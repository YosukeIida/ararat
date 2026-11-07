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
  var emptyProbe: [String: Any] = [:]
  var emptyMenuCount: UInt = 0
  var emptyMenuEnabled: [NSNumber] = []
  var emptyRestore: [String: Any] = [:]
  var emptyRestorePassed = false
  var emptyRowsBefore: Set<String> = []
  var linkMenuObserver: NSObjectProtocol?
  var linkMenuChosen = false

  func start(session: WorkspaceSession? = nil, shownSpace: String? = nil, reopening: Bool = false) throws {
    let arguments = CommandLine.arguments
    let checkName = arguments.first(where: { $0.hasPrefix("--ararat-check=") }).map { String($0.dropFirst(15)) }
    let screenName = arguments.first(where: { $0.hasPrefix("--ararat-screen=") }).map { String($0.dropFirst(16)) }
    if session == nil, let checkName, !["slice", "quit", "quit-cancel", "close", "newtab", "popup", "menu", "empty", "deferred", "profiles", "ext-windows", "incognito"].contains(checkName) { return }
    if session == nil {
      quitMode = screenName == "quit" ? "screen-quit" : (["quit", "quit-cancel", "close"].contains(checkName ?? "") ? checkName : nil)
      if ["newtab", "popup", "menu", "empty", "deferred", "profiles", "ext-windows", "incognito"].contains(checkName ?? "") { browserCheckMode = checkName }
      if screenName == "links" { browserCheckMode = "screen-links" }
      if screenName == "profiles" { browserCheckMode = "screen-profiles" }
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
    let check = session == nil && (arguments.contains("--ararat-check=slice") || quitMode != nil || browserCheckMode != nil)
    let profileCheck = ["profiles", "ext-windows", "incognito", "screen-profiles"].contains(browserCheckMode ?? "") || quitMode == "quit-cancel"
    let singleCheck = (browserCheckMode != nil && !profileCheck) || (quitMode != nil && quitMode != "quit")
    let linkCheck = browserCheckMode == "screen-links"
    let profileURL = ["ext-windows", "screen-profiles"].contains(browserCheckMode ?? "")
      ? "chrome-extension://kmgaadhbnkendcanjninlfmfgehagggl/probe.html" : "about:blank"
    let adapter = try EngineAdapter(path: path, windowID: windowID, card: card, seedCheck: check && !singleCheck && !profileCheck, seedSingleCheck: check && singleCheck && !linkCheck, seedLinkCheck: check && linkCheck, seedProfiles: check && profileCheck, profileCheckURL: profileURL, session: running)
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
      if browserCheckMode == "screen-links" || browserCheckMode == "screen-profiles" {
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
    guard let view = tab.view, let window = view.window else { return }
    let local = NSPoint(x: 70, y: view.isFlipped ? 70 : view.bounds.height - 70)
    let location = view.convert(local, to: nil)
    let flags: NSEvent.ModifierFlags = command ? .command : []
    for type in right ? [NSEvent.EventType.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp] {
      if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: flags,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { NSApp.sendEvent(event) }
    }
  }

  func watchLinkMenu() {
    guard let title = host?.checkOpenLinkNewWindowTitle(), !title.isEmpty else { return }
    linkMenuObserver = NotificationCenter.default.addObserver(
      forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
    ) { [weak self] notification in
      guard let menu = notification.object as? NSMenu,
            let target = menu.items.firstIndex(where: { $0.title == title }) else { return }
      let count = menu.items[...target].filter { !$0.isHidden && $0.isEnabled && !$0.isSeparatorItem }.count
      MainActor.assumeIsolated { self?.linkMenuChosen = true }
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
    if mode == "popup" {
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
                           "browser_count": count as Any? ?? NSNull()]) { _, new in new }
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
      finishBrowserCheck(ok: profileCheckPassed && closed && unchanged && removed && browserCheckStock == 1,
                         values: profileCheckResult)
      return
    }
    guard let host else { return }
    if mode == "empty" { emptyCheckTick(host); return }
    if mode == "profiles" { profileCheckTick(host); return }
    if mode == "incognito" { incognitoCheckTick(host); return }
    if mode == "ext-windows" || mode == "screen-profiles" { extensionCheckTick(host, screen: mode == "screen-profiles"); return }
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
    } else if mode == "deferred", browserCheckPhase == 2, host.checkStockBrowsers() >= 2 {
      let stock = host.checkStockBrowsers()
      finishBrowserCheck(ok: stock == 2 && children.isEmpty && popups.isEmpty,
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
      finishBrowserCheck(ok: rowsUnchanged && sizeOK && stock == 0,
        values: ["opener_alive": true, "popup_closed": true, "rows_unchanged": rowsUnchanged,
                 "width": browserCheckPopupSize.width, "height": browserCheckPopupSize.height, "stock_browsers": stock])
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
        (cookies["set"] as? Bool) == true && (cookies["isolated"] as? Bool) == true && switchesOK && stock == 1 &&
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

  func finishBrowserCheck(ok: Bool, values: [String: Any]) {
    browserCheckTimer?.invalidate()
    browserCheckTimer = nil
    if let linkMenuObserver { NotificationCenter.default.removeObserver(linkMenuObserver) }
    linkMenuObserver = nil
    Launcher.startupWatchdog?.cancel()
    Launcher.browserCheckFinished = true
    var result = values
    result["check"] = browserCheckMode == "screen-links" ? "links" : (browserCheckMode == "screen-profiles" ? "profiles" : (browserCheckMode ?? "unknown"))
    if browserCheckMode == "screen-links" { result["screen"] = "links" }
    if browserCheckMode == "screen-profiles" { result["screen"] = "profiles" }
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
  if let runtime = Launcher.runtime { return runtime.finishQuitCheck(exitCode: result) }
  if let argument = CommandLine.arguments.first(where: {
    ["--ararat-check=quit", "--ararat-check=quit-cancel", "--ararat-check=close", "--ararat-check=newtab", "--ararat-check=popup", "--ararat-check=menu", "--ararat-check=empty", "--ararat-check=deferred", "--ararat-check=profiles", "--ararat-check=ext-windows", "--ararat-check=incognito", "--ararat-screen=quit", "--ararat-screen=links", "--ararat-screen=profiles"].contains($0)
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
