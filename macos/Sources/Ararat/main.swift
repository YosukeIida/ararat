// Why not NSApplicationMain or @main: Chrome's BrowserCrApplication must be
// the first NSApplication; AppKit objects are created only from started.

import Darwin
import Foundation
import AppKit
import SQLite3
import AraratEngineAPI
import AraratKit
import AraratUI

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("engine: \(message)\n".utf8))
  exit(1)
}

// The versioned framework path the way chrome_exe_main_mac.cc builds it, the
// version taken from the outer bundle's Info.plist, so the launcher loads the
// framework it shipped with even when a second Versions/<new> is staged next
// to the running one.
var size: UInt32 = 0
guard _NSGetExecutablePath(nil, &size) == -1 else { fail("cannot get the executable path") }
var buffer = [CChar](repeating: 0, count: Int(size))
guard _NSGetExecutablePath(&buffer, &size) == 0 else { fail("cannot get the executable path") }
let end = buffer.firstIndex(of: 0) ?? buffer.count
let executableDir = (String(decoding: buffer[..<end].map { UInt8.init($0) }, as: UTF8.self) as NSString)
  .deletingLastPathComponent

guard let info = Bundle.main.infoDictionary,
      let version = info["CFBundleShortVersionString"] as? String, !version.isEmpty else {
  fail("no CFBundleShortVersionString in the bundle's Info.plist")
}

let frameworkPath = ((executableDir + "/../Frameworks/Chromium Framework.framework/Versions/\(version)/Chromium Framework") as NSString)
  .standardizingPath
guard FileManager.default.fileExists(atPath: frameworkPath) else {
  fail("no engine framework at \(frameworkPath)")
}

guard let handle = dlopen(frameworkPath, RTLD_LAZY | RTLD_LOCAL | RTLD_FIRST) else {
  fail("cannot load \(frameworkPath): \(String(cString: dlerror()))")
}
Launcher.handle = handle

// The browser process runs our entry (which stores the callbacks, sets the
// extra-parts hook and calls ChromeMain); the helpers keep running the stock
// ChromeMain — their engine behaviour is stock by design.
let isHelper = CommandLine.arguments.contains { $0.hasPrefix("--type=") }
let symbolName = isHelper ? "ChromeMain" : "AraratMain"
guard let symbol = dlsym(handle, symbolName) else {
  fail("cannot find \(symbolName): \(String(cString: dlerror()))")
}

if isHelper {
  typealias ChromeMain = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
  let chromeMain = unsafeBitCast(symbol, to: ChromeMain.self)
  exit(chromeMain(CommandLine.argc, CommandLine.unsafeArgv))
}

enum Launcher {
  static var handle: UnsafeMutableRawPointer!
  static var startupWatchdog: DispatchSourceTimer?
  @MainActor static var runtime: Runtime?
  @MainActor static var pendingURLs: [(url: String, untrusted: Bool)] = []
  @MainActor static var browserCheckFinished = false
}

func checkRecords(_ path: String) -> [[String]]? {
  var database: OpaquePointer?
  guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
    if let database { sqlite3_close(database) }
    return nil
  }
  defer { sqlite3_close(database) }
  var statement: OpaquePointer?
  guard sqlite3_prepare_v2(database, "SELECT kind,id,body FROM records ORDER BY kind,id", -1, &statement, nil) == SQLITE_OK else { return nil }
  defer { sqlite3_finalize(statement) }
  var rows: [[String]] = []
  while true {
    let result = sqlite3_step(statement)
    if result == SQLITE_DONE { return rows }
    guard result == SQLITE_ROW else { return nil }
    var row: [String] = []
    for column in 0..<3 {
      guard let value = sqlite3_column_text(statement, Int32(column)) else { return nil }
      row.append(String(cString: value))
    }
    rows.append(row)
  }
}

func checkRecordDiff(_ before: [[String]]?, _ after: [[String]]?) -> [[String: Any]] {
  guard let before, let after else { return [["kind": "missing", "id": "", "fields": ["$snapshot"]]] }
  func indexed(_ rows: [[String]]) -> [String: [String]] {
    Dictionary(rows.filter { $0.count == 3 }.map { ("\($0[0])\u{0}\($0[1])", $0) }, uniquingKeysWith: { first, _ in first })
  }
  func object(_ value: String) -> NSDictionary? {
    guard let data = value.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary
  }
  let old = indexed(before), new = indexed(after)
  return Set(old.keys).union(new.keys).sorted().compactMap { key in
    let a = old[key], b = new[key]
    guard a != b else { return nil }
    let row = a ?? b!
    var fields = ["$record"]
    if let a, let b {
      fields = ["$value"]
      if let left = object(a[2]), let right = object(b[2]) {
        let keys = Set(left.allKeys.compactMap { $0 as? String }).union(right.allKeys.compactMap { $0 as? String })
        fields = keys.sorted().filter { name in
          let lhs = left[name] as? NSObject, rhs = right[name] as? NSObject
          if lhs == nil || rhs == nil { return (lhs == nil) != (rhs == nil) }
          return !lhs!.isEqual(rhs)
        }
      }
    }
    return ["kind": row[0], "id": row[1], "fields": fields]
  }
}

func checkWindowSelection(_ rows: [[String]]?, windowID: String) -> String? {
  guard let row = rows?.first(where: { $0.count == 3 && $0[0] == "window" && $0[1] == windowID }),
        let data = row[2].data(using: .utf8),
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
  return body["selected"] as? String
}

@MainActor
final class PopupHost: NSObject, @preconcurrency ARWindowHostDelegate {
  let card = NSView()
  var host: (any ARWindowHostAPI)?
  var createdSize = NSSize.zero
  var closeObserver: NSObjectProtocol?
  deinit { if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) } }
  func pageCard(forWindowHost host: any ARWindowHostAPI) -> NSView { card }
  func windowHost(_ host: any ARWindowHostAPI, didReceiveTransaction transaction: [String: Any]) {}
  func windowHost(_ host: any ARWindowHostAPI, showProfile profile: String) {}
  func windowHostClosingAllCancelled(_ host: any ARWindowHostAPI) {}

  func create(bounds: NSRect) -> Bool {
    guard let symbol = dlsym(Launcher.handle, "AraratWindowHostCreate") else { return false }
    typealias Factory = @convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> UnsafeMutableRawPointer?
    let id = UUID().uuidString as NSString
    guard let pointer = unsafeBitCast(symbol, to: Factory.self)(
      Unmanaged.passUnretained(card).toOpaque(), Unmanaged.passUnretained(id).toOpaque()),
      let host = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? any ARWindowHostAPI else { return false }
    self.host = host
    if CommandLine.arguments.contains("--ararat-check=popup") {
      FileHandle.standardError.write(Data("ararat-trace: popup created\n".utf8))
    }
    host.delegate = self
    let desktopTop = NSScreen.screens.first?.frame.maxY ?? 600
    let requestedOrigin = NSPoint(x: bounds.origin.x, y: desktopTop - bounds.origin.y - bounds.height)
    let screen = NSScreen.screens.first(where: { $0.frame.contains(requestedOrigin) })?.visibleFrame
      ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
    let width = min(bounds.width > 0 ? bounds.width : 800, screen.width)
    let height = min(bounds.height > 0 ? bounds.height : 600, screen.height)
    let x = min(max(bounds.origin.x, screen.minX), screen.maxX - width)
    let y = min(max(desktopTop - bounds.origin.y - height, screen.minY), screen.maxY - height)
    host.window().setFrame(NSRect(x: x, y: y, width: width, height: height), display: false)
    createdSize = host.window().frame.size
    if CommandLine.arguments.contains("--ararat-check=popup") {
      FileHandle.standardError.write(Data("ararat-trace: popup sized width=\(createdSize.width) height=\(createdSize.height)\n".utf8))
    }
    return true
  }
}

@MainActor
final class Runtime {
  var windowID: String
  weak var root: Runtime?
  var children: [Runtime] = []
  var popups: [PopupHost] = []
  var hostClosing = false
  var hasUsableHost: Bool { !hostClosing && host.map { !$0.isClosing() } == true }
  init(windowID: String = UUID().uuidString) { self.windowID = windowID }
  func refreshOtherWindows() {
    let owner = root ?? self
    for window in [owner] + owner.children where window !== self { window.adapter?.refresh() }
  }
  func openURLs(_ urls: [(url: String, untrusted: Bool)]) {
    let windows = [self] + children
    let target = windows.first { $0.hasUsableHost && $0.host?.window().isKeyWindow == true }
      ?? windows.first { $0.hasUsableHost } ?? self
    if !target.hasUsableHost { _ = target.reopen() }
    target.adapter?.openExternalURLs(urls)
  }
  func createHost(popup: Bool, profile: String, bounds: NSRect) -> UnsafeMutableRawPointer? {
    func fallback(_ reason: String) -> UnsafeMutableRawPointer? {
      if CommandLine.arguments.contains(where: { $0.hasPrefix("--ararat-check=") || $0.hasPrefix("--ararat-screen=") }) {
        FileHandle.standardError.write(Data("ararat-trace: browser-factory fallback=\(reason)\n".utf8))
      }
      return nil
    }
    if popup {
      let value = PopupHost()
      guard value.create(bounds: bounds), let host = value.host else { return fallback("popup-create") }
      guard host.setProfileDirectory(profile) else { return fallback("popup-profile") }
      popups.append(value)
      value.closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: host.window(), queue: .main) { [weak self, weak value] _ in
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            if CommandLine.arguments.contains("--ararat-check=popup") {
              FileHandle.standardError.write(Data("ararat-trace: popup window destroyed\n".utf8))
            }
            self?.popups.removeAll { $0 === value }
          }
        }
      }
      return Unmanaged.passUnretained(host as AnyObject).toOpaque()
    }
    let windows = [self] + children
    let matching = windows.filter { $0.hasUsableHost && $0.host?.profileDirectory() == profile }
    let key = matching.first { $0.host?.window().isKeyWindow == true } ?? matching.first ?? self
    if matching.contains(where: { $0 === key }), key.hasUsableHost, let host = key.host, !host.hasBrowser(forProfile: profile) {
      return Unmanaged.passUnretained(host as AnyObject).toOpaque()
    }
    guard let session = key.adapter?.session else { return fallback("no-session") }
    let shownSpace = session.queue.sync {
      session.store?.recentSpaceForProfile(windowId: key.windowID, profile: profile == "Default" ? .default : .named(profile))
    }
    let child = Runtime(windowID: UUID().uuidString)
    child.root = self
    do { try child.start(session: session, shownSpace: shownSpace) }
    catch { report(error); return fallback("child-start") }
    guard let host = child.host, host.setProfileDirectory(profile) else { return fallback("child-profile") }
    children.append(child)
    return Unmanaged.passUnretained(host as AnyObject).toOpaque()
  }
  var host: (any ARWindowHostAPI)?
  var adapter: EngineAdapter?
  var sidebar: SidebarView?
  var container: SidebarContainerView?
  var workspace: WorkspaceAdapter?
  var keyBindings: KeyBindingsModel?
  var snapshot = WorkspaceSnapshot(archive: [], shownSpaceId: nil, selectedId: nil, spaces: [])
  var sliceTimer: Timer?
  var sliceRows: [Row] = []
  var slicePhase = 0
  var sliceAttempts = 0
  var sliceTransactions = 0
  var sliceLastRev: UInt64 = 0
  var sliceActive: String?
  var sliceLive = ""
  var sliceNavigationCount: UInt = 0
  var sliceResult = false
  var sliceTitleMatches = false
  var sliceNoReload = false
  var sliceInCard = false
  var sliceTabCount = 0
  var sliceMouseSent = false
  var sliceExclusiveInputSeen = false
  var sliceBrowsers: UInt = 0
  var sliceStyleMask: UInt = 0
  var windowCloseObserver: NSObjectProtocol?
  var quitMode: String?
  var quitPath: String?
  var quitBefore: [[String]]?
  var quitOriginal: [[String]]?
  var quitDuringProfileSwitch: [[String]]?
  var quitCancelPrevious: [[String]]?
  var quitPhase = 0
  var quitAttempts = 0
  var quitTimer: Timer?
  var quitEvents: [NSNumber] = []
  var quitDialogCount: UInt = 0
  var quitWillShutDown = false
  var quitFirst: [String: Any] = [:]
  var quitClosedRows: [[String]]?
  var quitReopened = false
  var quitDockEmpty = false
  var quitStock: UInt = 0
  var quitTimedOut = false
  var screenDialogs = 0
  var quitStyleMask: UInt = 0
  var screenSidebarLights = false
  var screenAppKitLightsHidden = false
  var screenClosingOffset = 0
  var browserCheckMode: String?
  var profileCheckStates: [[String: Any]] = []
  var extensionFocusProbe: [String: Any] = [:]
  var extensionSwitchedAway = false
  var profileCheckLoadedAfterClose = false
  var profileCheckPointer: String?
  var profileCloseBefore: [[String]]?
  var profileCloseCancelled: [String: Any] = [:]
  var profileCloseFinal: [String: Any] = [:]
  var profileCheckResult: [String: Any] = [:]
  var profileCheckPassed = false
  var browserCheckTimer: Timer?
  var browserCheckPhase = 0
  var browserCheckAttempts = 0
  var browserCheckTracedPhase = -1
  var browserCheckRows: [Row] = []
  var browserCheckSeedID: String?
  var browserCheckBefore: WorkspaceSnapshot?
  var browserCheckPopupSize = NSSize.zero
  var browserCheckPopupOpenerAlive = false
  var browserCheckStyleMask: UInt = 0
  var browserCheckStock: UInt = 0
  var promptFixture: PromptFixtureServer?
  var promptFixturePort: UInt16?
  var promptFixtureError: String?
  var permissionResults: [String: String] = [:]
  var permissionReadPending = false
  var dialogResults: [String: String] = [:]
  var dialogReadPending = false
  var dialogShown = Array(repeating: false, count: 5)
  var dialogAnswered = Array(repeating: false, count: 5)
  var dialogCardBefore = NSRect.zero
  var dialogCardAfter = NSRect.zero
  var dialogResizedFrame = NSRect.zero
  var dialogResizedShown = false
  var dialogResizedAnswered = false
  var dialogWindowsBefore: Set<Int> = []
  var authShown = false
  var authCancelled = false
  var protocolScheme = ""
  var protocolHandler: URL?
  var protocolExecutable = ""
  var protocolPrefBefore: String?
  var protocolFrontBefore: String?
  var protocolPidsBefore: Set<Int>?
  var protocolNewPids: Set<Int> = []
  var protocolAppLaunchObserved = false
  var protocolLaunchObserver: NSObjectProtocol?
  var protocolShown = false
  var protocolCancelled = false
  var protocolAfterTicks = 0
  var autofillState: [String: Any] = [:]
  var autofillAddressShown = false
  var autofillAddressDeclined = false
  var autofillCardShown = false
  var autofillCardDeclined = false
  var autofillFillTicks = 0
  var autofillSubmitNavigation: UInt = 0
  var autofillSettleTicks = 0
  var promptPageCard: NSView?
  var promptScreenResults: [String: String] = [:]
  var promptScreenReading = false
  var promptScreenSteps: [String: [String: Any]] = [:]
  var promptScreenWindows: Set<Int> = []
  var promptScreenSeeded = false
  var promptScreenBlockClicks = 0
  var promptScreenBlockTicks = 0
  var emptyProbe: [String: Any] = [:]
  var emptyMenuCount: UInt = 0
  var emptyMenuEnabled: [NSNumber] = []
  var emptyRestore: [String: Any] = [:]
  var emptyRestorePassed = false
  var emptyRowsBefore: Set<String> = []
  var linkMenuObserver: NSObjectProtocol?
  var linkMenuChosen = false
  var linkMenuTitle = ""
  var linkMenuItems: [String] = []
  var linkMenuNotifications = 0
  var linkMenuTargetEnabled = false
  var linkMenuTargetIndex = -1
  var linkMenuDownKeys = 0
  var linkMouseDiagnostics: [String: Any] = [:]
  var devtoolsFrontBefore: String?
  var devtoolsFirstLive = ""
  var devtoolsSecondLive = ""
  var devtoolsInitialHosts = 0
  var devtoolsResults: [String: Any] = [:]
  var popupFrontBefore: String?
  var popupFrontChange: [String: Any]?
  var popupWindowsHidden = true
  var devtoolsScreenFrontend: [String: Bool] = [:]
  var devtoolsScreenReading = false
  var devtoolsScreenOriginalSize = NSSize.zero

  func start(session: WorkspaceSession? = nil, shownSpace: String? = nil, reopening: Bool = false) throws {
    let arguments = CommandLine.arguments
    let checkName = arguments.first(where: { $0.hasPrefix("--ararat-check=") }).map { String($0.dropFirst(15)) }
    let screenName = arguments.first(where: { $0.hasPrefix("--ararat-screen=") }).map { String($0.dropFirst(16)) }
    if session == nil, let checkName, !["slice", "quit", "quit-cancel", "close", "newtab", "popup", "menu", "empty", "deferred", "profiles", "ext-windows", "ext-popup", "ext-windows-popup", "incognito", "permissions", "dialogs", "protocol", "autofill", "devtools"].contains(checkName) { return }
    if session == nil {
      quitMode = screenName == "quit" ? "screen-quit" : (["quit", "quit-cancel", "close"].contains(checkName ?? "") ? checkName : nil)
      if ["newtab", "popup", "menu", "empty", "deferred", "profiles", "ext-windows", "ext-popup", "ext-windows-popup", "incognito", "permissions", "dialogs", "protocol", "autofill", "devtools"].contains(checkName ?? "") { browserCheckMode = checkName }
      if checkName == "devtools" { devtoolsFrontBefore = commandOutput("/usr/bin/lsappinfo", ["front"]) }
      if ["popup", "ext-popup", "ext-windows-popup"].contains(checkName ?? "") { popupFrontBefore = commandOutput("/usr/bin/lsappinfo", ["front"]) }
      if screenName == "links" { browserCheckMode = "screen-links" }
      if screenName == "profiles" { browserCheckMode = "screen-profiles" }
      if screenName == "prompts" { browserCheckMode = "screen-prompts" }
      if screenName == "devtools" { browserCheckMode = "screen-devtools" }
      if screenName == "extensions" { browserCheckMode = "screen-extensions" }
      if ["permissions", "dialogs", "protocol", "autofill"].contains(checkName ?? "") || screenName == "prompts" {
        let fixture = try PromptFixtureServer()
        promptFixture = fixture
        fixture.start { [weak self] result in
          DispatchQueue.main.async {
            switch result {
            case .success(let port):
              self?.promptFixturePort = port
              FileHandle.standardError.write(Data("ararat-trace: fixture listening port=\(port)\n".utf8))
            case .failure(let error): self?.promptFixtureError = String(describing: error)
            }
          }
        }
      }
    }
    guard let createSymbol = dlsym(Launcher.handle, "AraratWindowHostCreate"),
          let pathSymbol = dlsym(Launcher.handle, "AraratUserDataDirectory") else {
      throw NSError(domain: "Ararat", code: 1)
    }
    typealias UserData = @convention(c) () -> UnsafeMutableRawPointer?
    let userData = unsafeBitCast(pathSymbol, to: UserData.self)
    let requested = arguments.first { $0.hasPrefix("--ararat-db=") }.map { String($0.dropFirst(12)) }
    let directory: String
    if let requested {
      directory = (requested as NSString).deletingLastPathComponent
    } else {
      guard let pointer = userData(),
            let root = Unmanaged<NSString>.fromOpaque(pointer).takeUnretainedValue() as String? else {
        throw NSError(domain: "Ararat", code: 2)
      }
      directory = (root as NSString).appendingPathComponent("Ararat")
    }
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let path = requested ?? (directory as NSString).appendingPathComponent("workspace.sqlite")
    quitPath = path
    let running = session ?? WorkspaceSession()
    if session == nil || reopening {
      // Design (c): the first window adopts the newest kept `Window` record, none kept
      // means a fresh UUID; reopen adopts the newest kept record no open window names.
      // The store opened here is handed to the adapter below, so nothing opens twice.
      let owner = root ?? self
      let openIDs = Set(([owner] + owner.children).filter { $0.hasUsableHost }.map(\.windowID))
      running.queue.sync {
        running.store = try? running.store ?? WorkspaceStore.open(path: path)
      }
      let kept = running.queue.sync { running.store?.keptWindows() ?? [] }
      windowID = kept.first { !openIDs.contains($0.id) }?.id ?? UUID().uuidString
    }
    let card = NSView()
    promptPageCard = card
    let check = session == nil && (arguments.contains("--ararat-check=slice") || quitMode != nil || browserCheckMode != nil)
    let profileCheck = ["profiles", "ext-windows", "incognito", "screen-profiles"].contains(browserCheckMode ?? "") || quitMode == "quit-cancel"
    let singleCheck = (browserCheckMode != nil && !profileCheck) || (quitMode != nil && quitMode != "quit")
    let linkCheck = browserCheckMode == "screen-links"
    let profileURL = ["ext-windows", "screen-profiles"].contains(browserCheckMode ?? "")
      ? "chrome-extension://kmgaadhbnkendcanjninlfmfgehagggl/probe.html" : "about:blank"
    let extensionPopupCheck = ["ext-popup", "ext-windows-popup", "screen-extensions"].contains(browserCheckMode ?? "")
    let adapter = try EngineAdapter(path: path, windowID: windowID, card: card, seedCheck: check && !singleCheck && !profileCheck, seedSingleCheck: check && singleCheck && !linkCheck, seedLinkCheck: check && linkCheck, seedProfiles: check && profileCheck, profileCheckURL: profileURL, singleCheckURL: extensionPopupCheck ? "chrome-extension://kmgaadhbnkendcanjninlfmfgehagggl/probe.html" : nil, session: running)
    if let shownSpace {
      try adapter.session.queue.sync { try adapter.session.store?.showSpace(windowId: windowID, spaceId: shownSpace) }
    }
    let workspace = WorkspaceAdapter(windowID: windowID, session: adapter.session)
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: nil, selectedId: nil, spaces: []))
    let container = SidebarContainerView(sidebar: sidebar, page: card)
    typealias Factory = @convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> UnsafeMutableRawPointer?
    let factory = unsafeBitCast(createSymbol, to: Factory.self)
    let hostID = windowID as NSString
    guard let pointer = factory(Unmanaged.passUnretained(container).toOpaque(), Unmanaged.passUnretained(hostID).toOpaque()),
          let host = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? any ARWindowHostAPI else {
      throw NSError(domain: "Ararat", code: 3)
    }
    self.host = host
    observeClose(host)
    self.adapter = adapter
    self.workspace = workspace
    let bindings = KeyBindingsModel(adapter: workspace)
    self.keyBindings = bindings
    bindings.onChange = { [weak sidebar, weak bindings] in
      if let bindings { sidebar?.keyBindings = bindings.bindings }
    }
    bindings.load { [weak self] result in
      if case .failure(let error) = result { self?.report(error) }
    }
    self.sidebar = sidebar
    self.container = container
    container.extensionActions = { [weak host] in host?.extensionActions() ?? [] }
    container.onExtensionAnchor = { [weak host] rect in host?.setExtensionAnchor(rect) }
    container.onExtensionAction = { [weak host] id in host?.runExtensionAction(id) }
    adapter.onSnapshot = { [weak self, weak sidebar, weak container] snapshot in
      self?.snapshot = snapshot
      if self?.host?.isClosingAll() != true, let space = snapshot.spaces.first(where: { $0.id == snapshot.shownSpaceId }) {
        _ = self?.host?.setProfileDirectory(space.profileName)
      }
      sidebar?.update(snapshot: snapshot)
      container?.selectionChanged()
      if check {
        let rows = snapshot.spaces.flatMap { $0.today + $0.pinned + $0.favorites }
        self?.sliceRows = ["One", "Two", "Three"].compactMap { name in
          rows.first { $0.url == "data:text/html,<title>Ararat \(name)</title>" }
        }
        if linkCheck { self?.sliceRows = rows.filter { $0.url?.contains("Open link") == true } }
        if extensionPopupCheck { self?.sliceRows = rows.filter { $0.url?.contains("/probe.html") == true } }
      }
    }
    adapter.onTransaction = { [weak self] transaction in
      guard let self else { return }
      self.sliceTransactions += 1
      self.sliceLastRev = transaction.rev
      for strip in transaction.strips {
        self.sliceActive = strip.tabs.first { $0.liveId == strip.active }?.item
      }
    }
    adapter.onWorkspaceChange = { [weak self] in self?.refreshOtherWindows() }
    adapter.onQuitProfileSwitch = { [weak self] in self?.quitDuringProfileSwitch = self?.captureCheckRows() }
    let actions = SidebarActions()
    actions.onSelect = { [weak adapter] row in
      if let url = row.url { adapter?.select(id: row.id, url: url) }
    }
    actions.configureEditing(adapter: workspace, isActive: { true }, window: { [weak self] in self?.host?.window() }, show: { [weak self] snapshot in self?.show(snapshot) }, record: { [weak self] snapshot in self?.snapshot = snapshot })
    actions.onClose = { [weak self] id in self?.close(id) }
    actions.onCloseSelected = { [weak self] in
      if let id = self?.snapshot.selectedId { self?.close(id) }
    }
    actions.onArchive = { [weak self] id in
      self?.adapter?.close(id: id, archive: true)
    }
    actions.onShowSpace = { [weak self] id in
      self?.workspace?.showSpace(id: id) { [weak self] result in
        if case .failure(let error) = result { self?.report(error) }
        self?.workspace?.snapshot { [weak self] result in self?.showResult(result) }
      }
    }
    actions.onRestore = { [weak self] id in
      self?.workspace?.restore(id: id) { [weak self] result in self?.showResult(result) }
    }
    actions.onArchiveDelete = { [weak self] id in
      self?.workspace?.deleteArchive(id: id) { [weak self] result in self?.showResult(result) }
    }
    actions.onCreateSpace = { [weak self] name in
      self?.workspace?.createSpace(name: name) { [weak self] result in self?.showResult(result) }
    }
    actions.onCreatePageChanged = { [weak self] in self?.container?.selectionChanged() }
    actions.bind(to: sidebar)
    adapter.attach(host)
    if let argument = arguments.first(where: { $0.hasPrefix("--ararat-measure=") }) {
      guard let symbol = dlsym(Launcher.handle, "AraratStartMeasure") else {
        throw NSError(domain: "Ararat.measure", code: 1)
      }
      typealias StartMeasure = @convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> Void
      let scenario = String(argument.dropFirst(17)) as NSString
      unsafeBitCast(symbol, to: StartMeasure.self)(Unmanaged.passUnretained(host as AnyObject).toOpaque(), Unmanaged.passUnretained(scenario).toOpaque())
      return
    }
    if reopening {
      if quitMode == nil || quitMode == "screen-quit" { host.window().makeKeyAndOrderFront(nil) }
    } else if browserCheckMode != nil {
      if browserCheckMode == "screen-links" || browserCheckMode == "screen-profiles" || browserCheckMode == "screen-prompts" || browserCheckMode == "screen-devtools" || browserCheckMode == "screen-extensions" {
        NSApp.activate(ignoringOtherApps: true)
        host.window().makeKeyAndOrderFront(nil)
      }
      let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.browserCheckTick() }
      }
      browserCheckTimer = timer
      RunLoop.main.add(timer, forMode: .common)
    } else if quitMode != nil {
      if quitMode == "screen-quit" {
        host.disableCheckConfirmQuit()
        NSApp.activate(ignoringOtherApps: true)
        host.window().makeKeyAndOrderFront(nil)
      }
      if quitMode == "quit-cancel" || quitMode == "close" { host.installCheckDialogFactory() }
      let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.quitTick() }
      }
      quitTimer = timer
      RunLoop.main.add(timer, forMode: .common)
    } else if check {
      sliceTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.sliceTick(card: card) }
      }
    } else if session == nil {
      host.window().makeKeyAndOrderFront(nil)
    }
  }

  func observeClose(_ host: any ARWindowHostAPI) {
    if let windowCloseObserver { NotificationCenter.default.removeObserver(windowCloseObserver) }
    hostClosing = false
    windowCloseObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: host.window(), queue: .main
    ) { [weak weakHost = host as AnyObject, weak self] _ in
      MainActor.assumeIsolated {
        self?.hostClosing = true
        if let host = weakHost as? any ARWindowHostAPI {
          self?.captureCheckState(host)
          self?.adapter?.closeWindow(quitting: host.isClosingAll())
        }
      }
      DispatchQueue.main.async { [weak self, weak weakHost] in
        guard let self, let weakHost, (self.host as AnyObject?) === weakHost else { return }
        self.host = nil
        self.root?.children.removeAll { $0 === self }
      }
    }
  }

  func captureCheckState(_ host: any ARWindowHostAPI) {
    if browserCheckMode != nil {
      browserCheckStyleMask = host.window().styleMask.rawValue
      browserCheckStock = host.checkStockBrowsers()
      if browserCheckMode == "profiles" { profileCloseFinal = host.checkProfileCloseState() }
    }
    guard quitMode != nil else { return }
    quitEvents = host.checkClosingEvents()
    quitDialogCount = host.checkDialogCount()
    quitStock = host.checkStockBrowsers()
  }

  func reopen() -> Bool {
    if quitMode == "close" { FileHandle.standardError.write(Data("ararat-trace: reopen-callback host=\(host != nil) selected=\(snapshot.selectedId != nil)\n".utf8)) }
    if !hasUsableHost, let existing = children.first(where: { $0.hasUsableHost })?.host {
      if quitMode == nil { existing.window().makeKeyAndOrderFront(nil) }
      return false
    }
    if hasUsableHost, let host {
      if quitMode == nil || quitMode == "screen-quit" { host.window().makeKeyAndOrderFront(nil) }
      return false
    }
    guard let adapter else { return false }
    let oldSnapshot = snapshot
    let session = adapter.session
    adapter.shutdown()
    do { try start(session: session, shownSpace: oldSnapshot.shownSpaceId, reopening: true) }
    catch { report(error); return false }
    if let id = oldSnapshot.selectedId,
       let row = oldSnapshot.spaces.flatMap({ $0.today + $0.pinned + $0.favorites }).first(where: { $0.id == id }),
       let url = row.url {
      self.adapter?.select(id: id, url: url)
      if quitMode == "close" { FileHandle.standardError.write(Data("ararat-trace: reopen-select\n".utf8)) }
    }
    return false
  }

  func show(_ snapshot: WorkspaceSnapshot) {
    self.snapshot = snapshot
    sidebar?.update(snapshot: snapshot)
    container?.selectionChanged()
    refreshOtherWindows()
  }

  func showResult(_ result: Result<WorkspaceSnapshot, Error>) {
    switch result {
    case .success(let snapshot): show(snapshot)
    case .failure(let error): report(error)
    }
  }

  func showChange(_ result: Result<WorkspaceAdapter.Change, Error>) {
    switch result {
    case .success(let change): show(change.snapshot)
    case .failure(let error): report(error)
    }
  }

  func close(_ id: String) {
    adapter?.close(id: id)
  }

  func captureCheckRows() -> [[String]]? {
    guard let adapter, let quitPath else { return nil }
    return adapter.session.queue.sync {
      guard let store = adapter.session.store else { return nil }
      do { try store.flush() } catch { return nil }
      return checkRecords(quitPath)
    }
  }

  func sendQuitKey(_ host: any ARWindowHostAPI) {
    (host.tabs() as? [any ARTabAPI])?.first?.focusCheckPage()
    guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.window().windowNumber,
      context: nil, characters: "q", charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12) else { return }
    NSApp.sendEvent(event)
  }

  func sendLinkClick(_ tab: any ARTabAPI, right: Bool, command: Bool) {
    let name = right ? "right" : "command"
    guard let view = tab.view, let window = view.window else {
      linkMouseDiagnostics[name] = ["view_attached": false]
      return
    }
    let local = NSPoint(x: 70, y: view.isFlipped ? 70 : view.bounds.height - 70)
    let location = view.convert(local, to: nil)
    let root = window.contentView
    let point = root?.superview?.convert(location, from: nil) ?? location
    let hit = root?.hitTest(point)
    var chain: [String] = []
    var ancestor = hit
    while let current = ancestor {
      chain.append(NSStringFromClass(type(of: current)))
      ancestor = current.superview
    }
    linkMouseDiagnostics[name] = ["view_attached": true, "local": NSStringFromPoint(local),
      "window_point": NSStringFromPoint(location), "view_bounds": NSStringFromRect(view.bounds),
      "window_key": window.isKeyWindow, "window_visible": window.isVisible, "app_active": NSApp.isActive,
      "hit_in_view": hit?.isDescendant(of: view) ?? false, "hit_chain": chain]
    let flags: NSEvent.ModifierFlags = command ? .command : []
    for type in right ? [NSEvent.EventType.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp] {
      if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: flags,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { NSApp.sendEvent(event) }
    }
  }

  func watchLinkMenu() {
    guard let title = host?.checkOpenLinkNewWindowTitle(), !title.isEmpty else { return }
    linkMenuTitle = title
    linkMenuObserver = NotificationCenter.default.addObserver(
      forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
    ) { [weak self] notification in
      guard let menu = notification.object as? NSMenu else { return }
      MainActor.assumeIsolated {
        self?.linkMenuNotifications += 1
        self?.linkMenuItems = menu.items.map { $0.title }
      }
      guard let target = menu.items.firstIndex(where: { $0.title == title }) else { return }
      let count = menu.items[...target].filter { !$0.isHidden && $0.isEnabled && !$0.isSeparatorItem }.count
      MainActor.assumeIsolated {
        self?.linkMenuChosen = true
        self?.linkMenuTargetEnabled = menu.items[target].isEnabled && !menu.items[target].isHidden
        self?.linkMenuTargetIndex = target
        self?.linkMenuDownKeys = count
      }
      for key in Array(repeating: UInt16(125), count: count) + [UInt16(36)] {
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
          characters: key == 36 ? "\r" : "\u{f701}", charactersIgnoringModifiers: key == 36 ? "\r" : "\u{f701}",
          isARepeat: false, keyCode: key) { NSApp.postEvent(event, atStart: false) }
      }
    }
  }

  func browserCheckTick() {
    guard let mode = browserCheckMode else { return }
    if browserCheckPhase != browserCheckTracedPhase {
      browserCheckTracedPhase = browserCheckPhase
      FileHandle.standardError.write(Data("ararat-trace: browser-check=\(mode) phase=\(browserCheckPhase) tabs=\(host?.tabs().count ?? 0) children=\(children.count) popups=\(popups.count)\n".utf8))
    }
    browserCheckAttempts += 1
    var timeoutValues: [String: Any] = ["timeout": true]
    if ["profiles", "ext-windows", "incognito", "screen-profiles"].contains(mode), let host {
      let profileState = host.checkProfileState()
      timeoutValues["profile_state"] = profileState
      if mode == "ext-windows" || mode == "screen-profiles" {
        let browsers = profileState["browsers"] as? [[String: Any]] ?? []
        for (profile, label) in [("Default", "default"), ("Profile 1", "profile1")] {
          let browser = browsers.first { $0["profile"] as? String == profile }
          let title = ((browser?["tabs"] as? [[String: Any]])?.first?["title"] as? String)
          let data = title?.data(using: .utf8)
          timeoutValues["report_\(label)_ok"] = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } != nil
          timeoutValues["report_\(label)_title_length"] = title?.count ?? 0
          timeoutValues["report_\(label)_present"] = title != nil
        }
      }
      timeoutValues["cookie_state"] = host.checkCookieState()
      timeoutValues["snapshot_spaces"] = snapshot.spaces.count
      timeoutValues["shown_profile"] = host.profileDirectory()
      timeoutValues["host_tab_count"] = host.tabs().count
      timeoutValues["selected_item"] = snapshot.selectedId ?? ""
      timeoutValues["default_rows"] = snapshot.spaces.first(where: { $0.id == "default" })?.today.count ?? 0
      timeoutValues["named_rows"] = snapshot.spaces.first(where: { $0.id == "named" })?.today.count ?? 0
      timeoutValues["application_active"] = NSApp.isActive
      timeoutValues["window_key"] = host.window().isKeyWindow
      timeoutValues["popup_hosts"] = popups.count
      timeoutValues["popup_states"] = popups.compactMap { $0.host?.checkProfileState() }
      timeoutValues["popup_titles"] = popups.flatMap { ($0.host?.tabs() as? [any ARTabAPI])?.map(\.title) ?? [] }
      timeoutValues["observed_profiles"] = profileCheckStates.count
      timeoutValues["switched_away"] = extensionSwitchedAway
      timeoutValues["close_state"] = host.checkProfileCloseState()
      timeoutValues["cancel_run"] = profileCloseCancelled
      timeoutValues["close_run"] = profileCloseFinal
    }
    if mode == "empty" {
      timeoutValues["empty_windows_probe"] = emptyProbe
      timeoutValues["menu_items_validated"] = emptyMenuCount
      timeoutValues["enabled_command_ids"] = emptyMenuEnabled
      timeoutValues["session_restore"] = emptyRestore
      timeoutValues["host_has_browser"] = host?.hasBrowser() ?? false
      timeoutValues["host_tab_count"] = host?.tabs().count ?? 0
    }
    if mode == "devtools" {
      timeoutValues["devtools_state"] = host?.checkDevToolsState() ?? [:]
      timeoutValues["first_tab_state"] = host?.checkDevToolsTabState(devtoolsFirstLive) ?? [:]
      timeoutValues["tab_count"] = host?.tabs().count ?? 0
      timeoutValues["active_item"] = host?.activeItemId() ?? ""
      timeoutValues["devtools_hosts"] = host?.checkDevToolsHostCount() ?? 0
      timeoutValues["stock_browsers"] = host?.checkStockBrowsers() ?? browserCheckStock
      timeoutValues["host_present"] = host != nil
      timeoutValues["host_count"] = children.count + popups.count
      timeoutValues["initial_host_count"] = devtoolsInitialHosts
      timeoutValues["front_before"] = devtoolsFrontBefore ?? ""
      timeoutValues["front_now"] = commandOutput("/usr/bin/lsappinfo", ["front"]) ?? ""
      timeoutValues["completed"] = devtoolsResults
      for key in ["initial_docked", "background_hidden", "tab_restored", "undocked_host", "redocked", "closed_full_page", "inspected_tab_closed", "inspect_docked", "open_at_quit"] {
        timeoutValues[key] = devtoolsResults[key] as? Bool ?? false
      }
    }
    if mode == "screen-devtools" {
      timeoutValues["devtools_state"] = host?.checkDevToolsState() ?? [:]
      timeoutValues["frontend"] = devtoolsScreenFrontend
      timeoutValues["completed"] = devtoolsResults
      if browserCheckAttempts > 300, let window = host?.window(),
         let path = promptScreenScreenshot(window, name: "devtools-timeout", withoutShadow: true) {
        timeoutValues["screenshot"] = path
      }
    }
    if mode == "permissions" {
      let tab = (host?.tabs() as? [any ARTabAPI])?.first
      timeoutValues.merge(["fixture_port": promptFixturePort as Any? ?? NSNull(),
        "fixture_error": promptFixtureError as Any? ?? NSNull(), "tab_present": tab != nil,
        "page_loaded": tab?.url.contains("/permissions") == true && tab?.isLoading == false,
        "notification_answered": browserCheckPhase >= 3, "location_answered": browserCheckPhase >= 5,
        "midi_answered": browserCheckPhase >= 7, "read_pending": permissionReadPending,
        "notifications": permissionResults["notifications"] ?? "", "location": permissionResults["location"] ?? "",
        "midi_result": permissionResults["midiResult"] ?? "", "midi_state": permissionResults["midiState"] ?? "",
        "prompt_shown": tab?.checkPermissionShownCount() ?? 0, "pending": tab?.checkPermissionPending() ?? false,
        "stock_browsers": host?.checkStockBrowsers() ?? 0]) { _, new in new }
      if let error = promptFixtureError { finishBrowserCheck(ok: false, values: timeoutValues.merging(["error": error]) { _, new in new }); return }
    }
    if mode == "dialogs" {
      let tab = (host?.tabs() as? [any ARTabAPI])?.first
      timeoutValues.merge(["fixture_port": promptFixturePort as Any? ?? NSNull(),
        "fixture_error": promptFixtureError as Any? ?? NSNull(), "tab_present": tab != nil,
        "page_loaded": tab?.url.contains("/dialogs") == true && tab?.isLoading == false,
        "dialog_active": tab?.checkIsDialogActive() ?? false, "host_is_ours": tab?.checkDialogHostIsOurs() ?? false,
        "shown": dialogShown, "answered": dialogAnswered, "results": dialogResults,
        "read_pending": dialogReadPending, "auth_shown": authShown, "auth_cancelled": authCancelled,
        "auth_body": dialogResults["auth"] == "body", "stock_browsers": host?.checkStockBrowsers() ?? 0]) { _, new in new }
      timeoutValues.merge(["card_before": rectFields(dialogCardBefore), "card_after": rectFields(dialogCardAfter),
        "dialog_frame": rectFields(dialogResizedFrame), "resized_shown": dialogResizedShown,
        "resized_answered": dialogResizedAnswered]) { _, new in new }
      for (index, name) in ["alert", "confirm_ok", "confirm_cancel", "prompt_text", "prompt_cancel"].enumerated() {
        timeoutValues["\(name)_shown"] = dialogShown[index]
        timeoutValues["\(name)_answered"] = dialogAnswered[index]
        let keys = ["alert", "confirmOk", "confirmCancel", "promptText", "promptCancel"]
        timeoutValues["\(name)_result"] = dialogResults[keys[index]] ?? ""
      }
      if let error = promptFixtureError { finishBrowserCheck(ok: false, values: timeoutValues.merging(["error": error]) { _, new in new }); return }
    }
    if mode == "protocol" {
      let tab = (host?.tabs() as? [any ARTabAPI])?.first
      timeoutValues.merge(["fixture_port": promptFixturePort as Any? ?? NSNull(),
        "fixture_error": promptFixtureError as Any? ?? NSNull(), "tab_present": tab != nil,
        "page_loaded": tab?.url.contains("/protocol") == true && tab?.isLoading == false,
        "scheme": protocolScheme, "handler": protocolHandler?.path ?? "", "front_before": protocolFrontBefore as Any? ?? NSNull(),
        "process_snapshot": protocolPidsBefore != nil, "new_pids": protocolNewPids.sorted(),
        "app_launch_observed": protocolAppLaunchObserved, "dialog_active": tab?.checkIsDialogActive() ?? false,
        "host_is_ours": tab?.checkDialogHostIsOurs() ?? false, "dialog_shown": protocolShown,
        "cancelled": protocolCancelled, "pref_before": protocolPrefBefore as Any? ?? NSNull(),
        "settle_ticks": protocolAfterTicks, "stock_browsers": host?.checkStockBrowsers() ?? 0]) { _, new in new }
      if browserCheckAttempts > 300 {
        let pref = tab?.checkProtocol(protocolScheme, launch: false)["pref"] as? String
        let front = commandOutput("/usr/bin/lsappinfo", ["front"])
        timeoutValues["pref_after"] = pref as Any? ?? NSNull()
        timeoutValues["front_after"] = front as Any? ?? NSNull()
        timeoutValues["prefs_unchanged"] = pref != nil && pref == protocolPrefBefore
        timeoutValues["front_unchanged"] = front != nil && front == protocolFrontBefore
        timeoutValues["no_new_process"] = protocolPidsBefore != nil && protocolNewPids.isEmpty && !protocolAppLaunchObserved
      }
      if let error = promptFixtureError { finishBrowserCheck(ok: false, values: timeoutValues.merging(["error": error]) { _, new in new }); return }
    }
    if mode == "autofill" {
      let tab = (host?.tabs() as? [any ARTabAPI])?.first
      timeoutValues.merge(["fixture_port": promptFixturePort as Any? ?? NSNull(),
        "fixture_error": promptFixtureError as Any? ?? NSNull(), "tab_present": tab != nil,
        "page_loaded": tab?.url.contains("/autofill") == true && tab?.isLoading == false,
        "navigation_count": tab?.navigationCount ?? 0, "submit_navigation": autofillSubmitNavigation,
        "address_shown": autofillAddressShown, "address_declined": autofillAddressDeclined,
        "card_shown": autofillCardShown, "card_declined": autofillCardDeclined,
        "address_bubble": tab?.checkAutofillBubble(false, decline: false) ?? false,
        "card_bubble": tab?.checkAutofillBubble(true, decline: false) ?? false,
        "data": autofillState, "fill_ticks": autofillFillTicks, "settle_ticks": autofillSettleTicks,
        "stock_browsers": host?.checkStockBrowsers() ?? 0]) { _, new in new }
      if let error = promptFixtureError { finishBrowserCheck(ok: false, values: timeoutValues.merging(["error": error]) { _, new in new }); return }
    }
    if mode == "screen-prompts" {
      let tab = (host?.tabs() as? [any ARTabAPI])?.first
      timeoutValues.merge(["fixture_port": promptFixturePort as Any? ?? NSNull(),
        "fixture_error": promptFixtureError as Any? ?? NSNull(), "tab_present": tab != nil,
        "active": NSApp.isActive, "window_key": host?.window().isKeyWindow ?? false,
        "dialog_active": tab?.checkIsDialogActive() ?? false, "host_is_ours": tab?.checkDialogHostIsOurs() ?? false,
        "page_results": promptScreenResults, "steps": promptScreenSteps, "seeded": promptScreenSeeded,
        "block_clicks": promptScreenBlockClicks,
        "autofill_data": tab?.checkAutofillState() ?? [:], "field_reported": promptScreenResults["field"] != nil,
        "stock_browsers": host?.checkStockBrowsers() ?? 0, "bluetooth_tcc_risk": true]) { _, new in new }
      for name in ["permission", "javascript", "autofill", "auth", "webauthn_get", "webauthn_create"] {
        let step = promptScreenSteps[name] ?? [:]
        for key in ["shown", "host_is_ours", "dialog_frame", "card_frame", "button_frame", "field_frame", "popup_frame", "inside_card", "centered", "screenshot", "dialog_screenshot", "page_result"] {
          timeoutValues["\(name)_\(key)"] = step[key] ?? NSNull()
        }
      }
      if let error = promptFixtureError { finishBrowserCheck(ok: false, values: timeoutValues.merging(["error": error]) { _, new in new }); return }
    }
    if mode == "screen-links" {
      let seed = (host?.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == browserCheckSeedID })
      timeoutValues.merge(["mouse": linkMouseDiagnostics, "menu_observer": linkMenuObserver != nil,
        "menu_expected_title": linkMenuTitle, "menu_notifications": linkMenuNotifications,
        "menu_items": linkMenuItems, "menu_target_found": linkMenuChosen,
        "menu_target_enabled": linkMenuTargetEnabled, "menu_target_index": linkMenuTargetIndex,
        "menu_down_keys": linkMenuDownKeys, "child_hosts": children.filter { $0.host != nil }.count,
        "seed_tab_present": seed != nil, "seed_view_attached": seed?.view?.window != nil,
        "active_item": host?.activeItemId() ?? "", "selected_item": snapshot.selectedId ?? ""]) { _, new in new }
      if browserCheckAttempts > 300, let window = host?.window(),
         let path = promptScreenScreenshot(window, name: "links-timeout", withoutShadow: true) {
        timeoutValues["screenshot"] = path
      }
    }
    if mode == "screen-extensions" {
      timeoutValues.merge(devtoolsResults) { _, new in new }
      timeoutValues["sidebar_state"] = container?.sidebarState ?? "missing"
    }
    if ["popup", "ext-popup", "ext-windows-popup"].contains(mode) {
      let front = commandOutput("/usr/bin/lsappinfo", ["front"])
      let visible = NSApp.windows.contains { $0.isVisible || $0.isKeyWindow }
      popupWindowsHidden = popupWindowsHidden && !visible
      if popupFrontChange == nil, let before = popupFrontBefore, let front, before != front {
        let app = NSWorkspace.shared.frontmostApplication
        popupFrontChange = ["phase": browserCheckPhase, "front": front,
                            "app": app?.localizedName ?? "", "bundle_id": app?.bundleIdentifier ?? "",
                            "pid": app?.processIdentifier ?? 0, "ararat_window_visible": visible]
      }
      let popup = popups.first
      let popupHost = popup?.host
      let popupTab = (popupHost?.tabs() as? [any ARTabAPI])?.first
      let size = popup?.createdSize ?? browserCheckPopupSize
      let count = dlsym(Launcher.handle, "AraratBrowserCount").map {
        unsafeBitCast($0, to: (@convention(c) () -> UInt).self)()
      }
      timeoutValues.merge(["width": size.width, "height": size.height,
                           "opener_alive": popupTab?.checkOpenerAlive() ?? browserCheckPopupOpenerAlive,
                           "opener_probe_started": browserCheckPhase >= 3,
                           "popup_host_present": popupHost != nil,
                           "popup_has_browser": popupHost?.hasBrowser() ?? false,
                           "popup_tab_present": popupTab != nil,
                           "popup_loading": popupTab.map { $0.isLoading } as Any? ?? NSNull(),
                           "popup_navigation_count": popupTab.map { $0.navigationCount } as Any? ?? NSNull(),
                           "popup_url": popupTab?.url as Any? ?? NSNull(),
                           "popup_title": popupTab?.title as Any? ?? NSNull(),
                           "devtools_hosts": popupHost?.checkDevToolsHostCount() ?? 0,
                           "stock_browsers": popupHost?.checkStockBrowsers() ?? browserCheckStock,
                           "browser_count": count as Any? ?? NSNull(), "front_before": popupFrontBefore ?? "",
                           "front_now": front ?? "", "front_change": popupFrontChange ?? [:],
                           "windows_hidden": popupWindowsHidden]) { _, new in new }
    }
    if browserCheckAttempts > 300 { finishBrowserCheck(ok: false, values: timeoutValues); return }
    if mode == "profiles", browserCheckPhase == 8, host == nil,
       let symbol = dlsym(Launcher.handle, "AraratBrowserCount"),
       unsafeBitCast(symbol, to: (@convention(c) () -> UInt).self)() == 0 {
      let after = captureCheckRows()
      let unchanged = profileCloseBefore != nil && after != nil &&
        profileCloseBefore?.filter { $0.first != "window" } == after?.filter { $0.first != "window" }
      let removed = profileCloseBefore?.contains(where: { $0.first == "window" }) == true &&
        after?.contains(where: { $0.first == "window" }) == false
      let closed = profileCloseFinal["closed"] as? Bool == true &&
        profileCloseFinal["browsers"] as? Int == 0 && profileCloseFinal["dialogs"] as? Int == 2 &&
        profileCloseFinal["close_cancelled"] as? Int == 1 &&
        profileCloseFinal["beforeunload_profiles"] as? [String] == ["Default", "Profile 1"]
      profileCheckResult.merge(["cancel_run": profileCloseCancelled, "close_run": profileCloseFinal,
        "rows_before_close": profileCloseBefore ?? [], "rows_after_close": after ?? [],
        "rows_unchanged_after_close": unchanged, "window_removed": removed,
        "widget_closed": true, "stock_browsers": browserCheckStock]) { _, new in new }
      finishBrowserCheck(ok: profileCheckPassed && closed && unchanged && removed && browserCheckStock == 0,
                         values: profileCheckResult)
      return
    }
    if mode == "popup", browserCheckPhase >= 6 {
      guard let popup = popups.first?.host else { return }
      if browserCheckPhase == 6, host == nil, popups.count == 1,
         let symbol = dlsym(Launcher.handle, "AraratBrowserCount"),
         unsafeBitCast(symbol, to: (@convention(c) () -> UInt).self)() == 1 {
        browserCheckPhase = 7
        popup.checkOpenDevTools()
      } else if browserCheckPhase == 7, popups.count == 2, popup.checkDevToolsHostCount() == 1,
                popup.checkStockBrowsers() == 0 {
        devtoolsResults["popup_only_devtools_host"] = true
        browserCheckPhase = 8
        popup.checkCloseDevTools()
      } else if browserCheckPhase == 8, popups.count == 1, popup.checkDevToolsHostCount() == 0 {
        devtoolsResults["popup_only_devtools_closed"] = true
        devtoolsResults["stock_browsers"] = popup.checkStockBrowsers()
        let front = commandOutput("/usr/bin/lsappinfo", ["front"])
        let frontUnchanged = !(popupFrontBefore ?? "").isEmpty && !(front ?? "").isEmpty && popupFrontBefore == front && popupFrontChange == nil
        devtoolsResults["front_before"] = popupFrontBefore ?? ""
        devtoolsResults["front_after"] = front ?? ""
        devtoolsResults["front_unchanged"] = frontUnchanged
        devtoolsResults["front_change"] = popupFrontChange ?? [:]
        devtoolsResults["windows_hidden"] = popupWindowsHidden
        finishBrowserCheck(ok: popup.checkStockBrowsers() == 0 && frontUnchanged && popupWindowsHidden, values: devtoolsResults)
      }
      return
    }
    guard let host else { return }
    if mode == "devtools" { devtoolsCheckTick(host); return }
    if mode == "screen-devtools" { devtoolsScreenTick(host); return }
    if mode == "permissions" { permissionCheckTick(host); return }
    if mode == "dialogs" { dialogCheckTick(host); return }
    if mode == "protocol" { protocolCheckTick(host); return }
    if mode == "autofill" { autofillCheckTick(host); return }
    if mode == "screen-prompts" { promptScreenTick(host); return }
    if mode == "empty" { emptyCheckTick(host); return }
    if mode == "profiles" { profileCheckTick(host); return }
    if mode == "incognito" { incognitoCheckTick(host); return }
    if mode == "ext-windows" || mode == "screen-profiles" { extensionCheckTick(host, screen: mode == "screen-profiles"); return }
    if mode == "ext-windows-popup" { extensionPopupWindowCheckTick(host); return }
    if mode == "ext-popup" { extensionActionCheckTick(host); return }
    if mode == "screen-extensions" { extensionScreenTick(host); return }
    browserCheckStyleMask = host.window().styleMask.rawValue
    browserCheckStock = host.checkStockBrowsers()
    if browserCheckPhase == 0, let row = sliceRows.first, let url = row.url {
      browserCheckSeedID = row.id
      browserCheckPhase = 1
      adapter?.select(id: row.id, url: url)
    } else if browserCheckPhase == 1, sliceActive == browserCheckSeedID,
              let tab = (host.tabs() as? [any ARTabAPI])?.first, !tab.isLoading, tab.navigationCount > 0,
              snapshot.spaces.flatMap({ $0.today }).contains(where: { $0.id == browserCheckSeedID && (mode == "screen-links" || $0.title == "Ararat One") }) {
      browserCheckPhase = 2
      browserCheckBefore = snapshot
      if mode == "newtab" {
        for disposition in ["background", "split", "foreground"] {
          host.checkNavigate("data:text/html,<title>Ararat \(disposition)</title>", disposition: disposition)
        }
      } else if mode == "popup" {
        browserCheckBefore = snapshot
        tab.openCheckPopup()
      } else if mode == "deferred" {
        host.checkCreateDeferredBrowsers()
      } else if mode == "menu" {
        host.checkNavigate("chrome://newtab/", disposition: "current")
      } else if mode == "screen-links" {
        browserCheckBefore = snapshot
        sendLinkClick(tab, right: false, command: true)
      }
    } else if mode == "screen-links", browserCheckPhase == 2,
              snapshot.spaces.flatMap({ $0.today }).contains(where: { $0.url?.contains("example.test/link") == true }),
              let tab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == browserCheckSeedID }) {
      browserCheckPhase = 3
      watchLinkMenu()
      sendLinkClick(tab, right: true, command: false)
    } else if mode == "screen-links", browserCheckPhase == 3, linkMenuChosen,
              children.contains(where: { $0.host != nil }),
              let tab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == browserCheckSeedID }) {
      browserCheckPhase = 4
      tab.openCheckPopup()
    } else if mode == "screen-links", browserCheckPhase == 4, let popup = popups.first?.host,
              popup.window().isVisible,
              let popupTab = (popup.tabs() as? [any ARTabAPI])?.first, !popupTab.isLoading, popupTab.title == "Popup" {
      let frame = popup.window().frame
      let screen = popup.window().screen?.visibleFrame ?? .zero
      let placed = screen.contains(frame)
      let stock = host.checkStockBrowsers()
      finishBrowserCheck(ok: placed && stock == 0,
        values: ["command_click": true, "context_menu": true, "popup_placed": placed,
                 "popup_x": frame.origin.x, "popup_y": frame.origin.y, "stock_browsers": stock])
    } else if mode == "deferred", browserCheckPhase == 2, host.checkStockBrowsers() >= 1, popups.isEmpty {
      let stock = host.checkStockBrowsers()
      finishBrowserCheck(ok: stock == 1 && children.isEmpty && popups.isEmpty,
                         values: ["stock_browsers": stock, "app_windows": children.count, "popup_hosts": popups.count])
    } else if mode == "menu", browserCheckPhase == 2,
              let tab = (host.tabs() as? [any ARTabAPI])?.first, !tab.isLoading, tab.url.hasPrefix("chrome://newtab") {
      browserCheckBefore = snapshot
      browserCheckPhase = 3
      host.checkOpenURLs()
    } else if mode == "menu", browserCheckPhase == 3 {
      let rows = snapshot.spaces.flatMap { $0.today }
      guard let first = rows.first(where: { $0.url == "https://example.test/ararat-one" }),
            let last = rows.first(where: { $0.url == "https://example.test/ararat-two" }),
            rows.count == (browserCheckBefore?.spaces.flatMap { $0.today }.count ?? 0) + 2,
            snapshot.selectedId == last.id, rows.contains(where: { $0.id == browserCheckSeedID }) else { return }
      browserCheckRows = [first, last]
      browserCheckPhase = 4
      host.checkMenuCommand(false)
    } else if mode == "menu", browserCheckPhase == 4, host.tabs().count >= 4 {
      guard host.checkFocusSearch() else {
        finishBrowserCheck(ok: false, values: ["focus_search_unchanged": false])
        return
      }
      browserCheckPhase = 5
      host.checkMenuCommand(true)
    } else if mode == "menu", browserCheckPhase == 5, let child = children.first, let childHost = child.host {
      browserCheckPhase = 6
      childHost.close()
    } else if mode == "menu", browserCheckPhase == 6, children.first?.host == nil {
      browserCheckPhase = 7
      host.checkCloseAllTabs()
    } else if mode == "menu", browserCheckPhase == 7, !host.hasBrowser() {
      browserCheckPhase = 8
      host.checkMenuCommand(false)
    } else if mode == "menu", browserCheckPhase == 8, host.hasBrowser(), !host.tabs().isEmpty {
      browserCheckPhase = 9
      host.checkMenuCommand(true)
    } else if mode == "menu", browserCheckPhase == 9, let child = children.first(where: { $0.host != nil }), let childHost = child.host {
      browserCheckPhase = 10
      childHost.close()
    } else if mode == "menu", browserCheckPhase == 10, children.allSatisfy({ $0.host == nil }) {
      browserCheckPhase = 11
      host.checkCloseAllTabs()
    } else if mode == "menu", browserCheckPhase == 11, !host.hasBrowser() {
      browserCheckPhase = 12
      host.checkMenuCommand(true)
    } else if mode == "menu", browserCheckPhase == 12, host.hasBrowser(), !host.tabs().isEmpty,
              children.allSatisfy({ $0.host == nil }) {
      let stock = host.checkStockBrowsers()
      finishBrowserCheck(ok: stock == 0, values: ["urls_added": browserCheckRows.count,
        "last_selected": true, "ntp_preserved": true, "reused_empty_host": true, "focus_search_unchanged": true,
        "stock_browsers": stock])
    } else if mode == "popup", browserCheckPhase == 2,
              let popup = popups.first?.host,
              let tab = (popup.tabs() as? [any ARTabAPI])?.first, !tab.isLoading, tab.title == "Popup" {
      browserCheckPopupSize = popups.first?.createdSize ?? popup.window().frame.size
      FileHandle.standardError.write(Data("ararat-trace: popup loaded navigation_count=\(tab.navigationCount)\n".utf8))
      browserCheckPhase = 3
      tab.probeCheckOpener()
    } else if mode == "popup", browserCheckPhase == 3,
              let tab = (popups.first?.host?.tabs() as? [any ARTabAPI])?.first, tab.checkOpenerAlive() {
      browserCheckPopupOpenerAlive = true
      browserCheckPhase = 4
      FileHandle.standardError.write(Data("ararat-trace: popup close requested\n".utf8))
      tab.closeCheckPopup()
    } else if mode == "popup", browserCheckPhase == 4, popups.isEmpty,
              let symbol = dlsym(Launcher.handle, "AraratBrowserCount"),
              unsafeBitCast(symbol, to: (@convention(c) () -> UInt).self)() == 1 {
      let stock = host.checkStockBrowsers()
      let rowsUnchanged = snapshot == browserCheckBefore
      let sizeOK = abs(browserCheckPopupSize.width - 400) <= 20 && abs(browserCheckPopupSize.height - 300) <= 40
      devtoolsResults = ["opener_alive": true, "popup_closed": true, "rows_unchanged": rowsUnchanged,
                         "width": browserCheckPopupSize.width, "height": browserCheckPopupSize.height, "stock_browsers": stock]
      guard rowsUnchanged && sizeOK && stock == 0,
            let tab = (host.tabs() as? [any ARTabAPI])?.first else {
        finishBrowserCheck(ok: false, values: devtoolsResults); return
      }
      browserCheckPhase = 5
      tab.openCheckPopup()
    } else if mode == "popup", browserCheckPhase == 5, popups.count == 1,
              let popup = popups.first?.host,
              let tab = (popup.tabs() as? [any ARTabAPI])?.first, !tab.isLoading, tab.title == "Popup" {
      browserCheckPhase = 6
      host.close()
    } else if mode == "newtab", browserCheckPhase == 2 {
      let rows = snapshot.spaces.flatMap { $0.today }
      let matches = ["background", "split", "foreground"].compactMap { name in
        rows.first { $0.url?.contains(name) == true && $0.title == "Ararat \(name)" }
      }
      guard matches.count == 3, rows.count == (browserCheckBefore?.spaces.flatMap { $0.today }.count ?? 0) + 3,
            snapshot.selectedId == matches[2].id else { return }
      browserCheckRows = matches
      browserCheckPhase = 3
      host.checkNavigate("data:text/html,<title>Ararat window</title>", disposition: "window")
      host.checkNavigate("data:text/html,<title>Ararat popup</title>", disposition: "popup")
    } else if mode == "newtab", browserCheckPhase == 3, children.count == 1, popups.count == 1 {
      let stock = host.checkStockBrowsers()
      finishBrowserCheck(ok: stock == 0, values: ["rows_added": browserCheckRows.count,
        "selected": snapshot.selectedId ?? "", "urls": browserCheckRows.map { $0.url ?? "" },
        "titles": browserCheckRows.map(\.title), "app_windows": children.count,
        "popup_hosts": popups.count, "stock_browsers": stock])
    }
  }

  func emptyCheckTick(_ host: any ARWindowHostAPI) {
    if browserCheckPhase == 0, let tab = (host.tabs() as? [any ARTabAPI])?.first,
       let data = tab.title.data(using: .utf8),
       let report = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
       report["windows"] as? Int == 1, report["tabs"] as? Int == 0 {
      emptyProbe = report
      browserCheckPhase = 1
      host.checkCloseAllTabs()
    } else if browserCheckPhase == 1, !host.hasBrowser() {
      emptyRestore = host.checkEmptySessionRestore()
      browserCheckPhase = 10
    } else if browserCheckPhase == 10,
              let symbol = dlsym(Launcher.handle, "AraratBrowserCount") {
      let count = unsafeBitCast(symbol, to: (@convention(c) () -> UInt).self)()
      let stock = host.checkStockBrowsers()
      emptyRestore["browsers_after_wait"] = count
      emptyRestore["stock_after_wait"] = stock
      emptyRestorePassed = emptyRestore["service_available"] as? Bool == true &&
        emptyRestore["restore_eligible"] as? Bool == true && emptyRestore["startup_default"] as? Bool == true &&
        emptyRestore["startup_urls_preserved"] as? Bool == true &&
        emptyRestore["restore_requested"] as? Bool == false && emptyRestore["browsers_before"] as? Int == 0 &&
        emptyRestore["browsers_after"] as? Int == 0 && count == 0 &&
        emptyRestore["stock_before"] as? Int == 0 && emptyRestore["stock_after"] as? Int == 0 && stock == 0
      if count != 0 {
        finishBrowserCheck(ok: false, values: ["session_restore": emptyRestore, "stock_browsers": stock])
        return
      }
      host.checkEnsureEmptyBrowser()
      browserCheckPhase = 2
    } else if browserCheckPhase == 2, host.hasBrowser(), host.tabs().isEmpty {
      let menu = host.checkEmptyMenuValidation()
      emptyMenuCount = (menu["validated"] as? NSNumber)?.uintValue ?? 0
      emptyMenuEnabled = menu["enabled_command_ids"] as? [NSNumber] ?? []
      emptyRowsBefore = Set(snapshot.spaces.flatMap { $0.today + $0.pinned + $0.favorites }.map(\.id))
      browserCheckPhase = 3
      host.checkMenuCommand(false)
    } else if browserCheckPhase == 3, host.hasBrowser(),
              let tab = (host.tabs() as? [any ARTabAPI])?.first,
              let id = tab.itemId, !emptyRowsBefore.contains(id),
              snapshot.spaces.flatMap({ $0.today + $0.pinned + $0.favorites }).contains(where: { $0.id == id }) {
      let stock = host.checkStockBrowsers()
      finishBrowserCheck(ok: stock == 0 && emptyMenuCount > 0 && emptyRestorePassed, values: ["empty_windows_probe": emptyProbe,
        "menu_items_validated": emptyMenuCount, "enabled_command_ids": emptyMenuEnabled,
        "session_restore": emptyRestore, "new_tab": true, "new_tab_row_id": id,
        "command_bar_available": false, "stock_browsers": stock])
    }
  }

  func devtoolsScreenPixels(_ host: any ARWindowHostAPI, state: [String: Any], name: String) -> String? {
    let card = NSRectFromString(state["card_frame"] as? String ?? "")
    let page = NSRectFromString(state["page_frame"] as? String ?? "")
    guard card.width > page.width + 40, page.width > 40,
          abs(card.minX - page.minX) < 2, abs(card.minY - page.minY) < 2, abs(card.height - page.height) < 2,
          let path = promptScreenScreenshot(host.window(), name: "devtools-\(name)", withoutShadow: true),
          let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let image = NSBitmapImageRep(data: data) else { return nil }
    let window = host.window()
    let scaleX = CGFloat(image.pixelsWide) / window.frame.width
    let scaleY = CGFloat(image.pixelsHigh) / window.frame.height
    func colors(_ rect: NSRect) -> (Set<String>, Int) {
      var result = Set<String>()
      var white = 0
      for x in 1...20 {
        for y in 1...20 {
          let px = Int((rect.minX + rect.width * CGFloat(x) / 21) * scaleX)
          let py = Int((window.frame.height - rect.minY - rect.height * CGFloat(y) / 21) * scaleY)
          guard px >= 0, py >= 0, px < image.pixelsWide, py < image.pixelsHigh,
                let color = image.colorAt(x: px, y: py)?.usingColorSpace(.deviceRGB) else { continue }
          result.insert("\(Int(color.redComponent * 15)),\(Int(color.greenComponent * 15)),\(Int(color.blueComponent * 15))")
          if color.redComponent > 0.9 && color.greenComponent > 0.9 && color.blueComponent > 0.9 { white += 1 }
        }
      }
      return (result, white)
    }
    let tools = NSRect(x: page.maxX, y: card.minY, width: card.maxX - page.maxX, height: card.height)
    guard tools.width > 40, colors(page.insetBy(dx: 10, dy: 10)).1 >= 300,
          colors(tools.insetBy(dx: 10, dy: 10)).0.count >= 4 else { return nil }
    return path
  }

  func devtoolsScreenTick(_ host: any ARWindowHostAPI) {
    let state = host.checkDevToolsState()
    let window = host.window()
    let card = NSRectFromString(state["card_frame"] as? String ?? "")
    let page = NSRectFromString(state["page_frame"] as? String ?? "")
    let expected = NSRectFromString(state["strategy_page_frame"] as? String ?? "")
    let tools = NSRectFromString(state["devtools_frame"] as? String ?? "")
    let shared = CommandLine.arguments.contains("--ararat-compositor=c2")
    let docked = state["docked"] as? Bool == true && state["devtools_attached"] as? Bool == true &&
      card.width > 0 && tools == card && page == expected && page.width < card.width && state["page_above"] as? Bool == true &&
      (!shared || (state["page_hit"] as? Bool == true && state["devtools_hit"] as? Bool == true))
    if browserCheckPhase >= 2 && browserCheckPhase <= 5 && !devtoolsScreenReading {
      devtoolsScreenReading = true
      let requestedPhase = browserCheckPhase
      host.checkDevToolsFrontend { [weak self] json in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.devtoolsScreenReading = false
          guard self.browserCheckPhase == requestedPhase else { return }
          if let data = json.data(using: .utf8), let values = try? JSONDecoder().decode([String: Bool].self, from: data) {
            self.devtoolsScreenFrontend = values
          }
        }
      }
    }
    func key(_ text: String, code: UInt16, flags: NSEvent.ModifierFlags = []) {
      if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
        characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code) { NSApp.sendEvent(event) }
    }
    switch browserCheckPhase {
    case 0:
      guard let row = sliceRows.first, let url = row.url else { return }
      browserCheckSeedID = row.id
      browserCheckPhase = 1
      adapter?.select(id: row.id, url: url)
    case 1:
      guard sliceActive == browserCheckSeedID, let tab = (host.tabs() as? [any ARTabAPI])?.first,
            !tab.isLoading, tab.navigationCount > 0, window.isKeyWindow else { return }
      browserCheckPhase = 2
      host.checkOpenDevTools()
    case 2:
      guard docked, devtoolsScreenFrontend["drawer"] == false, devtoolsScreenFrontend["search"] == false,
            let path = devtoolsScreenPixels(host, state: state, name: "initial"), host.checkFocusDevTools() else { return }
      devtoolsResults["initial_screenshot"] = path
      devtoolsResults["focused"] = true
      devtoolsScreenFrontend = [:]
      browserCheckPhase = 3
      key("\u{1b}", code: 53)
    case 3:
      guard devtoolsScreenFrontend["drawer"] == true else { return }
      devtoolsResults["escape_drawer"] = true
      devtoolsScreenFrontend = [:]
      browserCheckPhase = 4
      key("\u{1b}", code: 53)
    case 4:
      guard devtoolsScreenFrontend["drawer"] == false, host.checkFocusDevTools() else { return }
      devtoolsScreenFrontend = [:]
      browserCheckPhase = 5
      key("f", code: 3, flags: .command)
    case 5:
      guard devtoolsScreenFrontend["search"] == true else { return }
      devtoolsResults["command_f_search"] = true
      devtoolsScreenOriginalSize = card.size
      browserCheckPhase = 6
      window.setFrame(NSRect(x: window.frame.minX, y: window.frame.minY, width: window.frame.width + 100, height: window.frame.height + 80), display: true)
    case 6:
      guard docked, card.size != devtoolsScreenOriginalSize,
            let path = devtoolsScreenPixels(host, state: state, name: "resized") else { return }
      devtoolsResults["resize_screenshot"] = path
      guard host.checkSetDevToolsDocked(false) else { finishBrowserCheck(ok: false, values: ["undock_request": false]); return }
      browserCheckPhase = 7
    case 7:
      guard state["docked"] as? Bool == false, host.checkDevToolsHostCount() == 1 else { return }
      guard host.checkSetDevToolsDocked(true) else { finishBrowserCheck(ok: false, values: ["redock_request": false]); return }
      browserCheckPhase = 8
    case 8:
      guard docked, host.checkDevToolsHostCount() == 0,
            let path = devtoolsScreenPixels(host, state: state, name: "redocked") else { return }
      devtoolsResults["redock_screenshot"] = path
      finishBrowserCheck(ok: host.checkStockBrowsers() == 0, values: devtoolsResults)
    default: break
    }
  }

  func devtoolsCheckTick(_ host: any ARWindowHostAPI) {
    let state = host.checkDevToolsState()
    let tabs = (host.tabs() as? [any ARTabAPI]) ?? []
    let card = NSRectFromString(state["card_frame"] as? String ?? "")
    let page = NSRectFromString(state["page_frame"] as? String ?? "")
    let tools = NSRectFromString(state["devtools_frame"] as? String ?? "")
    let expected = NSRectFromString(state["strategy_page_frame"] as? String ?? "")
    let docked = state["docked"] as? Bool == true && state["devtools_attached"] as? Bool == true &&
      ((state["hook_count"] as? NSNumber)?.intValue ?? 0) >= 1 && card.width > 0 && card.height > 0 &&
      tools == card && page == expected && page.width < card.width && state["page_above"] as? Bool == true
    let fullPage = card.width > 0 && page == card && state["devtools_attached"] as? Bool == false
    let hidden = !host.window().isVisible && popups.allSatisfy { $0.host?.window().isVisible == false }
    let front = commandOutput("/usr/bin/lsappinfo", ["front"])
    guard let initialFront = devtoolsFrontBefore, !initialFront.isEmpty, let front, !front.isEmpty else {
      finishBrowserCheck(ok: false, values: ["front_unavailable": true]); return
    }
    if !hidden || front != initialFront || host.checkStockBrowsers() != 0 {
      finishBrowserCheck(ok: false, values: ["hidden": hidden, "front_unchanged": front == initialFront,
                                             "stock_browsers": host.checkStockBrowsers()]); return
    }
    switch browserCheckPhase {
    case 0:
      guard let row = sliceRows.first, let url = row.url else { return }
      browserCheckSeedID = row.id
      devtoolsInitialHosts = children.count + popups.count
      browserCheckPhase = 1
      adapter?.select(id: row.id, url: url)
    case 1:
      guard sliceActive == browserCheckSeedID, let tab = tabs.first(where: { $0.itemId == browserCheckSeedID }),
            !tab.isLoading, tab.navigationCount > 0 else { return }
      devtoolsFirstLive = tab.liveId
      browserCheckPhase = 2
      host.checkOpenDevTools()
    case 2:
      guard docked, host.checkDevToolsHostCount() == 0, children.count + popups.count == devtoolsInitialHosts else { return }
      devtoolsResults.merge(state) { _, new in new }
      devtoolsResults["initial_docked"] = true
      devtoolsResults["host_count_unchanged"] = true
      browserCheckPhase = 3
      host.checkNavigate("about:blank", disposition: "foreground")
    case 3:
      guard let second = tabs.first(where: { $0.liveId != devtoolsFirstLive }), let item = second.itemId,
            host.activeItemId() == item, fullPage else { return }
      let firstState = host.checkDevToolsTabState(devtoolsFirstLive)
      guard firstState["exists"] as? Bool == true, firstState["hidden"] as? Bool == true,
            firstState["in_card"] as? Bool == false else { return }
      devtoolsSecondLive = second.liveId
      devtoolsResults["background_hidden"] = true
      browserCheckPhase = 4
      if let first = tabs.first(where: { $0.liveId == devtoolsFirstLive }), let item = first.itemId {
        adapter?.select(id: item, url: first.url)
      }
    case 4:
      guard host.activeItemId() == browserCheckSeedID, docked else { return }
      devtoolsResults["tab_restored"] = true
      guard host.checkSetDevToolsDocked(false) else { finishBrowserCheck(ok: false, values: ["undock_request": false]); return }
      browserCheckPhase = 5
    case 5:
      guard state["docked"] as? Bool == false, host.checkDevToolsHostCount() == 1,
            children.count + popups.count == devtoolsInitialHosts + 1 else { return }
      devtoolsResults["undocked_host"] = true
      guard host.checkSetDevToolsDocked(true) else { finishBrowserCheck(ok: false, values: ["redock_request": false]); return }
      browserCheckPhase = 6
    case 6:
      guard host.checkDevToolsHostCount() == 0, children.count + popups.count == devtoolsInitialHosts, docked else { return }
      devtoolsResults["redocked"] = true
      browserCheckPhase = 7
      host.checkCloseDevTools()
    case 7:
      guard fullPage, state["docked"] as? Bool == false else { return }
      devtoolsResults["closed_full_page"] = true
      browserCheckPhase = 8
      host.checkOpenDevTools()
    case 8:
      guard docked, let first = tabs.first(where: { $0.liveId == devtoolsFirstLive }), let item = first.itemId else { return }
      browserCheckPhase = 9
      adapter?.close(id: item)
    case 9:
      guard !tabs.contains(where: { $0.liveId == devtoolsFirstLive }),
            tabs.contains(where: { $0.liveId == devtoolsSecondLive }), fullPage,
            host.checkDevToolsHostCount() == 0 else { return }
      devtoolsResults["inspected_tab_closed"] = true
      guard host.checkInspectElement() else { finishBrowserCheck(ok: false, values: ["inspect_request": false]); return }
      browserCheckPhase = 10
    case 10:
      guard docked else { return }
      devtoolsResults["inspect_docked"] = true
      browserCheckPhase = 11
      host.checkCloseDevTools()
    case 11:
      guard fullPage, state["docked"] as? Bool == false else { return }
      browserCheckPhase = 12
      host.checkOpenDevTools()
    case 12:
      guard docked, let rows = captureCheckRows() else { return }
      guard quitBefore == rows else { quitBefore = rows; return }
      devtoolsResults["open_at_quit"] = true
      quitStyleMask = host.window().styleMask.rawValue
      quitMode = "devtools"
      quitPhase = 3
      browserCheckPhase = 13
      FileHandle.standardError.write(Data("ararat-trace: devtools terminate with frontend open\n".utf8))
      NSApp.terminate(nil)
    default: break
    }
  }

  func preparePromptFixture(_ host: any ARWindowHostAPI, name: String) -> Bool {
    if browserCheckPhase == 0 {
      guard promptFixturePort != nil, let row = sliceRows.first, let url = row.url else { return false }
      browserCheckSeedID = row.id
      browserCheckPhase = -1
      FileHandle.standardError.write(Data("ararat-trace: \(name) seed-select id=\(row.id)\n".utf8))
      adapter?.select(id: row.id, url: url)
      return false
    }
    if browserCheckPhase == -1 {
      guard let port = promptFixturePort, sliceActive == browserCheckSeedID,
            let tab = (host.tabs() as? [any ARTabAPI])?.first,
            tab.itemId == browserCheckSeedID, !tab.isLoading, tab.navigationCount > 0 else { return false }
      let url = "http://127.0.0.1:\(port)/\(name)"
      FileHandle.standardError.write(Data("ararat-trace: \(name) tab-ready\n".utf8))
      FileHandle.standardError.write(Data("ararat-trace: \(name) open-fixture url=\(url)\n".utf8))
      host.checkNavigate(url, disposition: "current")
      browserCheckPhase = 1
      return false
    }
    return true
  }

  func permissionCheckTick(_ host: any ARWindowHostAPI) {
    guard preparePromptFixture(host, name: "permissions") else { return }
    guard let tab = (host.tabs() as? [any ARTabAPI])?.first else { return }
    if browserCheckPhase >= 2 && !permissionReadPending {
      permissionReadPending = true
      tab.checkPermissionResults { [weak self] json in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.permissionReadPending = false
          if let data = json.data(using: .utf8), let values = try? JSONDecoder().decode([String: String].self, from: data) {
            self.permissionResults = values
          }
        }
      }
    }
    switch browserCheckPhase {
    case 1:
      guard tab.url.contains("/permissions"), !tab.isLoading else { return }
      tab.checkRequestPermission(0)
      browserCheckPhase = 2
    case 2:
      guard tab.checkPermissionShownCount() == 1, tab.checkPermissionDecision(0) else { return }
      browserCheckPhase = 3
    case 3:
      guard permissionResults["notifications"] == "granted", !tab.checkPermissionPending() else { return }
      tab.checkRequestPermission(1)
      browserCheckPhase = 4
    case 4:
      guard tab.checkPermissionShownCount() == 2, tab.checkPermissionDecision(2) else { return }
      browserCheckPhase = 5
    case 5:
      guard permissionResults["location"] == "1", !tab.checkPermissionPending() else { return }
      tab.checkRequestPermission(2)
      browserCheckPhase = 6
    case 6:
      guard tab.checkPermissionShownCount() == 3, tab.checkPermissionDecision(3) else { return }
      browserCheckPhase = 7
    case 7:
      guard permissionResults["midiResult"] == "NotAllowedError", permissionResults["midiState"] == "prompt",
            !tab.checkPermissionPending() else { return }
      let stock = host.checkStockBrowsers()
      finishBrowserCheck(ok: stock == 0 && tab.checkPermissionShownCount() == 3,
        values: ["notifications": "granted", "location": "1", "midi_result": "NotAllowedError",
                 "midi_state": "prompt", "prompt_shown": tab.checkPermissionShownCount(),
                 "pending": false, "stock_browsers": stock])
    default: break
    }
  }

  func autofillCheckTick(_ host: any ARWindowHostAPI) {
    guard preparePromptFixture(host, name: "autofill"),
          let tab = (host.tabs() as? [any ARTabAPI])?.first else { return }
    autofillState = tab.checkAutofillState()
    let loaded = autofillState["loaded"] as? Bool == true
    let ready = loaded && autofillState["address_pending"] as? Bool == false && autofillState["card_pending"] as? Bool == false
    let empty = autofillState["addresses"] as? Int == 0 && autofillState["cards"] as? Int == 0
    let formsReady = (autofillState["forms"] as? Int ?? 0) >= 2
    switch browserCheckPhase {
    case 1:
      guard tab.url.contains("/autofill"), !tab.isLoading, ready, formsReady,
            autofillState["address_enabled"] as? Bool == true, autofillState["card_enabled"] as? Bool == true else { return }
      guard empty else { finishBrowserCheck(ok: false, values: ["initial_data_not_empty": true, "data": autofillState]); return }
      tab.checkAutofillAction(0)
      autofillFillTicks = 0
      browserCheckPhase = 2
    case 2, 5:
      autofillFillTicks += 1
      guard autofillFillTicks >= 2 else { return }
      autofillSubmitNavigation = tab.navigationCount
      tab.checkAutofillAction(browserCheckPhase == 2 ? 1 : 3)
      browserCheckPhase += 1
    case 3:
      guard tab.checkAutofillBubble(false, decline: false) else { return }
      autofillAddressShown = true
      guard tab.checkAutofillBubble(false, decline: true) else { return }
      autofillAddressDeclined = true
      browserCheckPhase = 4
    case 4:
      guard tab.navigationCount > autofillSubmitNavigation, !tab.isLoading, ready, formsReady,
            !tab.checkAutofillBubble(false, decline: false) else { return }
      guard empty else { finishBrowserCheck(ok: false, values: ["address_saved": true, "data": autofillState]); return }
      tab.checkAutofillAction(2)
      autofillFillTicks = 0
      browserCheckPhase = 5
    case 6:
      guard tab.checkAutofillBubble(true, decline: false) else { return }
      autofillCardShown = true
      guard tab.checkAutofillBubble(true, decline: true) else { return }
      autofillCardDeclined = true
      browserCheckPhase = 7
    case 7:
      guard tab.navigationCount > autofillSubmitNavigation, !tab.isLoading, ready,
            !tab.checkAutofillBubble(false, decline: false), !tab.checkAutofillBubble(true, decline: false) else { return }
      autofillSettleTicks += 1
      guard autofillSettleTicks >= 10 else { return }
      tab.checkRefreshAutofillData()
      browserCheckPhase = 8
    case 8:
      guard ready else { return }
      let stock = host.checkStockBrowsers()
      finishBrowserCheck(ok: empty && stock == 0, values: ["address_shown": autofillAddressShown,
        "address_declined": autofillAddressDeclined, "card_shown": autofillCardShown,
        "card_declined": autofillCardDeclined, "data": autofillState, "stock_browsers": stock])
    default: break
    }
  }

  func promptScreenScreenshot(_ window: NSWindow, name: String, withoutShadow: Bool = false) -> String? {
    guard let temporary = ProcessInfo.processInfo.environment["TMPDIR"] else { return nil }
    let path = (temporary as NSString).appendingPathComponent("ararat-prompts-\(name)-\(UUID().uuidString).png")
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = ["-x"] + (withoutShadow ? ["-o"] : []) + ["-l\(window.windowNumber)", path]
    do { try task.run(); task.waitUntilExit() } catch { return nil }
    return task.terminationStatus == 0 && FileManager.default.fileExists(atPath: path) ? path : nil
  }

  func rectFields(_ r: NSRect) -> [String: Double] {
    ["x": r.minX, "y": r.minY, "width": r.width, "height": r.height]
  }

  func promptScreenCapture(_ host: any ARWindowHostAPI, name: String) -> [String: Any]? {
    let window = host.window()
    guard let card = promptPageCard,
          let dialog = window.childWindows?.first(where: { $0.isVisible }),
          let path = promptScreenScreenshot(window, name: name),
          let dialogPath = promptScreenScreenshot(dialog, name: "\(name)-dialog") else { return nil }
    let cardFrame = card.convert(card.bounds, to: nil)
    let dialogFrame = window.convertFromScreen(dialog.frame)
    func frame(_ r: NSRect) -> [String: Double] { ["x": r.minX, "y": r.minY, "width": r.width, "height": r.height] }
    return ["shown": true, "host_is_ours": true, "dialog_frame": frame(dialogFrame), "card_frame": frame(cardFrame),
      "inside_card": cardFrame.insetBy(dx: -1, dy: -1).contains(dialogFrame),
      "centered": abs(dialogFrame.midX - cardFrame.midX) <= 2, "screenshot": path, "dialog_screenshot": dialogPath]
  }

  func promptScreenKey(_ window: NSWindow, code: UInt16, characters: String) {
    if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
      context: nil, characters: characters, charactersIgnoringModifiers: characters,
      isARepeat: false, keyCode: code) { NSApp.sendEvent(event) }
  }

  func promptScreenTick(_ host: any ARWindowHostAPI) {
    guard preparePromptFixture(host, name: "permissions"),
          let tab = (host.tabs() as? [any ARTabAPI])?.first else { return }
    if browserCheckPhase >= 3 && !tab.checkIsDialogActive() && !promptScreenReading {
      promptScreenReading = true
      tab.checkDialogResults { [weak self] json in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.promptScreenReading = false
          if let data = json.data(using: .utf8), let result = try? JSONDecoder().decode([String: String].self, from: data) { self.promptScreenResults = result }
        }
      }
    }
    func capture(_ name: String) -> Bool {
      guard tab.checkIsDialogActive(), tab.checkDialogHostIsOurs(), let result = promptScreenCapture(host, name: name) else { return false }
      promptScreenSteps[name] = result
      return true
    }
    switch browserCheckPhase {
    case 1:
      guard NSApp.isActive, host.window().isKeyWindow, tab.url.contains("/permissions"), !tab.isLoading else { return }
      host.activateBrowser()
      tab.checkRequestPermission(1)
      browserCheckPhase = 2
    case 2:
      if promptScreenBlockClicks > 0 && !tab.checkIsDialogActive() {
        browserCheckPhase = 3
        return
      }
      if promptScreenSteps["permission"] == nil, !capture("permission") { return }
      promptScreenBlockTicks += 1
      guard promptScreenBlockTicks == 1 || promptScreenBlockTicks % 6 == 0 else { return }
      let button = tab.checkPermissionBlockButton()
      guard let window = button["window"] as? NSWindow,
            let bounds = (button["frame"] as? NSValue)?.rectValue,
            !bounds.isEmpty else { return }
      let location = NSPoint(x: bounds.midX, y: bounds.midY)
      guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 0, clickCount: 1, pressure: 0) else { return }
      promptScreenSteps["permission"]?["button_frame"] = rectFields(bounds)
      window.sendEvent(down)
      window.sendEvent(up)
      promptScreenBlockClicks += 1
      promptScreenSteps["permission"]?["block_clicks"] = promptScreenBlockClicks
      FileHandle.standardError.write(Data("ararat-trace: prompts permission block mouse sent\n".utf8))
    case 3:
      guard promptScreenResults["location"] == "1", let port = promptFixturePort else { return }
      promptScreenSteps["permission"]?["page_result"] = "1"
      host.checkNavigate("http://127.0.0.1:\(port)/dialogs", disposition: "current")
      browserCheckPhase = 4
    case 4:
      guard tab.url.contains("/dialogs"), !tab.isLoading else { return }
      tab.checkRunJavaScriptDialog(0)
      browserCheckPhase = 5
    case 5:
      guard capture("javascript"), tab.checkAcceptJavaScriptDialog("") else { return }
      browserCheckPhase = 6
    case 6:
      guard promptScreenResults["alert"] == "done", let port = promptFixturePort else { return }
      promptScreenSteps["javascript"]?["page_result"] = "done"
      host.checkNavigate("http://127.0.0.1:\(port)/autofill", disposition: "current")
      browserCheckPhase = 7
    case 7:
      guard tab.url.contains("/autofill"), !tab.isLoading else { return }
      let state = tab.checkAutofillState()
      guard state["loaded"] as? Bool == true, state["address_pending"] as? Bool == false,
            (state["forms"] as? Int ?? 0) >= 2 else { return }
      guard tab.checkScreenAddress(true) else { return }
      promptScreenSeeded = true
      browserCheckPhase = 8
    case 8:
      let state = tab.checkAutofillState()
      guard state["address_pending"] as? Bool == false, state["addresses"] as? Int == 1 else { return }
      promptScreenWindows = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
      tab.focusCheckPage()
      tab.checkScreenFocusAddress()
      browserCheckPhase = 9
    case 9:
      guard promptScreenResults["field"] != nil else { return }
      promptScreenKey(host.window(), code: 125, characters: "\u{f701}")
      browserCheckPhase = 10
    case 10:
      guard (tab.checkAutofillState()["suggestions"] as? Int ?? 0) > 0,
            let popup = NSApp.windows.first(where: { $0.isVisible && !promptScreenWindows.contains($0.windowNumber) && $0.parent == host.window() }),
            let card = promptPageCard, let fieldJSON = promptScreenResults["field"]?.data(using: .utf8),
            let field = try? JSONDecoder().decode([String: Double].self, from: fieldJSON),
            let x = field["x"], let y = field["y"], let width = field["width"], let height = field["height"] else { return }
      let cardFrame = card.convert(card.bounds, to: nil)
      let fieldFrame = NSRect(x: cardFrame.minX + x, y: cardFrame.maxY - y - height, width: width, height: height)
      let popupFrame = host.window().convertFromScreen(popup.frame)
      func frame(_ r: NSRect) -> [String: Double] { ["x": r.minX, "y": r.minY, "width": r.width, "height": r.height] }
      guard let screenshot = promptScreenScreenshot(popup, name: "autofill") else { return }
      promptScreenSteps["autofill"] = ["shown": true, "host_is_ours": popup.parent == host.window(),
        "dialog_frame": frame(popupFrame), "popup_frame": frame(popupFrame), "field_frame": frame(fieldFrame),
        "card_frame": frame(cardFrame), "inside_card": cardFrame.contains(popupFrame),
        "page_result": "suggestions visible", "screenshot": screenshot]
      promptScreenKey(host.window(), code: 53, characters: "\u{1b}")
      guard tab.checkScreenAddress(false) else { return }
      promptScreenSeeded = false
      browserCheckPhase = 11
    case 11:
      let state = tab.checkAutofillState()
      guard state["address_pending"] as? Bool == false, state["addresses"] as? Int == 0, let port = promptFixturePort else { return }
      host.checkNavigate("http://127.0.0.1:\(port)/auth", disposition: "current")
      browserCheckPhase = 12
    case 12:
      guard capture("auth"), tab.checkCloseModalDialogs() else { return }
      browserCheckPhase = 13
    case 13:
      guard promptScreenResults["auth"] == "body", let port = promptFixturePort else { return }
      promptScreenSteps["auth"]?["page_result"] = "body"
      host.checkNavigate("http://localhost:\(port)/webauthn", disposition: "current")
      browserCheckPhase = 14
    case 14:
      guard tab.url.contains("/webauthn"), !tab.isLoading else { return }
      tab.checkScreenWebAuthn(false)
      browserCheckPhase = 15
    case 15:
      guard capture("webauthn_get"), tab.checkCloseModalDialogs() else { return }
      browserCheckPhase = 16
    case 16:
      guard promptScreenResults["get"] == "NotAllowedError" else { return }
      promptScreenSteps["webauthn_get"]?["page_result"] = "NotAllowedError"
      tab.checkScreenWebAuthn(true)
      browserCheckPhase = 17
    case 17:
      guard capture("webauthn_create"), tab.checkCloseModalDialogs() else { return }
      browserCheckPhase = 18
    case 18:
      guard promptScreenResults["create"] == "NotAllowedError" else { return }
      promptScreenSteps["webauthn_create"]?["page_result"] = "NotAllowedError"
      let positionsOK = ["permission", "javascript", "auth", "webauthn_get", "webauthn_create"].allSatisfy {
        promptScreenSteps[$0]?["inside_card"] as? Bool == true && promptScreenSteps[$0]?["centered"] as? Bool == true
      }
      let stock = host.checkStockBrowsers()
      finishBrowserCheck(ok: positionsOK && stock == 0, values: ["steps": promptScreenSteps,
        "page_results": promptScreenResults, "address_removed": true, "bluetooth_tcc_risk": true, "stock_browsers": stock])
    default: break
    }
  }

  func dialogCheckTick(_ host: any ARWindowHostAPI) {
    guard preparePromptFixture(host, name: "dialogs") else { return }
    guard let tab = (host.tabs() as? [any ARTabAPI])?.first else { return }
    if browserCheckPhase >= 3 && !tab.checkIsDialogActive() && !dialogReadPending {
      dialogReadPending = true
      tab.checkDialogResults { [weak self] json in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.dialogReadPending = false
          if let data = json.data(using: .utf8), let values = try? JSONDecoder().decode([String: String].self, from: data) {
            self.dialogResults = values
          }
        }
      }
    }
    if browserCheckPhase == 1 {
      guard tab.url.contains("/dialogs"), !tab.isLoading else { return }
      host.activateBrowser()
      tab.checkRunJavaScriptDialog(0)
      browserCheckPhase = 2
    } else if (2...11).contains(browserCheckPhase) {
      let index = (browserCheckPhase - 2) / 2
      if browserCheckPhase % 2 == 0 {
        guard tab.checkIsDialogActive(), tab.checkDialogHostIsOurs() else { return }
        dialogShown[index] = true
        let accepted = index == 1 || index == 3 || index == 0
        let answered = accepted ? tab.checkAcceptJavaScriptDialog(index == 3 ? "Ararat text" : "") : tab.checkCancelJavaScriptDialog()
        guard answered else { return }
        dialogAnswered[index] = true
        browserCheckPhase += 1
      } else {
        let keys = ["alert", "confirmOk", "confirmCancel", "promptText", "promptCancel"]
        let expected = ["done", "true", "false", "Ararat text", "null"]
        guard !tab.checkIsDialogActive(), dialogResults[keys[index]] == expected[index] else { return }
        if index == 0, let card = promptPageCard {
          dialogCardBefore = card.convert(card.bounds, to: nil)
          var frame = host.window().frame
          frame.size.width += 160
          frame.size.height += 100
          host.window().setFrame(frame, display: false)
          FileHandle.standardError.write(Data("ararat-trace: dialogs resize requested\n".utf8))
          browserCheckPhase = 14
        } else if index < 4 {
          tab.checkRunJavaScriptDialog(index + 1)
          browserCheckPhase += 1
        } else if let port = promptFixturePort {
          dialogResults = [:]
          host.checkNavigate("http://127.0.0.1:\(port)/auth", disposition: "current")
          browserCheckPhase = 12
        }
      }
    } else if browserCheckPhase == 14 {
      guard let card = promptPageCard else { return }
      host.window().contentView?.layoutSubtreeIfNeeded()
      let current = card.convert(card.bounds, to: nil)
      guard current != dialogCardBefore, !current.isEmpty else { return }
      dialogCardAfter = current
      dialogResults.removeValue(forKey: "alert")
      dialogWindowsBefore = Set(NSApp.windows.map(\.windowNumber))
      tab.checkRunJavaScriptDialog(0)
      FileHandle.standardError.write(Data("ararat-trace: dialogs resized card changed; alert requested\n".utf8))
      browserCheckPhase = 15
    } else if browserCheckPhase == 15 {
      guard tab.checkIsDialogActive(), tab.checkDialogHostIsOurs() else { return }
      let windows = NSApp.windows.filter { !dialogWindowsBefore.contains($0.windowNumber) }
      guard windows.count <= 1 else {
        finishBrowserCheck(ok: false, values: ["error": "multiple_new_dialog_windows",
          "windows": windows.map { ["number": $0.windowNumber, "title": $0.title] }]); return
      }
      guard let dialog = windows.first else { return }
      dialogResizedFrame = host.window().convertFromScreen(dialog.frame)
      dialogResizedShown = true
      let inside = dialogCardAfter.insetBy(dx: -1, dy: -1).contains(dialogResizedFrame)
      let centered = abs(dialogResizedFrame.midX - dialogCardAfter.midX) <= 2
      guard inside && centered else {
        finishBrowserCheck(ok: false, values: ["card_before": rectFields(dialogCardBefore),
          "card_after": rectFields(dialogCardAfter), "dialog_frame": rectFields(dialogResizedFrame),
          "inside_card": inside, "centered": centered]); return
      }
      guard tab.checkAcceptJavaScriptDialog("") else { return }
      dialogResizedAnswered = true
      FileHandle.standardError.write(Data("ararat-trace: dialogs resized alert centered and accepted\n".utf8))
      browserCheckPhase = 16
    } else if browserCheckPhase == 16 {
      guard !tab.checkIsDialogActive(), dialogResults["alert"] == "done" else { return }
      tab.checkRunJavaScriptDialog(1)
      browserCheckPhase = 4
    } else if browserCheckPhase == 12 {
      guard tab.checkIsDialogActive(), tab.checkDialogHostIsOurs() else { return }
      authShown = true
      guard tab.checkCloseModalDialogs() else { return }
      authCancelled = true
      browserCheckPhase = 13
    } else if browserCheckPhase == 13 {
      guard !tab.checkIsDialogActive(), tab.url.contains("/auth"), !tab.isLoading,
            dialogResults["auth"] == "body" else { return }
      let stock = host.checkStockBrowsers()
      finishBrowserCheck(ok: stock == 0, values: ["shown": dialogShown, "answered": dialogAnswered,
        "alert": "done", "confirm_ok": "true", "confirm_cancel": "false", "prompt_text": "Ararat text",
        "prompt_cancel": "null", "auth_shown": authShown, "auth_cancelled": authCancelled,
        "auth_body": true, "card_before": rectFields(dialogCardBefore), "card_after": rectFields(dialogCardAfter),
        "dialog_frame": rectFields(dialogResizedFrame), "inside_card": true, "centered": true,
        "stock_browsers": stock])
    }
  }

  func commandOutput(_ path: String, _ arguments: [String]) -> String? {
    let task = Process()
    let pipe = Pipe()
    task.executableURL = URL(fileURLWithPath: path)
    task.arguments = arguments
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    do { try task.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard task.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func handlerProcesses() -> Set<Int>? {
    guard let output = commandOutput("/bin/ps", ["-axo", "pid=,comm="]) else { return nil }
    var result = Set<Int>()
    for line in output.split(separator: "\n") {
      let fields = line.trimmingCharacters(in: .whitespaces).split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
      guard fields.count == 2, let pid = Int(fields[0]) else { continue }
      if URL(fileURLWithPath: String(fields[1])).resolvingSymlinksInPath().path == protocolExecutable { result.insert(pid) }
    }
    return result
  }

  func protocolCandidates() -> [String] {
    var schemes = Set(["tel", "sms", "facetime", "maps", "calshow", "zoommtg", "slack", "vscode", "spotify"])
    let roots = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]
    for root in roots {
      guard let entries = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
      for case let url as URL in entries where url.pathExtension == "app" {
        guard let types = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] else { continue }
        for type in types { schemes.formUnion((type["CFBundleURLSchemes"] as? [String] ?? []).map { $0.lowercased() }) }
      }
    }
    return schemes.sorted()
  }

  func protocolCheckTick(_ host: any ARWindowHostAPI) {
    guard preparePromptFixture(host, name: "protocol") else { return }
    guard let tab = (host.tabs() as? [any ARTabAPI])?.first else { return }
    if browserCheckPhase == 1 {
      guard tab.url.contains("/protocol"), !tab.isLoading else { return }
      for scheme in protocolCandidates() {
        guard let url = URL(string: "\(scheme)://ararat.invalid/"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: url)?.resolvingSymlinksInPath(),
              handler != Bundle.main.bundleURL.resolvingSymlinksInPath(),
              let executable = Bundle(url: handler)?.executableURL?.resolvingSymlinksInPath().path,
              tab.checkProtocol(scheme, launch: false)["eligible"] as? Bool == true else { continue }
        protocolScheme = scheme
        protocolHandler = handler
        protocolExecutable = executable
        break
      }
      guard let handler = protocolHandler else {
        finishBrowserCheck(ok: false, values: ["no_eligible_handler": true, "stock_browsers": host.checkStockBrowsers()]); return
      }
      protocolLaunchObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] notification in
        MainActor.assumeIsolated {
          guard let self, let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
          if app.bundleURL?.resolvingSymlinksInPath() == handler { self.protocolAppLaunchObserved = true }
        }
      }
      guard let front = commandOutput("/usr/bin/lsappinfo", ["front"]), !front.isEmpty,
            let pids = handlerProcesses() else {
        finishBrowserCheck(ok: false, values: ["baseline_unavailable": true, "stock_browsers": host.checkStockBrowsers()]); return
      }
      protocolFrontBefore = front
      protocolPidsBefore = pids
      host.activateBrowser()
      let state = tab.checkProtocol(protocolScheme, launch: true)
      guard state["launched_request"] as? Bool == true, let pref = state["pref"] as? String else {
        finishBrowserCheck(ok: false, values: ["eligibility_changed": true, "stock_browsers": host.checkStockBrowsers()]); return
      }
      protocolPrefBefore = pref
      FileHandle.standardError.write(Data("ararat-trace: protocol scheme=\(protocolScheme) handler=\(handler.path)\n".utf8))
      browserCheckPhase = 2
    } else if browserCheckPhase == 2 || browserCheckPhase == 3 {
      guard let before = protocolPidsBefore, let now = handlerProcesses() else {
        finishBrowserCheck(ok: false, values: ["process_snapshot_unavailable": true, "stock_browsers": host.checkStockBrowsers()]); return
      }
      protocolNewPids.formUnion(now.subtracting(before))
      if browserCheckPhase == 2 {
        guard tab.checkIsDialogActive(), tab.checkDialogHostIsOurs() else { return }
        protocolShown = true
        guard tab.checkCloseModalDialogs() else { return }
        protocolCancelled = true
        browserCheckPhase = 3
      } else {
        guard !tab.checkIsDialogActive() else { return }
        protocolAfterTicks += 1
        guard protocolAfterTicks >= 10 else { return }
        let state = tab.checkProtocol(protocolScheme, launch: false)
        guard let pref = state["pref"] as? String, let front = commandOutput("/usr/bin/lsappinfo", ["front"]), !front.isEmpty else {
          finishBrowserCheck(ok: false, values: ["final_state_unavailable": true, "stock_browsers": host.checkStockBrowsers()]); return
        }
        let unchanged = pref == protocolPrefBefore
        let frontUnchanged = front == protocolFrontBefore
        let noProcess = protocolNewPids.isEmpty && !protocolAppLaunchObserved
        let stock = host.checkStockBrowsers()
        finishBrowserCheck(ok: unchanged && frontUnchanged && noProcess && stock == 0,
          values: ["scheme": protocolScheme, "handler": protocolHandler?.path ?? "", "dialog_shown": protocolShown,
            "cancelled": protocolCancelled, "prefs_unchanged": unchanged, "front_unchanged": frontUnchanged,
            "pref_before": protocolPrefBefore ?? "", "pref_after": pref,
            "front_before": protocolFrontBefore ?? "", "front_after": front, "pids_before": before.sorted(),
            "new_pids": protocolNewPids.sorted(), "app_launch_observed": protocolAppLaunchObserved,
            "no_new_process": noProcess, "stock_browsers": stock])
      }
    }
  }

  func extensionCheckTick(_ host: any ARWindowHostAPI, screen: Bool) {
    func tab(_ profile: String) -> (any ARTabAPI)? {
      let space = profile == "Default" ? "default" : "named"
      guard let id = snapshot.spaces.first(where: { $0.id == space })?.today.first?.id else { return nil }
      return (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == id })
    }
    func screenStateValid(_ shown: String) -> Bool {
      let state = host.checkProfileState()
      guard state["shown"] as? String == shown, state["chrome_last"] as? String == shown,
            state["app_last"] as? String == shown, let rows = state["browsers"] as? [[String: Any]],
            let visible = rows.first(where: { $0["profile"] as? String == shown }),
            let hidden = rows.first(where: { $0["profile"] as? String != shown }) else { return false }
      return visible["visible"] as? Bool == true && visible["active"] as? Bool == true &&
        hidden["visible"] as? Bool == false && hidden["active"] as? Bool == false && hidden["minimized"] as? Bool == false
    }
    func report(_ profile: String) -> [String: Any]? {
      guard let rows = host.checkProfileState()["browsers"] as? [[String: Any]],
            let browser = rows.first(where: { $0["profile"] as? String == profile }),
            let tab = (browser["tabs"] as? [[String: Any]])?.first,
            let title = tab["title"] as? String, let data = title.data(using: .utf8),
            let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
      return value
    }
    func valid(_ report: [String: Any]) -> Bool {
      guard let windows = report["windows"] as? [[String: Any]], windows.count == 1,
            let id = windows.first?["id"] as? Int,
            let windowTabs = windows.first?["tabs"] as? [[String: Any]], windowTabs.count == 1,
            let last = report["last"] as? [String: Any], last["id"] as? Int == id,
            let tabs = report["tabs"] as? [[String: Any]], tabs.count == 1,
            tabs.first?["windowId"] as? Int == id, let tabID = tabs.first?["id"] as? Int,
            let windowTabID = windowTabs.first?["id"] as? Int, tabID == windowTabID else { return false }
      return true
    }
    if browserCheckAttempts % 10 == 0 && browserCheckPhase <= 2 {
      for profile in ["Default", "Profile 1"] where report(profile) == nil {
        tab(profile)?.checkReloadExtensionWindow()
      }
    }
    if browserCheckPhase == 0,
       let row = snapshot.spaces.first(where: { $0.id == "default" })?.today.first, let url = row.url {
      adapter?.select(id: row.id, url: url)
      browserCheckPhase = 1
    } else if browserCheckPhase == 1, report("Default") != nil {
      adapter?.windowHost(host, showProfile: "Profile 1")
      guard let row = snapshot.spaces.first(where: { $0.id == "named" })?.today.first, let url = row.url else { return }
      adapter?.select(id: row.id, url: url)
      browserCheckPhase = 2
    } else if browserCheckPhase == 2, report("Default") != nil, report("Profile 1") != nil {
      FileHandle.standardError.write(Data("ararat-trace: extension-report request profiles=Default,Profile 1 next_phase=20\n".utf8))
      tab("Default")?.checkReportExtensionWindow()
      tab("Profile 1")?.checkReportExtensionWindow()
      browserCheckPhase = 20
    } else if browserCheckPhase == 20, let first = report("Default"), let second = report("Profile 1"),
              first["hash"] as? String == "#report", second["hash"] as? String == "#report", valid(first), valid(second),
              let firstWindows = first["windows"] as? [[String: Any]], let secondWindows = second["windows"] as? [[String: Any]],
              let firstID = firstWindows.first?["id"] as? Int, let secondID = secondWindows.first?["id"] as? Int, firstID != secondID {
      if screen && !screenStateValid("Profile 1") { return }
      FileHandle.standardError.write(Data("ararat-trace: extension-report ready default=\(firstID) profile1=\(secondID) screen=\(screen)\n".utf8))
      profileCheckStates = [first, second]
      guard let probe = tab("Profile 1") else { return }
      if screen {
        probe.checkPrepareExtensionFocus()
        browserCheckPhase = 22
      } else {
        probe.checkPrepareExtensionWindows()
        browserCheckPhase = 25
      }
    } else if !screen, browserCheckPhase == 25, let named = report("Profile 1"),
              named["hash"] as? String == "#prepare-hidden",
              let target = named["targetId"] as? Int, let other = named["otherId"] as? Int,
              target != other, named["focusBefore"] as? Int == other,
              let windows = named["windows"] as? [[String: Any]], windows.count == 2,
              children.count == 1 {
      extensionFocusProbe = named
      adapter?.windowHost(host, showProfile: "Default")
      guard host.profileDirectory() == "Default" else {
        finishBrowserCheck(ok: false, values: ["failed_predicate": "switched_away",
          "switched_away": false, "shown_profile": host.profileDirectory(),
          "profile_windows": extensionFocusProbe, "stock_browsers": host.checkStockBrowsers()])
        return
      }
      extensionSwitchedAway = true
      tab("Profile 1")?.checkFocusExtensionWindow()
      browserCheckPhase = 26
    } else if !screen, browserCheckPhase == 26, let named = report("Profile 1"),
              named["hash"] as? String == "#focus", named["focusResult"] as? Bool == true,
              host.profileDirectory() == "Profile 1", let target = named["targetId"] as? Int,
              let other = named["otherId"] as? Int, target != other,
              let windows = named["windows"] as? [[String: Any]], windows.count == 2,
              let last = named["last"] as? [String: Any], last["id"] as? Int == target,
              let current = named["current"] as? [String: Any], current["id"] as? Int == target,
              let byID = named["byId"] as? [String: Any], byID["id"] as? Int == target,
              byID["type"] as? String == "normal",
              windows.allSatisfy({ $0["type"] as? String == "normal" }),
              let byIDTabs = byID["tabs"] as? [[String: Any]], byIDTabs.count == 1,
              host.checkProfileState()["chrome_last"] as? String == "Profile 1",
              host.checkProfileState()["app_last"] as? String == "Profile 1" {
      extensionFocusProbe = named
      children.first?.host?.close()
      browserCheckPhase = 27
    } else if !screen, browserCheckPhase == 27, children.isEmpty {
      finishBrowserCheck(ok: host.checkStockBrowsers() == 0, values: ["profiles": profileCheckStates,
        "profile_windows": extensionFocusProbe, "switched_away": extensionSwitchedAway,
        "chrome_last": "Profile 1", "app_last": "Profile 1",
        "stock_browsers": host.checkStockBrowsers()])
    } else if browserCheckPhase == 22, let named = report("Profile 1"),
              let before = named["focusBefore"] as? Int, let other = named["otherId"] as? Int,
              let target = named["targetId"] as? Int, target != other, before == other,
              children.count == 1 {
      extensionFocusProbe = named
      adapter?.windowHost(host, showProfile: "Default")
      if screen { host.window().makeKeyAndOrderFront(nil) }
      browserCheckPhase = 21
    } else if browserCheckPhase == 21 {
      if screen && !screenStateValid("Default") { return }
      guard let named = snapshot.spaces.first(where: { $0.id == "named" })?.today.first,
            let tab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == named.id }) else { return }
      tab.checkFocusExtensionWindow()
      browserCheckPhase = 3
    } else if browserCheckPhase == 3, host.profileDirectory() == "Profile 1",
              let named = report("Profile 1"), named["focusResult"] as? Bool == true,
              named["targetId"] as? Int == extensionFocusProbe["targetId"] as? Int,
              named["otherId"] as? Int == extensionFocusProbe["otherId"] as? Int {
      if screen && !screenStateValid("Profile 1") { return }
      extensionFocusProbe = named
      children.first?.host?.close()
      browserCheckPhase = 23
    } else if browserCheckPhase == 23, children.isEmpty {
      if !screen {
        finishBrowserCheck(ok: host.checkStockBrowsers() == 0, values: ["profiles": profileCheckStates,
          "focused_hidden_profile": true, "focus_probe": extensionFocusProbe, "stock_browsers": host.checkStockBrowsers()])
      } else {
        NSApp.deactivate()
        browserCheckPhase = 4
      }
    } else if screen, browserCheckPhase == 4, let named = report("Profile 1"),
              let events = named["focusEvents"] as? [Int], events.contains(-1),
              let windows = named["windows"] as? [[String: Any]],
              let id = windows.first?["id"] as? Int, events.contains(id) {
      NSApp.activate(ignoringOtherApps: true)
      host.window().makeKeyAndOrderFront(nil)
      browserCheckPhase = 5
    } else if screen, browserCheckPhase == 5, host.window().isKeyWindow {
      if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.window().windowNumber,
          context: nil, characters: "N", charactersIgnoringModifiers: "n", isARepeat: false, keyCode: 45) {
        NSApp.sendEvent(event)
      }
      browserCheckPhase = 6
    } else if screen, browserCheckPhase == 6, let popup = popups.first?.host,
              (popup.checkProfileState()["browsers"] as? [[String: Any]])?.first?["off_the_record"] as? Bool == true {
      finishBrowserCheck(ok: host.checkStockBrowsers() == 0, values: ["profiles": profileCheckStates,
        "focused_hidden_profile": true, "focus_probe": extensionFocusProbe, "focus_none": true, "menu_incognito": true, "stock_browsers": host.checkStockBrowsers()])
    }
  }

  func incognitoCheckTick(_ host: any ARWindowHostAPI) {
    if browserCheckPhase == 0,
       let row = snapshot.spaces.first(where: { $0.id == "default" })?.today.first,
       let url = row.url {
      browserCheckSeedID = row.id
      adapter?.select(id: row.id, url: url)
      browserCheckPhase = 1
    } else if browserCheckPhase == 1, sliceActive == browserCheckSeedID, !host.tabs().isEmpty {
      browserCheckBefore = snapshot
      guard let rows = captureCheckRows() else { return }
      quitBefore = rows
      host.checkCreateIncognito()
      browserCheckPhase = 2
    } else if browserCheckPhase == 2, let popup = popups.first?.host,
              (popup.checkProfileState()["browsers"] as? [[String: Any]])?.first?["off_the_record"] as? Bool == true {
      host.checkNavigateOffTheRecord()
      browserCheckPhase = 3
    } else if browserCheckPhase == 3, popups.contains(where: { popup in
      (popup.host?.tabs() as? [any ARTabAPI])?.contains(where: { $0.title == "ararat-otr-navigation" }) == true
    }) {
      let stock = host.checkStockBrowsers()
      let after = captureCheckRows()
      let rowsUnchanged = snapshot == browserCheckBefore && quitBefore != nil && after == quitBefore
      finishBrowserCheck(ok: rowsUnchanged && stock == 0, values: ["off_the_record": true,
        "off_the_record_navigation": true, "rows_unchanged": rowsUnchanged,
        "rows_before": quitBefore ?? [], "rows_after": after ?? [], "stock_browsers": stock])
    }
  }

  func profileCheckTick(_ host: any ARWindowHostAPI) {
    func select(_ space: String) -> Bool {
      guard let row = snapshot.spaces.first(where: { $0.id == space })?.today.first, let url = row.url else { return false }
      adapter?.select(id: row.id, url: url)
      return true
    }
    let state = host.checkProfileState()
    let browsers = state["browsers"] as? [[String: Any]] ?? []
    let stock = host.checkStockBrowsers()
    if browserCheckPhase == 0 {
      if select("default") { browserCheckPhase = 1 }
    } else if browserCheckPhase == 1, browsers.count == 1, !host.tabs().isEmpty {
      adapter?.windowHost(host, showProfile: "Profile 1")
      if select("named") { browserCheckPhase = 2 }
    } else if browserCheckPhase == 2, browsers.count == 2, host.tabs().count == 2 {
      host.checkCreateRestoreBrowser()
      host.checkActivateShownProfile()
      profileCheckStates.append(host.checkProfileState())
      host.checkCookieIsolation()
      adapter?.windowHost(host, showProfile: "Default")
      host.checkActivateShownProfile()
      browserCheckPhase = 3
    } else if browserCheckPhase == 3, state["shown"] as? String == "Default" {
      profileCheckStates.append(state)
      profileCheckPointer = browsers.first(where: { $0["profile"] as? String == "Profile 1" })?["profile_pointer"] as? String
      host.checkCloseTabs(forProfile: "Profile 1")
      browserCheckPhase = 4
    } else if browserCheckPhase == 4, browsers.count == 1,
              let loaded = state["loaded_profiles"] as? [String], loaded.contains("Profile 1"),
              (host.checkCookieState()["done"] as? Bool) == true {
      profileCheckLoadedAfterClose = true
      adapter?.windowHost(host, showProfile: "Profile 1")
      guard let adapter else { return }
      let row: Row? = adapter.session.queue.sync {
        guard let store = adapter.session.store,
              let current = try? store.createTab(windowId: windowID, url: "about:blank"),
              let selected = current.selectedId else { return nil }
        return current.spaces.flatMap(\.today).first { $0.id == selected }
      }
      if let row, let url = row.url {
        adapter.select(id: row.id, url: url)
        browserCheckPhase = 5
      }
    } else if browserCheckPhase == 5, browsers.count == 2,
              state["devtools_destroyed"] as? Bool == true,
              let named = browsers.first(where: { $0["profile"] as? String == "Profile 1" }),
              let namedTabs = named["tabs"] as? [[String: Any]], !namedTabs.isEmpty {
      host.checkActivateShownProfile()
      let state = host.checkProfileState()
      let cookies = host.checkCookieState()
      let names = Set(browsers.compactMap { $0["profile"] as? String })
      let hidden = browsers.first { $0["profile"] as? String == "Default" }
      let switchesOK = profileCheckStates.count == 2 && profileCheckStates.allSatisfy { state in
        guard let shown = state["shown"] as? String,
              state["chrome_last"] as? String == shown, state["app_last"] as? String == shown,
              let windows = state["browsers"] as? [[String: Any]], windows.count == 2,
              let hidden = windows.first(where: { $0["profile"] as? String != shown }) else { return false }
        return hidden["visible"] as? Bool == false && hidden["minimized"] as? Bool == false
      }
      let correct = names == Set(["Default", "Profile 1"]) &&
        (hidden?["visible"] as? Bool) == false && (hidden?["minimized"] as? Bool) == false &&
        (state["chrome_last"] as? String) == "Profile 1" && (state["app_last"] as? String) == "Profile 1" &&
        (cookies["set"] as? Bool) == true && (cookies["isolated"] as? Bool) == true && switchesOK && stock == 0 &&
        profileCheckPointer != nil && profileCheckPointer == named["profile_pointer"] as? String &&
        state["restore_omitted"] as? Bool == true && state["devtools_destroyed"] as? Bool == true
      guard let tabs = host.tabs() as? [any ARTabAPI], tabs.count == 2,
            tabs.allSatisfy({ !$0.isLoading }) else { return }
      profileCheckStates.append(state)
      profileCheckPassed = correct
      profileCheckResult = ["states": profileCheckStates, "cookie": cookies,
        "loaded_after_hidden_close": profileCheckLoadedAfterClose, "profile_pointer_before": profileCheckPointer ?? "", "restore_omitted": state["restore_omitted"] ?? false, "devtools_destroyed": state["devtools_destroyed"] ?? false, "stock_browsers": stock, "reopened": true]
      for tab in tabs { tab.prepareCheckBeforeUnload() }
      browserCheckPhase = 6
    } else if browserCheckPhase == 6, let tabs = host.tabs() as? [any ARTabAPI], tabs.count == 2,
              tabs.allSatisfy({ $0.checkHasBeforeUnload() }), let rows = captureCheckRows() {
      profileCloseBefore = rows
      host.configureProfileCloseCheck(2)
      browserCheckPhase = 7
      host.close()
    } else if browserCheckPhase == 7 {
      let closeState = host.checkProfileCloseState()
      guard closeState["dialogs"] as? Int == 2, closeState["closing"] as? Bool == false else { return }
      let after = captureCheckRows()
      let rowsKept = after?.filter { $0.first != "window" } == profileCloseBefore?.filter { $0.first != "window" } && after != nil
      let valid = closeState["browsers"] as? Int == 2 && closeState["closed"] as? Bool == false &&
        closeState["close_cancelled"] as? Int == 1 &&
        closeState["beforeunload_profiles"] as? [String] == ["Default", "Profile 1"] && rowsKept
      profileCloseCancelled = closeState.merging(["rows_unchanged": rowsKept, "host_open": true]) { _, new in new }
      profileCheckPassed = profileCheckPassed && valid
      host.configureProfileCloseCheck(0)
      browserCheckPhase = 8
      host.close()
    }
  }

  func extensionScreenTick(_ host: any ARWindowHostAPI) {
    if browserCheckPhase == 0, let row = sliceRows.first, let url = row.url {
      browserCheckPhase = 1
      adapter?.select(id: row.id, url: url)
      return
    }
    guard let tab = (host.tabs() as? [any ARTabAPI])?.first, !tab.isLoading,
          tab.navigationCount > 0, let button = container?.sidebarExtensionsButton else { return }
    let state = host.checkExtensionActionState()
    if browserCheckPhase == 1, host.window().isKeyWindow,
       host.extensionActions().contains(where: { $0["id"] as? String == "kmgaadhbnkendcanjninlfmfgehagggl" }) {
      guard let container, let screen = NSScreen.screens.first else { return }
      let window = host.window()
      let edge = NSPoint(x: window.frame.minX + 2, y: window.frame.midY)
      guard CGWarpMouseCursorPosition(CGPoint(x: edge.x, y: screen.frame.maxY - edge.y)) == .success else { return }
      container.toggleSidebar()
      if let event = NSEvent.mouseEvent(with: .mouseMoved, location: window.convertPoint(fromScreen: edge), modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
          eventNumber: 0, clickCount: 0, pressure: 0) { NSApp.sendEvent(event) }
      browserCheckPhase = 5
    } else if browserCheckPhase == 5, container?.sidebarState == "floating" {
      guard let container else { return }
      let buttonFrame = host.window().convertToScreen(button.convert(button.bounds, to: nil))
      devtoolsResults["button_frame"] = rectFields(buttonFrame)
      guard let browserScreenshot = promptScreenScreenshot(host.window(), name: "extensions-floating", withoutShadow: true) else { return }
      devtoolsResults["floating_screenshot"] = browserScreenshot
      devtoolsResults["sidebar_state_at_invocation"] = container.sidebarState
      devtoolsResults["stay_right"] = host.window().frame.minX + 5 + container.resizeHandle.sidebarWidth + 72
      host.checkExtensionAction(5)
      linkMenuObserver = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] notification in
        guard let menu = notification.object as? NSMenu,
              menu.items.count == 1, menu.items[0].representedObject as? String == "kmgaadhbnkendcanjninlfmfgehagggl" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
          guard let self else { return }
          if let menuWindow = NSApp.windows.first(where: {
            $0.isVisible && $0 !== self.host?.window() && NSStringFromClass(type(of: $0)).localizedCaseInsensitiveContains("menu")
          }), let path = self.promptScreenScreenshot(menuWindow, name: "extensions-menu", withoutShadow: true),
             let image = NSImage(contentsOfFile: path), image.size.width > 0, image.size.height > 0 {
            self.devtoolsResults["menu_screenshot"] = path
            self.devtoolsResults["menu_window_id"] = menuWindow.windowNumber
            self.devtoolsResults["menu_frame"] = self.rectFields(menuWindow.frame)
            guard let stayRight = self.devtoolsResults["stay_right"] as? CGFloat,
                  let screen = NSScreen.screens.first else { return }
            let point = NSPoint(x: menuWindow.frame.maxX - 20, y: menuWindow.frame.midY)
            guard point.x > stayRight, menuWindow.frame.contains(point),
                  CGWarpMouseCursorPosition(CGPoint(x: point.x, y: screen.frame.maxY - point.y)) == .success else { return }
            self.devtoolsResults["selection_point"] = ["x": point.x, "y": point.y]
            self.devtoolsResults["sidebar_state_during_menu"] = self.container?.sidebarState ?? "missing"
            self.linkMenuChosen = true
            for type in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
              if let event = NSEvent.mouseEvent(with: type, location: menuWindow.convertPoint(fromScreen: point), modifierFlags: [],
                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: menuWindow.windowNumber, context: nil,
                  eventNumber: 0, clickCount: type == .mouseMoved ? 0 : 1, pressure: type == .mouseMoved ? 0 : 1) {
                NSApp.postEvent(event, atStart: false)
              }
            }
          }
        }
      }
      browserCheckPhase = 2
      let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
      for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: host.window().windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { NSApp.sendEvent(event) }
      }
    } else if browserCheckPhase == 2, linkMenuChosen, state["loaded"] as? Int == 1,
              let popup = state["window"] as? NSWindow, popup.isVisible,
              let screenshot = promptScreenScreenshot(popup, name: "extensions-popup", withoutShadow: true) {
      guard let fields = devtoolsResults["button_frame"] as? [String: Double],
            let x = fields["x"], let y = fields["y"], let width = fields["width"], let height = fields["height"] else { return }
      let buttonFrame = NSRect(x: x, y: y, width: width, height: height)
      let popupFrame = popup.frame
      devtoolsResults["popup_frame"] = rectFields(popupFrame)
      devtoolsResults["menu_shown"] = linkMenuChosen
      devtoolsResults["popup_screenshot"] = screenshot
      devtoolsResults["placed_below"] = popupFrame.maxY <= buttonFrame.minY + 8
      devtoolsResults["anchor_gap"] = buttonFrame.minY - popupFrame.maxY
      devtoolsResults["aligned_with_button"] = popupFrame.minX <= buttonFrame.midX && popupFrame.maxX >= buttonFrame.midX
      devtoolsResults["sidebar_state_after_selection"] = container?.sidebarState ?? "missing"
      browserCheckPhase = 3
      host.checkExtensionAction(1)
    } else if browserCheckPhase == 3, state["destroyed"] as? Int == 1 {
      browserCheckPhase = 4
      tab.checkOpenActionPopup()
    } else if browserCheckPhase == 4, state["loaded"] as? Int == 2 {
      let stock = host.checkStockBrowsers()
      devtoolsResults["api_popup"] = true
      devtoolsResults["stock_browsers"] = stock
      finishBrowserCheck(ok: stock == 0 && devtoolsResults["placed_below"] as? Bool == true && (devtoolsResults["anchor_gap"] as? CGFloat ?? .infinity) <= 24 && devtoolsResults["aligned_with_button"] as? Bool == true && devtoolsResults["menu_screenshot"] != nil && devtoolsResults["floating_screenshot"] != nil && devtoolsResults["sidebar_state_at_invocation"] as? String == "floating" && devtoolsResults["sidebar_state_during_menu"] as? String == "floating" && devtoolsResults["sidebar_state_after_selection"] as? String == "hidden", values: devtoolsResults)
    }
  }

  func extensionActionCheckTick(_ host: any ARWindowHostAPI) {
    if browserCheckPhase == 0, let row = sliceRows.first, let url = row.url {
      browserCheckPhase = 1
      adapter?.select(id: row.id, url: url)
      return
    }
    guard let tab = (host.tabs() as? [any ARTabAPI])?.first, !tab.isLoading,
          tab.navigationCount > 0 else { return }
    let state = host.checkExtensionActionState()
    let loaded = state["loaded"] as? Int ?? 0
    let destroyed = state["destroyed"] as? Int ?? 0
    if browserCheckPhase == 1 {
      guard let action = host.extensionActions().first(where: { $0["id"] as? String == "kmgaadhbnkendcanjninlfmfgehagggl" }),
            action["name"] as? String == "Ararat windows check with a wide extension menu entry for floating sidebar selection",
            let icon = action["icon"] as? NSImage, icon.isValid else { return }
      browserCheckPhase = 2
      host.checkExtensionAction(0)
    } else if browserCheckPhase == 2, loaded == 1,
              state["title"] as? String == "Ararat extension popup",
              state["storage"] as? String == "Ararat extension popup",
              state["anchor"] as? Bool == true {
      browserCheckPhase = 3
      host.checkExtensionAction(1)
    } else if browserCheckPhase == 3, destroyed == 1 {
      browserCheckPhase = 4
      host.checkExtensionAction(2)
    } else if browserCheckPhase == 4, loaded == 2 {
      browserCheckPhase = 5
      host.checkExtensionAction(3)
    } else if browserCheckPhase == 5, destroyed == 2 {
      browserCheckPhase = 6
      host.checkExtensionAction(4)
    } else if browserCheckPhase == 6, loaded == 3, state["api_callback"] as? Bool == true {
      let stock = host.checkStockBrowsers()
      host.checkExtensionAction(1)
      finishBrowserCheck(ok: stock == 0 && hiddenPopupSafe(), values: ["action_listed": true, "loaded": loaded,
        "hidden_closed": true, "window_close": true, "api_callback": true,
        "anchor": true, "storage": true, "stock_browsers": stock])
    }
  }

  func extensionPopupWindowCheckTick(_ host: any ARWindowHostAPI) {
    if browserCheckPhase == 0, let row = sliceRows.first, let url = row.url {
      browserCheckSeedID = row.id
      browserCheckPhase = 1
      adapter?.select(id: row.id, url: url)
      return
    }
    guard let tab = (host.tabs() as? [any ARTabAPI])?.first, !tab.isLoading,
          tab.navigationCount > 0 else { return }
    if browserCheckPhase == 1, tab.title.data(using: .utf8).flatMap({ try? JSONSerialization.jsonObject(with: $0) }) != nil {
      browserCheckBefore = snapshot
      browserCheckPhase = 2
      tab.checkExtensionPopupWindow(false)
    } else if browserCheckPhase == 2, popups.count == 1,
              let popup = popups.first?.host, popup.checkIsExtensionAppPopup(),
              let data = tab.title.data(using: .utf8),
              let report = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let result = report["popupResult"] as? [String: Any], result["type"] as? String == "popup" {
      browserCheckPhase = 3
      tab.checkExtensionPopupWindow(true)
    } else if browserCheckPhase == 3, popups.isEmpty,
              let data = tab.title.data(using: .utf8),
              let report = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let result = report["popupResult"] as? [String: Any], result["removed"] as? Bool == true {
      let before = browserCheckBefore?.spaces.flatMap { $0.today + $0.pinned + $0.favorites }.map(\.id)
      let after = snapshot.spaces.flatMap { $0.today + $0.pinned + $0.favorites }.map(\.id)
      let stock = host.checkStockBrowsers()
      let unchanged = before == after
      finishBrowserCheck(ok: unchanged && stock == 0 && hiddenPopupSafe(),
        values: ["app_popup": true, "windows_type": "popup", "popup_removed": true,
                 "rows_unchanged": unchanged, "stock_browsers": stock])
    }
  }

  func hiddenPopupSafe() -> Bool {
    let front = commandOutput("/usr/bin/lsappinfo", ["front"])
    return popupWindowsHidden && !NSApp.windows.contains { $0.isVisible || $0.isKeyWindow } &&
      !(popupFrontBefore ?? "").isEmpty && front == popupFrontBefore && popupFrontChange == nil
  }

  func finishBrowserCheck(ok: Bool, values: [String: Any]) {

    if promptScreenSeeded, let tab = (host?.tabs() as? [any ARTabAPI])?.first {
      _ = tab.checkScreenAddress(false)
      promptScreenSeeded = false
    }
    if let protocolLaunchObserver { NSWorkspace.shared.notificationCenter.removeObserver(protocolLaunchObserver) }
    protocolLaunchObserver = nil
    promptFixture?.stop()
    promptFixture = nil
    browserCheckTimer?.invalidate()
    browserCheckTimer = nil
    if let linkMenuObserver { NotificationCenter.default.removeObserver(linkMenuObserver) }
    linkMenuObserver = nil
    Launcher.startupWatchdog?.cancel()
    Launcher.browserCheckFinished = true
    var result = values
    if ["ext-popup", "ext-windows-popup"].contains(browserCheckMode ?? "") {
      result["windows_hidden"] = popupWindowsHidden && !NSApp.windows.contains { $0.isVisible || $0.isKeyWindow }
      result["front_before"] = popupFrontBefore ?? ""
      result["front_after"] = commandOutput("/usr/bin/lsappinfo", ["front"]) ?? ""
      result["front_unchanged"] = !(popupFrontBefore ?? "").isEmpty && result["front_after"] as? String == popupFrontBefore && popupFrontChange == nil
      result["front_change"] = popupFrontChange ?? [:]
    }
    result["check"] = browserCheckMode == "screen-links" ? "links" : (browserCheckMode == "screen-profiles" ? "profiles" : (browserCheckMode == "screen-prompts" ? "prompts" : (browserCheckMode == "screen-devtools" ? "devtools" : (browserCheckMode ?? "unknown"))))
    if browserCheckMode == "screen-links" { result["screen"] = "links" }
    if browserCheckMode == "screen-profiles" { result["screen"] = "profiles" }
    if browserCheckMode == "screen-prompts" { result["screen"] = "prompts" }
    if browserCheckMode == "screen-devtools" { result["screen"] = "devtools" }
    if browserCheckMode == "screen-extensions" { result["check"] = "extensions"; result["screen"] = "extensions" }
    result["ok"] = ok
    result["exit"] = ok ? 0 : 1
    if result["stock_browsers"] == nil { result["stock_browsers"] = host?.checkStockBrowsers() ?? browserCheckStock }
    result["phase"] = browserCheckPhase
    result["attempts"] = browserCheckAttempts
    result["style_mask"] = host?.window().styleMask.rawValue ?? browserCheckStyleMask
    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
       let line = String(data: data, encoding: .utf8) { print(line); fflush(stdout) }
    if let symbol = dlsym(Launcher.handle, "AraratFinishSliceCheck") {
      unsafeBitCast(symbol, to: (@convention(c) (Bool) -> Void).self)(ok)
    }
  }

  func clickScreenDialog(stay: Bool) -> Bool {
    func buttons(_ view: NSView) -> [NSButton] {
      (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
    }
    for window in NSApp.windows where window.isVisible && window !== host?.window() {
      guard let content = window.contentView else { continue }
      let candidates = buttons(content)
      let button = candidates.first { stay ? $0.keyEquivalent == "\u{1b}" : $0.keyEquivalent == "\r" }
      if let button { button.performClick(nil); screenDialogs += 1; return true }
    }
    return false
  }

  func quitTick() {
    guard let mode = quitMode else { return }
    quitAttempts += 1
    if quitAttempts > 300 {
      quitTimedOut = true
      finishQuitCheck(exitCode: 1)
      exit(1)
    }
    let host = self.host
    if mode == "quit-cancel", let host {
      if quitPhase == 0, let row = snapshot.spaces.first(where: { $0.id == "default" })?.today.first,
         let url = row.url {
        quitPhase = 10
        adapter?.select(id: row.id, url: url)
        return
      }
      if quitPhase == 10, let row = snapshot.spaces.first(where: { $0.id == "default" })?.today.first,
         (host.tabs() as? [any ARTabAPI])?.contains(where: { $0.itemId == row.id && !$0.isLoading }) == true,
         let named = snapshot.spaces.first(where: { $0.id == "named" })?.today.first, let url = named.url {
        adapter?.windowHost(host, showProfile: "Profile 1")
        adapter?.select(id: named.id, url: url)
        quitPhase = 11
        return
      }
      if quitPhase == 11, let row = snapshot.spaces.first(where: { $0.id == "named" })?.today.first,
         let tab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == row.id }),
         !tab.isLoading {
        tab.prepareCheckBeforeUnload()
        quitPhase = 12
        return
      }
      if quitPhase == 12, let row = snapshot.spaces.first(where: { $0.id == "named" })?.today.first,
         (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == row.id })?.checkHasBeforeUnload() == true {
        adapter?.windowHost(host, showProfile: "Default")
        quitBefore = nil
        quitPhase = 13
        return
      }
      if quitPhase == 13, host.profileDirectory() == "Default",
         let row = snapshot.spaces.first(where: { $0.id == "default" })?.today.first,
         snapshot.selectedId == row.id, let rows = captureCheckRows() {
        guard quitBefore == rows else { quitBefore = rows; return }
        quitOriginal = rows
        quitStyleMask = host.window().styleMask.rawValue
        quitPhase = 3
        NSApp.terminate(nil)
        return
      }
    }
    if quitPhase == 0, host != nil, !sliceRows.isEmpty {
      quitPhase = 1
      let row = sliceRows[0]
      if let url = row.url { adapter?.select(id: row.id, url: url) }
      return
    }
    if quitPhase == 1, let host, sliceActive == sliceRows.first?.id,
       let tab = (host.tabs() as? [any ARTabAPI])?.first, !tab.isLoading, tab.navigationCount > 0 {
      if mode == "quit" {
        guard sliceRows.count == 3, let url = sliceRows[1].url else { return }
        quitPhase = 2
        adapter?.select(id: sliceRows[1].id, url: url)
      } else {
        tab.prepareCheckBeforeUnload()
        quitPhase = 2
      }
      return
    }
    if quitPhase == 2, let host {
      let tabs = (host.tabs() as? [any ARTabAPI]) ?? []
      if mode == "quit" {
        guard tabs.count == 2, sliceRows.count == 3, sliceActive == sliceRows[1].id,
              tabs.allSatisfy({ !$0.isLoading && $0.navigationCount > 0 }) else { return }
      } else {
        guard tabs.first?.checkHasBeforeUnload() == true else { return }
      }
      guard let rows = captureCheckRows() else { return }
      quitBefore = rows
      quitStyleMask = host.window().styleMask.rawValue
      screenSidebarLights = container?.hasSidebarLights == true
      screenAppKitLightsHidden = container?.appKitLightsHidden == true
      if mode == "screen-quit" {
        quitPhase = 7
        container?.sidebarCloseButton?.performClick(nil)
        return
      }
      quitPhase = 3
      if mode == "close" { container?.sidebarCloseButton?.performClick(nil) }
      else if mode == "screen-quit" { sendQuitKey(host) }
      else { NSApp.terminate(nil) }
      return
    }
    if quitPhase == 7, let host, mode == "screen-quit" {
      if screenDialogs == 0 { _ = clickScreenDialog(stay: true); return }
      guard !host.checkTryingToQuit(), host.tabs().count == 1,
            (host.tabs() as? [any ARTabAPI])?.first?.checkHasBeforeUnload() == true else { return }
      screenClosingOffset = host.checkClosingEvents().count
      screenDialogs = 0
      quitPhase = 3
      sendQuitKey(host)
      return
    }
    if quitPhase == 3, let host, mode != "quit" {
      if mode == "screen-quit", screenDialogs == 0 { _ = clickScreenDialog(stay: true); return }
      let seen = mode == "screen-quit" ? screenDialogs : Int(host.checkDialogCount())
      let expectedBrowsers = mode == "quit-cancel" ? 2 : 1
      guard seen >= 1, !host.checkTryingToQuit(), host.tabs().count == expectedBrowsers,
            let symbol = dlsym(Launcher.handle, "AraratBrowserCount") else { return }
      let closing = host.checkClosingEvents().map(\.boolValue)
      guard closing.last == false else { return }
      let browsers = unsafeBitCast(symbol, to: (@convention(c) () -> UInt).self)()
      guard browsers == UInt(expectedBrowsers) else { return }
      guard let rows = captureCheckRows() else { return }
      let activeItem = host.activeItemId()
      let selectedMatches = activeItem != nil && snapshot.selectedId == activeItem &&
        checkWindowSelection(rows, windowID: windowID) == activeItem
      if mode == "quit-cancel" {
        guard selectedMatches else { quitCancelPrevious = nil; return }
        guard quitCancelPrevious == rows else { quitCancelPrevious = rows; return }
      }
      let cancelDiff = checkRecordDiff(quitBefore, rows)
      let duringDiff = checkRecordDiff(quitBefore, quitDuringProfileSwitch)
      let outgoingItem = checkWindowSelection(quitBefore, windowID: windowID)
      let allowedWindowFields: Set<String> = ["shown_space", "space_history", "changed_at", "selected", "history"]
      let allowedSelections = Set([outgoingItem, activeItem].compactMap { $0 })
      let windowRecordsChanged = cancelDiff.filter { $0["kind"] as? String == "window" }.count
      let onlyWindowSpaceChanged = outgoingItem != nil && activeItem != nil && windowRecordsChanged == 1 &&
        cancelDiff.contains { ($0["fields"] as? [String] ?? []).contains("shown_space") } && cancelDiff.allSatisfy { entry in
        if entry["kind"] as? String == "window" && entry["id"] as? String == windowID {
          return Set(entry["fields"] as? [String] ?? []).isSubset(of: allowedWindowFields)
        }
        guard entry["kind"] as? String == "last_selected", let id = entry["id"] as? String,
              allowedSelections.contains(id) else { return false }
        return rows.contains { $0.count == 3 && $0[0] == "last_selected" && $0[1] == id }
      }
      quitFirst = ["trying_to_quit": host.checkTryingToQuit(), "browsers": browsers,
                   "host_alive": true, "tabs": host.tabs().count,
                   "rows_unchanged": mode == "quit-cancel" ? onlyWindowSpaceChanged && selectedMatches : rows == quitBefore,
                   "hidden_profile_shown": mode == "quit-cancel" && host.profileDirectory() == "Profile 1",
                   "rows_unchanged_during_switch": mode == "quit-cancel" && quitDuringProfileSwitch != nil && duringDiff.isEmpty,
                   "window_written_after_cancel": mode == "quit-cancel" && onlyWindowSpaceChanged,
                   "outgoing_item": outgoingItem ?? "", "active_item": activeItem ?? "",
                   "window_records_changed": windowRecordsChanged, "selected_matches_active": selectedMatches,
                   "during_diff": duringDiff, "cancel_diff": cancelDiff]
      if mode == "quit-cancel" { quitBefore = rows }
      quitEvents = host.checkClosingEvents()
      quitPhase = 4
      if mode == "close" { container?.sidebarCloseButton?.performClick(nil) }
      else if mode == "screen-quit" { sendQuitKey(host) }
      else { NSApp.terminate(nil) }
      return
    }
    if quitPhase == 4 && mode == "screen-quit" && screenDialogs == 1 {
      _ = clickScreenDialog(stay: false)
      return
    }
    if quitPhase == 4 && mode == "close" && host == nil,
       let symbol = dlsym(Launcher.handle, "AraratBrowserCount"),
       unsafeBitCast(symbol, to: (@convention(c) () -> UInt).self)() == 0 {
      quitClosedRows = captureCheckRows()
      let menu = NSApp.delegate?.applicationDockMenu?(NSApp)
      quitDockEmpty = menu?.items.isEmpty ?? true
      FileHandle.standardError.write(Data("ararat-trace: dock-menu items=\(menu?.items.count ?? 0)\n".utf8))
      quitPhase = 5
      _ = NSApp.delegate?.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false)
      FileHandle.standardError.write(Data("ararat-trace: reopen-return host=\(self.host != nil)\n".utf8))
      return
    }
    if quitPhase == 5, let host, mode == "close",
       let symbol = dlsym(Launcher.handle, "AraratBrowserCount"),
       unsafeBitCast(symbol, to: (@convention(c) () -> UInt).self)() == 1 {
      quitReopened = true
      quitDialogCount = host.checkDialogCount()
      quitPhase = 6
      NSApp.terminate(nil)
    }
  }

  @discardableResult func finishQuitCheck(exitCode: Int32) -> Bool {
    guard let mode = quitMode else { return true }
    Launcher.startupWatchdog?.cancel()
    Launcher.startupWatchdog = nil
    let after = quitPath.flatMap(checkRecords)
    func workspaceRows(_ rows: [[String]]?) -> [[String]]? { rows?.filter { $0.first != "window" } }
    let unchanged = quitBefore != nil && after != nil && (mode == "close" ? workspaceRows(quitBefore) == workspaceRows(after) : quitBefore == after)
    let closedRowsUnchanged = quitBefore != nil && quitClosedRows != nil && workspaceRows(quitBefore) == workspaceRows(quitClosedRows)
    let windowRemoved = quitBefore?.contains(where: { $0.first == "window" }) == true && quitClosedRows?.contains(where: { $0.first == "window" }) == false
    let dialogSeen = mode == "screen-quit" ? screenDialogs : Int(quitDialogCount)
    let firstPassed = (quitFirst["rows_unchanged"] as? Bool) == true &&
      (quitFirst["trying_to_quit"] as? Bool) == false && (quitFirst["browsers"] as? UInt) == (mode == "quit-cancel" ? 2 : 1)
    let events = quitEvents.map(\.boolValue)
    let modePassed: Bool
    switch mode {
    case "quit": modePassed = unchanged && events == [true]
    case "devtools":
      let front = commandOutput("/usr/bin/lsappinfo", ["front"])
      let frontUnchanged = devtoolsFrontBefore != nil && front != nil && front == devtoolsFrontBefore
      devtoolsResults["front_unchanged"] = frontUnchanged
      devtoolsResults["hidden"] = true
      modePassed = unchanged && events == [true] && frontUnchanged &&
        ["initial_docked", "background_hidden", "tab_restored", "undocked_host", "redocked", "closed_full_page", "inspected_tab_closed", "inspect_docked", "open_at_quit"].allSatisfy { devtoolsResults[$0] as? Bool == true }
    case "quit-cancel": modePassed = unchanged && firstPassed && dialogSeen == 2 && events == [true, false, true] &&
      quitFirst["hidden_profile_shown"] as? Bool == true && quitFirst["rows_unchanged_during_switch"] as? Bool == true &&
      quitFirst["window_written_after_cancel"] as? Bool == true
    case "close": modePassed = firstPassed && closedRowsUnchanged && windowRemoved && quitReopened && quitDockEmpty && dialogSeen == 2
    case "screen-quit": modePassed = unchanged && firstPassed && dialogSeen == 2 && Array(events.dropFirst(screenClosingOffset)) == [true, false, true] && screenSidebarLights && screenAppKitLightsHidden
    default: modePassed = false
    }
    let ok = exitCode == 0 && !quitTimedOut && quitWillShutDown && quitStock == 0 && modePassed
    var result: [String: Any] = ["check": mode == "screen-quit" ? "quit" : mode,
      "closing": quitEvents, "will_shut_down": quitWillShutDown,
      "stock_browsers": quitStock, "rows_before": quitBefore ?? [], "rows_after": after ?? [],
      "rows_unchanged": unchanged, "dialog_seen": dialogSeen, "exit": ok ? 0 : 1, "ok": ok,
      "timeout": quitTimedOut, "phase": quitPhase, "attempts": quitAttempts, "style_mask": quitStyleMask]
    if mode == "devtools" {
      result.merge(devtoolsResults) { _, new in new }
      result["phase"] = browserCheckPhase
      result["attempts"] = browserCheckAttempts
      result["engine_exit_code"] = exitCode
      result["mode_passed"] = modePassed
    }
    if mode == "screen-quit" {
      result["screen"] = "quit"
      result["sidebar_lights"] = screenSidebarLights
      result["appkit_lights_hidden"] = screenAppKitLightsHidden
    }
    if mode == "quit-cancel" || mode == "close" || mode == "screen-quit" { result["after_stay"] = quitFirst }
    if mode == "quit-cancel" { result["rows_before_first_quit"] = quitOriginal ?? [] }
    if mode == "close" {
      result["rows_after_close"] = quitClosedRows ?? []
      result["rows_unchanged_after_close"] = closedRowsUnchanged
      result["window_removed_after_close"] = windowRemoved
      result["reopened"] = quitReopened
      result["dock_empty"] = quitDockEmpty
    }
    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
       let line = String(data: data, encoding: .utf8) { print(line); fflush(stdout) }
    return ok
  }

  func report(_ error: Error) {
    FileHandle.standardError.write(Data("workspace: \(error)\n".utf8))
  }

  func sliceTick(card: NSView) {
    sliceAttempts += 1
    guard sliceAttempts < 300 else { finishSlice(ok: false); return }
    if slicePhase == 4 {
      if let symbol = dlsym(Launcher.handle, "AraratBrowserCount") {
        let count = unsafeBitCast(symbol, to: (@convention(c) () -> UInt).self)()
        sliceBrowsers = count
        if count == 0 { finishSlice(ok: sliceResult) }
      }
      return
    }
    guard let host else { return }
    sliceStyleMask = host.window().styleMask.rawValue
    let tabs = (host.tabs() as? [any ARTabAPI]) ?? []
    func select(_ index: Int) {
      let row = sliceRows[index]
      sidebar?.onSelect?(row)
    }
    if slicePhase == 0 && sliceRows.count == 3 {
      slicePhase = 1
      select(1)
    } else if slicePhase == 1 && sliceActive == sliceRows[1].id,
              let tab = tabs.first(where: { $0.title == "Ararat Two" && $0.view != nil }), !tab.isLoading {
      sliceLive = tab.liveId
      sliceNavigationCount = tab.navigationCount
      if let view = tab.view, let window = view.window {
        let center = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        let point = view.convert(center, to: nil)
        if let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
          sliceMouseSent = tab.sendCheckMouseMoved(event)
        }
      }
      slicePhase = 2
      select(0)
    } else if slicePhase == 2 && sliceActive == sliceRows[0].id {
      slicePhase = 3
      select(1)
    } else if slicePhase == 3 && sliceActive == sliceRows[1].id,
              let tab = tabs.first(where: { $0.liveId == sliceLive && $0.view != nil }) {
      let titleMatches = tab.title == "Ararat Two"
      let noReload = tab.navigationCount == sliceNavigationCount
      let activeInCard = tab.view?.superview === card
      sliceTitleMatches = titleMatches
      sliceNoReload = noReload
      sliceInCard = activeInCard
      sliceTabCount = tabs.count
      if let symbol = dlsym(Launcher.handle, "AraratExclusiveInputCount") {
        sliceExclusiveInputSeen = unsafeBitCast(symbol, to: (@convention(c) () -> UInt).self)() > 0
      }
      sliceResult = titleMatches && noReload && activeInCard && sliceMouseSent && sliceExclusiveInputSeen && tabs.count == 2
      slicePhase = 4
      host.close()
    }
  }

  func finishSlice(ok: Bool) {
    sliceTimer?.invalidate()
    sliceTimer = nil
    print("{\"check\":\"slice\",\"ok\":\(ok),\"phase\":\(slicePhase),\"attempts\":\(sliceAttempts),\"style_mask\":\(sliceStyleMask),\"title_matches\":\(sliceTitleMatches),\"reselect_no_reload\":\(sliceNoReload),\"tabs\":\(sliceTabCount),\"active_in_card\":\(sliceInCard),\"mouse_sent\":\(sliceMouseSent),\"exclusive_input_seen\":\(sliceExclusiveInputSeen),\"transactions\":{\"count\":\(sliceTransactions),\"last_rev\":\(sliceLastRev)},\"browsers\":\(sliceBrowsers)}")
    fflush(stdout)
    guard let symbol = dlsym(Launcher.handle, "AraratFinishSliceCheck") else { return }
    unsafeBitCast(symbol, to: (@convention(c) (Bool) -> Void).self)(ok)
  }

  func shutdown() {
    if promptScreenSeeded, let tab = (host?.tabs() as? [any ARTabAPI])?.first {
      _ = tab.checkScreenAddress(false)
      promptScreenSeeded = false
    }
    if let protocolLaunchObserver { NSWorkspace.shared.notificationCenter.removeObserver(protocolLaunchObserver) }
    protocolLaunchObserver = nil
    promptFixture?.stop()
    promptFixture = nil
    browserCheckTimer?.invalidate()
    children.forEach { $0.shutdown() }
    children.removeAll()
    popups.removeAll()
    sliceTimer?.invalidate()
    quitTimer?.invalidate()
    if quitMode != nil {
      quitWillShutDown = true
      if let host { captureCheckState(host) }
    }
    if let windowCloseObserver { NotificationCenter.default.removeObserver(windowCloseObserver) }
    adapter?.shutdown()
    host?.close()
    host = nil
    adapter = nil
    workspace = nil
    keyBindings = nil
    sidebar = nil
    container = nil
  }
}

var callbacks = AraratCallbacks(
  started: { _ in
    MainActor.assumeIsolated {
      let value = Runtime()
      do {
        try value.start()
        Launcher.runtime = value
        value.openURLs(Launcher.pendingURLs)
        Launcher.pendingURLs.removeAll()
        if value.quitMode == nil && value.browserCheckMode == nil {
          Launcher.startupWatchdog?.cancel()
          Launcher.startupWatchdog = nil
        }
      } catch {
        Launcher.startupWatchdog?.cancel()
        Launcher.startupWatchdog = nil
        FileHandle.standardError.write(Data("engine: startup failed: \(error)\n".utf8))
        if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--ararat-measure=") }) {
          let scenario = String(argument.dropFirst(17))
          let compositor = CommandLine.arguments.contains("--ararat-compositor=c2") ? "c2" : "c1"
          for run in 1...10 {
            let result: [String: Any] = ["measure": scenario, "compositor": compositor, "run": run, "timeout": "startup"]
            if let data = try? JSONSerialization.data(withJSONObject: result), let line = String(data: data, encoding: .utf8) {
              print(line)
              fflush(stdout)
            }
          }
          if let symbol = dlsym(Launcher.handle, "AraratQuit") {
            unsafeBitCast(symbol, to: (@convention(c) () -> Void).self)()
          }
        } else if value.quitMode != nil {
          value.quitTimedOut = true
          value.finishQuitCheck(exitCode: 1)
          exit(1)
        } else if value.browserCheckMode != nil {
          value.finishBrowserCheck(ok: false, values: ["error": "startup"])
        } else if CommandLine.arguments.contains("--ararat-check=slice") {
          value.finishSlice(ok: false)
        } else if let symbol = dlsym(Launcher.handle, "AraratQuit") {
          unsafeBitCast(symbol, to: (@convention(c) () -> Void).self)()
        }
      }
    }
  },
  will_shut_down: { _ in
    MainActor.assumeIsolated {
      Launcher.runtime?.shutdown()
      if Launcher.runtime?.quitMode == nil { Launcher.runtime = nil }
    }
  },
  reopen: { _, _ in
    MainActor.assumeIsolated { Launcher.runtime?.reopen() ?? false }
  },
  create_host: { _, popup, profile, x, y, width, height in
    guard let profile else { return nil }
    let profileName = String(cString: profile)
    let address = MainActor.assumeIsolated {
      if Launcher.runtime == nil && CommandLine.arguments.contains(where: { $0.hasPrefix("--ararat-check=") || $0 == "--ararat-screen=links" }) {
        FileHandle.standardError.write(Data("ararat-trace: browser-factory fallback=no-runtime\n".utf8))
      }
      return Launcher.runtime?.createHost(popup: popup, profile: profileName, bounds: NSRect(x: Int(x), y: Int(y), width: Int(width), height: Int(height))).map { UInt(bitPattern: $0) } ?? 0
    }
    return UnsafeMutableRawPointer(bitPattern: address)
  },
  open_urls: { _, pointer in
    guard let pointer else { return }
    let urls: [(url: String, untrusted: Bool)] = Unmanaged<NSArray>.fromOpaque(pointer).takeUnretainedValue()
      .compactMap { value in
        guard let entry = value as? [String: Any], let url = entry["url"] as? URL,
              let untrusted = entry["untrusted"] as? Bool else { return nil }
        return (url.absoluteString, untrusted)
      }
    MainActor.assumeIsolated {
      if let runtime = Launcher.runtime { runtime.openURLs(urls) }
      else { Launcher.pendingURLs.append(contentsOf: urls) }
    }
  },
  ctx: nil
)
typealias AraratMain = @convention(c) (
  Int32,
  UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
  UnsafeRawPointer?
) -> Int32
let araratMain = unsafeBitCast(symbol, to: AraratMain.self)
if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--ararat-check=") || $0.hasPrefix("--ararat-screen=") }) {
  let screen = argument.hasPrefix("--ararat-screen=")
  let name = String(argument.dropFirst(screen ? 16 : 15))
  let timer = DispatchSource.makeTimerSource(queue: .global())
  timer.schedule(deadline: .now() + 60)
  timer.setEventHandler {
    var result: [String: Any] = ["check": name, "ok": false, "timeout": "watchdog", "exit": 1, "phase": -1, "attempts": 0, "style_mask": 0]
    if screen { result["screen"] = name }
    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
      FileHandle.standardOutput.write(data)
      FileHandle.standardOutput.write(Data([0x0a]))
    }
    exit(1)
  }
  Launcher.startupWatchdog = timer
  timer.resume()
}
let result = withUnsafePointer(to: &callbacks) {
  araratMain(CommandLine.argc, CommandLine.unsafeArgv, UnsafeRawPointer($0))
}
let checksPassed = MainActor.assumeIsolated {
  if Launcher.browserCheckFinished { return true }
  if let runtime = Launcher.runtime {
    if runtime.browserCheckMode == "devtools" && runtime.quitMode == nil {
      let failure: [String: Any] = ["check": "devtools", "ok": false, "error": "engine exited before quit", "exit": 1, "phase": runtime.browserCheckPhase]
      if let data = try? JSONSerialization.data(withJSONObject: failure), let line = String(data: data, encoding: .utf8) { print(line); fflush(stdout) }
      return false
    }
    return runtime.finishQuitCheck(exitCode: result)
  }
  if let argument = CommandLine.arguments.first(where: {
    ["--ararat-check=quit", "--ararat-check=quit-cancel", "--ararat-check=close", "--ararat-check=newtab", "--ararat-check=popup", "--ararat-check=menu", "--ararat-check=empty", "--ararat-check=deferred", "--ararat-check=profiles", "--ararat-check=ext-windows", "--ararat-check=ext-popup", "--ararat-check=ext-windows-popup", "--ararat-check=incognito", "--ararat-check=permissions", "--ararat-check=dialogs", "--ararat-check=protocol", "--ararat-check=autofill", "--ararat-check=devtools", "--ararat-screen=quit", "--ararat-screen=links", "--ararat-screen=profiles", "--ararat-screen=prompts", "--ararat-screen=devtools", "--ararat-screen=extensions"].contains($0)
  }) {
    Launcher.startupWatchdog?.cancel()
    let screen = argument.hasPrefix("--ararat-screen=")
    let name = String(argument.dropFirst(screen ? 16 : 15))
    var failure: [String: Any] = ["check": name, "ok": false, "error": "startup", "exit": 1]
    if screen { failure["screen"] = name }
    if let data = try? JSONSerialization.data(withJSONObject: failure), let line = String(data: data, encoding: .utf8) {
      print(line)
      fflush(stdout)
    }
    return false
  }
  return true
}
exit(result == 0 && !checksPassed ? 1 : result)
