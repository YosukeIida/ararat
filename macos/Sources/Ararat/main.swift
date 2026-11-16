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

if CommandLine.arguments.contains(where: { ["--ararat-check=organize", "--ararat-screen=organize", "--ararat-check=look", "--ararat-screen=look", "--ararat-check=dock", "--ararat-screen=dock", "--ararat-check=downloads", "--ararat-screen=downloads", "--ararat-check=toasts", "--ararat-screen=toasts", "--ararat-check=split-focus", "--ararat-screen=split-focus", "--ararat-check=split-commands", "--ararat-screen=split-commands", "--ararat-check=header", "--ararat-screen=header", "--ararat-check=urlfield", "--ararat-screen=urlfield", "--ararat-check=site-controls", "--ararat-screen=site-controls", "--ararat-check=ext-actions", "--ararat-screen=ext-actions", "--ararat-screen=settings-frame", "--ararat-screen=settings-search", "--ararat-screen=settings-tabs", "--ararat-screen=settings-shortcuts", "--ararat-screen=settings-air-traffic", "--ararat-screen=settings-spaces", "--ararat-screen=settings-appearance", "--ararat-screen=settings-little-window", "--ararat-screen=settings-websites", "--ararat-screen=settings-privacy", "--ararat-screen=settings-extensions", "--ararat-screen=settings-toolbar", "--ararat-screen=onboarding", "--ararat-check=onboarding", "--ararat-check=window-drag", "--ararat-screen=window-drag", "--ararat-check=create-space", "--ararat-screen=create-space", "--ararat-check=folder-upload", "--ararat-screen=folder-upload"].contains($0) }) {
  let args = CommandLine.arguments
  let temporary = [NSTemporaryDirectory(), "/tmp"].map { URL(fileURLWithPath: $0, isDirectory: true).resolvingSymlinksInPath().path + "/" }
  func scratch(_ argument: String) -> Bool {
    guard let value = args.first(where: { $0.hasPrefix(argument) }).map({ String($0.dropFirst(argument.count)) }), !value.isEmpty else { return false }
    let path = URL(fileURLWithPath: value).resolvingSymlinksInPath().path
    return temporary.contains { path.hasPrefix($0) }
  }
  let downloads = args.contains(where: { $0.hasSuffix("=downloads") || $0.hasSuffix("=toasts") })
  // A settings screen check refused here names itself by its argument (`settings-tabs`), which is
  // the mode's raw value, so the refusal's `check` is the same name the run would have reported.
  let settingsScreen = args.first { $0.hasPrefix("--ararat-screen=settings-") }.map { String($0.dropFirst("--ararat-screen=".count)) }
  guard args.contains("--use-mock-keychain"), scratch("--user-data-dir="), scratch("--ararat-db="), !downloads || args.contains("--disable-features=SystemNotifications") else {
    let result: [String: Any] = ["check": settingsScreen ?? (args.contains(where: { $0.hasSuffix("=onboarding") }) ? "onboarding" : args.contains(where: { $0.hasSuffix("=split-commands") }) ? "split-commands" : args.contains(where: { $0.hasSuffix("=split-focus") }) ? "split-focus" : args.contains(where: { $0.hasSuffix("=header") }) ? "header" : args.contains(where: { $0.hasSuffix("=urlfield") }) ? "urlfield" : args.contains(where: { $0.hasSuffix("=toasts") }) ? "toasts" : downloads ? "downloads" : args.contains(where: { $0.hasSuffix("=look") }) ? "look" : args.contains(where: { $0.hasSuffix("=dock") }) ? "dock" : args.contains(where: { $0.hasSuffix("=folder-upload") }) ? "folder-upload" : "organize"), "ok": false, "error": downloads ? "scratch profile, database, mock keychain and notification flag required" : "scratch profile, database and mock keychain required", "conditions": [:], "failed_conditions": ["scratch_guard"]]
    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) { FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10])) }
    exit(1)
  }
}

if let check = CommandLine.arguments.first(where: { $0 == "--ararat-check=relaunch" || $0 == "--ararat-check=crash" || $0 == "--ararat-check=relaunch-pins" || $0 == "--ararat-check=private-durability" }) {
  if check == "--ararat-check=private-durability" { exit(runPrivateDurabilityDriver()) }
  exit(runRelaunchDriver(check == "--ararat-check=relaunch-pins" ? "pins" : String(check.dropFirst(15))))
}

enum Launcher {
  static var handle: UnsafeMutableRawPointer!
  static var startupWatchdog: DispatchSourceTimer?
  static var teardownDeadline: TeardownDeadline?
  static var teardownFailure = false
  @MainActor static var runtime: Runtime?
  @MainActor static var pendingURLs: [(url: String, untrusted: Bool)] = []
  /// U27h: set just before the engine creates a Little Window's popup Browser. The create_host
  /// callback runs on the root Runtime whichever window asked, so the request lives here.
  /// `replacing` is the Little Window a profile switch is replacing: it is closed only after
  /// the new one exists, so a refused open never loses the page.
  @MainActor static var pendingLittleWindow: (origin: Runtime, frame: NSRect, url: String?, profile: String,
                                             replacing: LittleWindowController?)?
  @MainActor static var browserCheckFinished = false
}

/// U27i O3: the app-wide registration of the Little Window's global shortcut. One for the app, so
/// the shortcut works from any window and while Ararat is in the background; the settings pane
/// writes a new key through the same center, which re-registers immediately.
@MainActor
enum LittleWindowGlobalShortcut {
  static var center: LittleWindowHotKeyCenter?

  static func install(_ runtime: Runtime) {
    let center = LittleWindowHotKeyCenter(registrar: CarbonGlobalHotKey())
    center.onTrigger = { [weak runtime] in runtime?.newLittleWindow(nil) }
    self.center = center
    runtime.workspace?.littleWindowDevice { result in
      if case .success(let device) = result { center.apply(device.hotKey) }
    }
  }
}

/// One in-memory workspace per off-the-record `Profile*`, shared by that profile's windows and
/// released when the last of them closes (U26f). The key is the Profile pointer, never the
/// directory name: an OTR profile's name is its parent's, which two OTR profiles share.
@MainActor
enum PrivateWorkspaces {
  struct Entry {
    let session: WorkspaceSession
    var windows = 0
  }
  private static var entries: [UInt: Entry] = [:]

  static func acquire(pointer: UInt, profile: String) -> WorkspaceSession {
    if var entry = entries[pointer] {
      entry.windows += 1
      entries[pointer] = entry
      return entry.session
    }
    let session = WorkspaceSession()
    session.store = WorkspaceStore.openPrivate(profile: profile == "Default" ? .default : .named(profile))
    entries[pointer] = Entry(session: session, windows: 1)
    return session
  }

  static func release(pointer: UInt) {
    guard var entry = entries[pointer] else { return }
    entry.windows -= 1
    if entry.windows <= 0 {
      // The workspace, its command-bar state and its downloads model go together: nothing
      // restores a private window, and a crash keeps nothing.
      entry.session.store = nil
      entries.removeValue(forKey: pointer)
    } else {
      entries[pointer] = entry
    }
  }

  static var liveCount: Int { entries.values.reduce(0) { $0 + $1.windows } }
  static func session(pointer: UInt) -> WorkspaceSession? { entries[pointer]?.session }
}

final class TeardownDeadline {
  private let lock = NSLock()
  private var finished = false
  private var expired = false
  private var timer: DispatchSourceTimer?
  private var deadline: DispatchTime = .distantFuture

  func start(seconds: Int) {
    let timer = DispatchSource.makeTimerSource(queue: .global())
    self.timer = timer
    deadline = .now() + .seconds(seconds)
    timer.schedule(deadline: deadline)
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      self.lock.lock()
      defer { self.lock.unlock() }
      guard !self.finished else { return }
      self.expired = true
      FileHandle.standardError.write(Data("ararat-teardown: deadline expired; process outcome incomplete\n".utf8))
    }
    timer.resume()
  }

  func finish() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    finished = true
    timer?.cancel()
    if !expired && DispatchTime.now().uptimeNanoseconds >= deadline.uptimeNanoseconds {
      expired = true
      FileHandle.standardError.write(Data("ararat-teardown: deadline expired; process outcome incomplete\n".utf8))
    }
    return !expired
  }
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

func checkStoredTabMetadata(_ rows: [[String]], item: String, url: String, title: String) -> Bool {
  guard !title.isEmpty,
        let row = rows.first(where: { $0.count == 3 && $0[0] == "item" && $0[1] == item }),
        let data = row[2].data(using: .utf8),
        let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
        let kind = record["kind"] as? [String: Any], let tab = kind["Tab"] as? [String: Any] else { return false }
  return tab["url"] as? String == url && tab["saved_title"] as? String == title
}

func checkCoverageFlags(_ arguments: [String]) -> [String] {
  let names = ["--ararat-keyboard-main-scope", "--ararat-incognito-window-check", "--ararat-space-matrix-check", "--ararat-page-only-menu-check", "--ararat-quit-suggestion-check",
    "--ararat-multiple-quit-check", "--ararat-multiple-close-check", "--ararat-split-close-check",
    "--ararat-empty-close-check", "--ararat-same-profile-empty-quit-check", "--ararat-selection-race",
    "--ararat-selection-supersede", "--ararat-committed-switch-race", "--ararat-cross-window-selection-check",
    "--ararat-cross-window-reverse-check"]
  return arguments.filter { argument in names.contains { argument == $0 || argument.hasPrefix($0 + "=") } }
}

/// U26f: the commands a private workspace (one space, Today only) can run. One list for the
/// command dispatcher and the menu validation, so the two cannot drift.
let privateWorkspaceCommands: Set<String> = [
  "cycle_tabs_next", "cycle_tabs_previous", "force_reload", "settings", "quit", "new_tab",
  "edit_url", "copy_link", "close_tab", "rename", "toggle_sidebar", "clear_cache_site",
  "clear_cookies_site", "reset_sidebar_width",
]

func incognitoResultIdentity(check: String, arguments: [String]) -> [String: Any] {
  guard check == "incognito" else { return [:] }
  let regular = arguments.contains("--ararat-incognito-window-check")
  return ["case": regular ? "incognito-regular-window" : "incognito-private",
          "check_flags": checkCoverageFlags(arguments),
          "compositor": arguments.contains("--ararat-compositor=c2") ? "c2" : "c1",
          "requested_direction": arguments.contains("--force-ui-direction=rtl") ? "rtl" : "default"]
}

// Why not compare every record: the page-only popup cannot write workspace rows, but the
// regular window's own device-local Window/LastSelected rows commit on their one-second batch,
// so a whole-table compare flakes. Those two kinds are excluded; every workspace kind is not.
// A private run must not touch the regular workspace rows; the regular window's own
// Window/LastSelected rows can commit on their own batch and are not workspace content.
func workspaceRowsMatch(_ before: [[String]]?, _ after: [[String]]?) -> Bool {
  guard let before, let after else { return false }
  func stable(_ rows: [[String]]) -> [[String]] {
    rows.filter { $0.count == 3 && $0[0] != "window" && $0[0] != "last_selected" }
  }
  return stable(before) == stable(after)
}

func pageOnlyRowsUnchanged(_ before: [[String]]?, _ after: [[String]]?) -> Bool {
  guard let before, let after else { return false }
  func stable(_ rows: [[String]]) -> [[String]] {
    rows.filter { $0.count == 3 && $0[0] != "window" && $0[0] != "last_selected" }
  }
  return stable(before) == stable(after)
}

func pageOnlyTraceRows(_ rows: [[String]]?) -> [[String: String]]? {
  rows?.filter { $0.count == 3 && $0[0] != "window" && $0[0] != "last_selected" }.map { row in
    var result = ["kind": row[0], "id": row[1]]
    if row[0] == "space", let data = row[2].data(using: .utf8),
       let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
       let title = body["title"] as? String { result["title"] = title }
    return result
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
  let rootView = NSView()
  let card = NSView()
  private let permissionDim = PermissionDim()
  let findBar = FindBarView()
  var findPageRect = NSRect.zero
  var host: (any ARWindowHostAPI)?
  var createdSize = NSSize.zero
  /// U27h: set for a Little Window; nil for every other page-only popup.
  var littleWindow: LittleWindowController?
  func isLittleWindow(forWindowHost host: any ARWindowHostAPI) -> Bool { littleWindow != nil }
  var closeObserver: NSObjectProtocol?
  private var windowID: String?
  private var failureView: PageFailureView?
  private var failureLiveID: String?
  var checkFailureState: [String: Any] { failureView?.checkState ?? [:] }
  deinit { if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) } }
  func pageCard(forWindowHost host: any ARWindowHostAPI) -> NSView { card }
  func windowHost(_ host: any ARWindowHostAPI, permissionDim identifier: String,
                  container: NSView, frame: NSRect, visible: Bool) {
    permissionDim.update(identifier, container: container, frame: frame, visible: visible)
  }
  func windowHost(_ host: any ARWindowHostAPI, didReceiveTransaction transaction: [String: Any]) {
    littleWindow?.update()
    guard let strips = transaction["strips"] as? [[String: Any]],
          let strip = strips.first(where: { $0["window"] as? String == windowID }) else { return }
    let active = strip["active"] as? String
    guard let live = active,
          let tab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.liveId == live }),
          tab.crashed || tab.networkError != 0 else {
      failureView?.uncover(restoreFocus: active != nil && active == failureLiveID)
      failureView?.removeFromSuperview()
      failureView = nil
      failureLiveID = nil
      return
    }
    let view = failureView ?? PageFailureView(frame: card.bounds)
    view.frame = card.bounds
    view.autoresizingMask = [.width, .height]
    view.update(crashed: tab.crashed, error: Int(tab.networkError), host: URL(string: tab.url)?.host ?? tab.url, archive: false)
    view.onReload = { [weak tab] in tab?.reload() }
    view.onClose = { [weak tab] in tab?.close(withCommandId: UUID().uuidString) }
    if view.superview !== card { card.addSubview(view, positioned: .above, relativeTo: nil) }
    view.cover(tab.view, focus: true) { [weak tab] in tab?.focus() }
    failureView = view
    failureLiveID = live
  }
  func windowHost(_ host: any ARWindowHostAPI, showProfile profile: String) {}
  func siteStateChanged(forWindowHost host: any ARWindowHostAPI) { littleWindow?.update() }
  func extensionActionsChanged(forWindowHost host: any ARWindowHostAPI) { littleWindow?.update() }
  func windowHostClosingAllCancelled(_ host: any ARWindowHostAPI) {}
  func windowHostWillBeginClosing(_ host: any ARWindowHostAPI) {}
  func windowHost(_ host: any ARWindowHostAPI, pageFullscreenChanged fullscreen: Bool) {}
  func windowHost(_ host: any ARWindowHostAPI, windowFullscreenChanged fullscreen: Bool) {}
  func windowHost(_ host: any ARWindowHostAPI, performWorkspaceCommand command: String) {}
  func windowHost(_ host: any ARWindowHostAPI, updateFindBar state: [String: Any]) {
    if CommandLine.arguments.contains("--ararat-compositor=c2"), state["visible"] as? Bool == true,
       let root = host.window().contentView, findBar.superview !== root || root.subviews.last !== findBar {
      root.addSubview(findBar, positioned: .above, relativeTo: nil)
      positionFindBar()
    }
    findBar.update(state: state)
  }
  func findBarHasFocus(forWindowHost host: any ARWindowHostAPI) -> Bool { findBar.hasFocus }
  func windowHost(_ host: any ARWindowHostAPI, findPageRectChanged rect: NSRect) {
    findPageRect = rootView.convert(rect, from: card)
    positionFindBar()
  }
  func positionFindBar() {
    let width = min(380, findPageRect.width)
    let frame = NSRect(x: findPageRect.maxX - width, y: findPageRect.maxY - 36, width: width, height: 36)
    findBar.frame = findBar.superview.map { $0.convert(frame, from: rootView) } ?? frame
  }

  func create(bounds: NSRect) -> Bool {
    rootView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
    rootView.addSubview(card)
    card.frame = rootView.bounds
    card.autoresizingMask = [.width, .height]
    findBar.frame = NSRect(x: max(0, rootView.bounds.width - 380), y: max(0, rootView.bounds.height - 36), width: 380, height: 36)
    findBar.autoresizingMask = [.minXMargin, .minYMargin]
    findBar.isHidden = true
    rootView.addSubview(findBar)
    guard let symbol = dlsym(Launcher.handle, "AraratWindowHostCreate") else { return false }
    typealias Factory = @convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> UnsafeMutableRawPointer?
    let id = UUID().uuidString as NSString
    windowID = id as String
    guard let pointer = unsafeBitCast(symbol, to: Factory.self)(
      Unmanaged.passUnretained(rootView).toOpaque(), Unmanaged.passUnretained(id).toOpaque()),
      let host = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? any ARWindowHostAPI else { return false }
    self.host = host
    findBar.onAction = { [weak host] action, text, selection, live, profile in host?.findAction(action, text: text, selection: selection, liveId: live, profile: profile) }
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
final class Runtime: NSObject, NSMenuItemValidation {
  let clearUndo = ClearUndo()
  var windowID: String
  weak var root: Runtime?
  var children: [Runtime] = []
  /// This window and every window under it, so a settings change reaches a private window opened
  /// from a child window as well as the owner's own children (U27d review 1 M2).
  var windowTree: [Runtime] { [self] + children.flatMap(\.windowTree) }
  var popups: [PopupHost] = []
  /// U27h: the page-only Little Windows opened from this window.
  var littleWindows: [LittleWindowController] = []
  /// The last one opened, kept after it closes so a check can read what it did.
  var lastLittleWindow: LittleWindowController?
  var hostClosing = false
  var selectionGeneration = 0
  var hasUsableHost: Bool { !hostClosing && host.map { !$0.isClosing() && !$0.isClosingAll() } == true }
  init(windowID: String = UUID().uuidString) { self.windowID = windowID; super.init() }
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
  func createHost(popup: Bool, offTheRecord: Bool, profilePointer: UInt?, profile: String, bounds: NSRect) -> UnsafeMutableRawPointer? {
    if ["incognito", "keyboard", "private-window"].contains(browserCheckMode ?? "") {
      FileHandle.standardError.write(Data("ararat-trace: create-host phase=\(browserCheckPhase) popup=\(popup) profile=\(profile)\n".utf8))
    }
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
      if let pending = Launcher.pendingLittleWindow {
        Launcher.pendingLittleWindow = nil
        let controller = LittleWindowController(popup: value, origin: pending.origin, profile: pending.profile,
                                                frame: pending.frame, url: pending.url)
        pending.origin.littleWindows.append(controller)
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--ararat-check=") || $0.hasPrefix("--ararat-screen=") }) {
          pending.origin.lastLittleWindow = controller
        }
        // M1: the window a profile switch replaces closes only now that its replacement exists.
        pending.replacing?.close()
      }
      value.closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: host.window(), queue: .main) { [weak self, weak value] _ in
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            if CommandLine.arguments.contains("--ararat-check=popup") {
              FileHandle.standardError.write(Data("ararat-trace: popup window destroyed\n".utf8))
            }
            if self?.browserCheckMode == "download-close" {
              FileHandle.standardError.write(Data("ararat-trace: download-close popup removed\n".utf8))
            }
            self?.popups.removeAll { $0 === value }
          }
        }
      }
      return Unmanaged.passUnretained(host as AnyObject).toOpaque()
    }
    if offTheRecord {
      // A private window is a full window with the sidebar, backed by the private workspace of
      // its OTR profile. The engine creates it before its Browser exists, so the pointer is the
      // only stable identity; the store is shared until this profile's last window closes.
      guard let profilePointer else { return fallback("no-private-profile") }
      let session = PrivateWorkspaces.acquire(pointer: profilePointer, profile: profile)
      let child = Runtime(windowID: UUID().uuidString)
      child.root = self
      child.isPrivateWindow = true
      child.privatePointer = profilePointer
      do { try child.start(session: session, privateProfile: profile) }
      catch { report(error); PrivateWorkspaces.release(pointer: profilePointer); return fallback("private-child-start") }
      guard let host = child.host else {
        child.host?.close()
        PrivateWorkspaces.release(pointer: profilePointer)
        return fallback("private-child-profile")
      }
      children.append(child)
      return Unmanaged.passUnretained(host as AnyObject).toOpaque()
    }
    let windows = [self] + children
    let matching = windows.filter { !$0.isPrivateWindow && $0.hasUsableHost && $0.host?.profileDirectory() == profile }
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
  var isPrivateWindow = false
  var privatePointer: UInt?
  var privateProfile: String?
  var sidebar: SidebarView?
  var container: SidebarContainerView?
  var workspace: WorkspaceAdapter?
  var keyBindings: KeyBindingsModel?
  var settings: SettingsWindowController?
  var airTraffic: AirTrafficModel?
  // R7: the unread dot is app state from the live strip, never stored or synced.
  var unread = UnreadTracker()
  var seededNewTabRow: String?
  var commandPresenter: CommandBarPresenter?
  var tabSwitcher: TabSwitcher?
  var commandBarConditions: [String: Bool] = [:]
  var commandBarFixtureID: String?
  var commandBarSearchID: String?
  var commandBarInitialID: String?
  var commandBarReloadCount: UInt = 0
  var commandBarPrivateResult: CommandBarResult?
  // U26f pass 3: the private-window check's recorded ids and counters.
  var privateFirstWindowID = ""
  var privateFirstItem = ""
  var privateFirstLive = ""
  var privateRowsBefore: [[String]]?
  var privateHistoryQueries = 0
  var privateWindowCheck: PrivateWindowCheckState?
  var privateIsolationCheck: PrivateIsolationCheckState?
  var privateDownloadsCheck: PrivateDownloadsCheckState?
  var privateDurabilityTitles: [String] = []
  var coreMenuInstalled = false
  var lookCheck: LookScreenCheck?
  var sidebarCheck: SidebarCheck?
  var settingsCheck: SettingsScreenCheck?
  // U27j: the onboarding window, the fake screen-4 setter the check injects, the import the
  // progress screen schedules (held while a check captures it), and the check's state.
  var onboardingWindow: OnboardingWindowController?
  var onboardingPendingImport: (@MainActor () -> Void)?
  var onboardingDefaultBrowser: FakeDefaultBrowserSetter?
  var onboardingCheck: OnboardingCheckState?
  var sharedLookProbe: LookCheckProbe?
  // The space-name check waits for the look popover's open animation: the last frame seen.
  var sharedLookFrame: NSRect?
  var sidebarChecksActive = false
  var sidebarSeedTraced = false
  var sidebarFirstTransactionTraced = false
  var dockCheck: DockScreenCheck?
  var organizeConditions: [String: Bool] = [:]
  var organizeCancelStarted = false
  /// p4checks: when the hover-hold drag began, so a folder that never opens is a named failure.
  var organizeHoverStarted: TimeInterval = 0
  /// p4checks: the resolver's answer for the first-favourite drop, scored only once it lands.
  var organizeFirstFavoriteTarget = false
  var organizeImage: String?
  weak var settingsOwner: Runtime?
  var displacedMenuItems: [String: NSMenuItem] = [:]
  var keyboardResults: [String: Any] = [:]
  var keyboardSidebarBefore = ""
  var keyboardLibraryBefore = false
  var profileFocusEventCount = 0
  var profileFocusNoneObserved = false
  var profileNewFocusNoneEvent = false
  var profileFocusPhaseTicks = 0
  var profileFocusEventsAtReturn: [Int] = []
  var keyboardSettingsTabs = Set<String>()
  weak var keyboardSettingsWindow: NSWindow?
  var keyboardLiveID = ""
  var keyboardNavigation: UInt = 0
  var keyboardScriptPending = false
  var keyboardScriptResult: String?
  var keyboardOtherItem = ""
  var keyboardStaleIndex = 0
  var keyboardFindRequest = 0
  var keyboardRestoreItem = ""
  // p4checks: the Library phase's second archived row, its presses and their bounded waits.
  var keyboardLibraryDeleteItem = ""
  var keyboardRowWaited = 0
  var keyboardRestoreWaited = 0
  var keyboardFindOtherItem = ""
  var keyboardFindOtherLive = ""
  var keyboardFindTeardownText = ""
  var spaceMatrixPhase = 0
  var spaceMatrixNumber = 1
  var spaceMatrixIDs: [String] = []
  struct MatrixTarget {
    let space: String
    let item: String
    let profile: String
    let url: String
    var live: String?
  }
  var matrixTargets: [MatrixTarget] = []
  var matrixSetupIndex = 0
  var matrixSetupGeneration = 0
  var matrixCommand: String?
  var matrixCommandOpens = false
  var matrixAcknowledgedLive: String?
  var matrixAcknowledgedEpoch: UInt64?
  var matrixReturning = false
  var matrixEpoch: UInt64?
  var matrixEpochChanged = false
  var matrixCommandInvariantFailed = false
  var spaceMatrixSuggestionPassed: [Int] = []
  var spaceMatrixMenuPassed: [Int] = []
  var spaceMatrixCommandIndex = 0
  var spaceMatrixCommandsPassed: [String] = []
  var spaceMatrixCommandItem = ""
  var spaceMatrixCommandLive = ""
  var spaceMatrixWasPinned = false
  var spaceMatrixSidebarBefore = ""
  var spaceMatrixLibraryBefore = false
  var spaceMatrixDefaultWidth: CGFloat = 0
  var spaceMatrixBeforeRows: [[String]]?
  var spaceMatrixBeforeTabCount = 0
  var spaceMatrixBeforeSelected: String?
  var spaceMatrixSetup: [String: Any] = [:]
  var spaceMatrixLastTransaction: [String: Any] = [:]
  var keyboardSavedURL = ""
  var incognitoTabsBefore = 0
  var incognitoWindowRows: [[String]]?
  var incognitoWindowID = ""
  var incognitoWindowItem = ""
  var incognitoPrivateItem = ""
  var incognitoWindowLive = ""
  var incognitoPrivateLive = ""
  var incognitoPrivateProfile = ""
  var incognitoPrivateBrowser = ""
  var snapshot = WorkspaceSnapshot(archive: [], shownSpaceId: nil, selectedId: nil, spaces: [])
  // A check that owns this window's profile (relaunch-pins' isolation child) keeps the snapshot
  // delivery from setting it back to the space the window shows.
  var profilePinned = false
  var sliceTimer: Timer?
  var sliceRows: [Row] = []
  var relaunchSeedRows: [Row] = []
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
  var quitDialogPages: [[String: Any]] = []
  var quitClosedRows: [[String]]?
  var quitReopened = false
  var quitDockEmpty = false
  var quitStock: UInt = 0
  var quitTimedOut = false
  var quitResultPrinted = false
  var quitResultOK = false
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
  var profileCloseAfterPrevious: [[String]]?
  var profileCloseCancelled: [String: Any] = [:]
  var profileCloseFinal: [String: Any] = [:]
  var splitCloseExpected: [String: String] = [:]
  var splitCloseBefore: WorkspaceSnapshot?
  var splitPanelBeforeRows: [[String]]?
  var splitPanelLive = ""
  weak var splitPanelPage: NSView?
  var splitCloseRaceCommand: String?
  var splitCloseRaceSettled = false
  var splitCloseRaceFailed = false
  var splitCloseRaceActivated = false
  var splitCloseConfirmRaceOK = true
  var committedSwitchRace = false
  var multiCloseChildItem = ""
  var multiCloseChildLive = ""
  var multiCloseChildSpace = ""
  var multiCloseChildWindowID = ""
  var multiCloseRootLive = ""
  weak var multiCloseRootPage: NSView?
  var multiCloseDefaultItems: Set<String> = []
  var multiClosePassed = false
  var multiQuitFirst: [String: Any] = [:]
  var multiQuitSecond: [String: Any] = [:]
  var multiCloseOriginal: [[String]]?
  var childRaceCommand: String?
  var childRaceActivated = false
  var childRaceCompleted = false
  var profileCheckResult: [String: Any] = [:]
  var profileCheckPassed = false
  var browserCheckTimer: Timer?
  var browserCheckPhase = 0
  var browserCheckAttempts = 0
  var browserCheckTracedPhase = -1
  var keyboardCommandTx = 0
  var keyboardCommandActive: String?
  var keyboardSelectionMark = 0
  var keyboardDevToolsReadyState: [String: Any] = [:]
  var browserCheckRows: [Row] = []
  var browserCheckSeedID: String?
  var historyClearCheck: HistoryClearCheck?
  var historyPurgeCheck: HistoryPurgeCheck?
  var browserCheckBefore: WorkspaceSnapshot?
  var popupNewTabBefore: [(live: String, item: String?)] = []
  var popupNewTabRows: Set<String> = []
  var popupNewTabDestination = ""
  var checkSeedSelectionStage = "not_started"
  var browserCheckPopupSize = NSSize.zero
  var browserCheckPopupOpenerAlive = false
  var browserCheckPopupOpenerProbeStarted = false
  var browserCheckStyleMask: UInt = 0
  var browserCheckStock: UInt = 0
  var promptFixture: PromptFixtureServer?
  var promptFixturePort: UInt16?
  var promptFixtureError: String?
  var downloadCloseConditions: [String: Bool] = [:]
  var downloadsCheck: DownloadsCheck?
  var toastsCheck: ToastsCheck?
  var splitFocusCheck: SplitFocusCheck?
  var splitCommandsCheck: SplitCommandsCheck?
  var splitFocusDispatches: [String: Int] = [:]
  var headerCheck: HeaderCheck?
  var siteControlsCheck: SiteControlsCheck?
  var extensionActionsCheck: ExtensionActionsCheck?
  var urlFieldCheck: URLFieldCheckState?
  var littleWindowCheck: LittleWindowCheckState?
  // P4 item 6: the create-space check's injected core error (always 0 in a shipping run).
  var createSpaceFailureInjections = 0
  var createSpaceCheck: CreateSpaceCheckState?
  var folderUploadCheck: FolderUploadCheckState?
  var windowDragCheck: WindowDragCheckState?
  var pinsIsolationChild: Runtime?
  var siteFixture: SiteFixtureServer?
  var siteFixturePorts: SiteFixtureServer.Ports?
  var siteFixtureError: String?
  // U26e: the focused site snapshot and the extension action list both come from the engine's
  // callbacks; the app only mirrors them into the UI and the checks.
  var siteState: SiteState?
  var siteControls: SiteControlsPopover?
  var siteOverlay: SiteCaptureOverlay?
  var siteOverlayDocument = ""
  var lastExtensionAnchor: NSRect?
  var extensionItems: [ExtensionActionItem] = []
  var captureError = ""
  var lastSiteFingerprint = ""
  var downloadCloseFallback = false
  var errorPageConditions: [String: Bool] = [:]
  var errorPageImages: [String: String] = [:]
  var errorPageCapturing = false
  var errorPageItem: String?
  var errorPageNavigationCount: UInt = 0
  var permissionResults: [String: String] = [:]
  var permissionWidgetState: [String: Any] = [:]
  var permissionNavigationCleared = false
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
  var dialogsScreenCapturing = false
  var dialogsScreenChecks: [String: Bool] = [:]
  var dialogsScreenSteps: [String: [String: Any]] = [:]
  var dialogsScreenTicks = 0
  var dialogsScreenFirstLive = ""
  var dialogsScreenTransferID = ""
  var dialogNavigationBefore = 0
  var dialogNavigationCleared = false
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
  var fullscreenRound = 0
  var fullscreenElement: Bool?
  var fullscreenProbePending = false
  var fullscreenProbeGeneration = 0
  var fullscreenResults: [String: Any] = [:]
  var fullscreenTab: (any ARTabAPI)?
  var fullscreenOtherTab: (any ARTabAPI)?
  var fullscreenEnteredNotification = false
  let fullscreenExitGate = FullscreenExitGate()
  var fullscreenCardBefore = NSRect.zero
  var fullscreenNavigation: UInt = 0
  var fullscreenObserver: NSObjectProtocol?
  var fullscreenActivationObserver: NSObjectProtocol?
  var fullscreenActivated = false
  var fullscreenFocusObservers: [NSObjectProtocol] = []
  var fullscreenFocusTrace: [[String: Any]] = []
  var fullscreenFocusTraceDropped = 0
  var fullscreenMenuDispatch: [String: Any] = [:]
  var fullscreenPhase4Observed = false

  func recordFullscreenFocus(_ event: String, window: NSWindow) {
    guard fullscreenFocusTrace.count < 64 else { fullscreenFocusTraceDropped += 1; return }
    fullscreenFocusTrace.append([
      "event": event, "uptime": ProcessInfo.processInfo.systemUptime, "phase": browserCheckPhase,
      "app_active": NSApp.isActive, "window_key": window.isKeyWindow,
      "window_visible": window.isVisible, "can_become_key": window.canBecomeKey,
      "activation_policy": NSApp.activationPolicy().rawValue,
      "style_mask": window.styleMask.rawValue, "collection_behavior": window.collectionBehavior.rawValue,
      "fullscreen_state": host?.checkFullscreenState() ?? [:],
    ])
  }

  func start(session: WorkspaceSession? = nil, shownSpace: String? = nil, reopening: Bool = false, privateProfile: String? = nil) throws {
    let arguments = CommandLine.arguments
    let checkName = arguments.first(where: { $0.hasPrefix("--ararat-check=") }).map { String($0.dropFirst(15)) }
    let screenName = arguments.first(where: { $0.hasPrefix("--ararat-screen=") }).map { String($0.dropFirst(16)) }
    if session == nil, let checkName, !["slice", "quit", "quit-cancel", "close", "newtab", "popup", "menu", "empty", "deferred", "profiles", "ext-windows", "ext-popup", "ext-windows-popup", "incognito", "permissions", "dialogs", "protocol", "autofill", "devtools", "fullscreen", "keyboard", "organize", "look", "downloads", "download-close", "errorpages", "dock", "commandbar", "sadtab", "relaunch-seed", "relaunch-verify", "history-clear", "history-purge", "private-window", "private-isolation", "private-downloads", "private-durability-seed", "private-durability-verify", "sidebar-rows", "folder-empty", "today", "space-name", "toasts", "split-focus", "split-commands", "header", "urlfield", "site-controls", "ext-actions", "little-window", "onboarding", "window-drag", "create-space", "folder-upload"].contains(checkName) { return }
    if session == nil {
      quitMode = screenName == "quit" ? "screen-quit" : (["quit", "quit-cancel", "close"].contains(checkName ?? "") ? checkName : nil)
      if ["newtab", "popup", "menu", "empty", "deferred", "profiles", "ext-windows", "ext-popup", "ext-windows-popup", "incognito", "permissions", "dialogs", "protocol", "autofill", "devtools", "fullscreen", "keyboard", "organize", "look", "downloads", "download-close", "errorpages", "dock", "commandbar", "sadtab", "relaunch-seed", "relaunch-verify", "history-clear", "history-purge", "private-window", "private-isolation", "private-downloads", "private-durability-seed", "private-durability-verify", "sidebar-rows", "folder-empty", "today", "space-name", "toasts", "split-focus", "split-commands", "header", "urlfield", "site-controls", "ext-actions", "little-window", "onboarding", "window-drag", "create-space", "folder-upload"].contains(checkName ?? "") { browserCheckMode = checkName }
      if checkName == "download-close" { browserCheckMode = checkName }
      if checkName == "errorpages" { browserCheckMode = checkName }
      if checkName == "devtools" { devtoolsFrontBefore = commandOutput("/usr/bin/lsappinfo", ["front"]) }
      if ["popup", "ext-popup", "ext-windows-popup", "keyboard"].contains(checkName ?? "") { popupFrontBefore = checkFrontApplication() }
      if checkName == "fullscreen" {
        popupFrontBefore = commandOutput("/usr/bin/lsappinfo", ["front"])
        fullscreenActivationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.fullscreenActivated = true }
        }
      }
      if screenName == "links" { browserCheckMode = "screen-links" }
      if screenName == "profiles" { browserCheckMode = "screen-profiles" }
      if screenName == "prompts" { browserCheckMode = "screen-prompts" }
      if screenName == "dialogs" { browserCheckMode = "screen-dialogs" }
      if screenName == "devtools" { browserCheckMode = "screen-devtools" }
      if screenName == "extensions" { browserCheckMode = "screen-extensions" }
      if screenName == "fullscreen" { browserCheckMode = "screen-fullscreen" }
      if screenName == "keyboard" { browserCheckMode = "screen-keyboard" }
      if screenName == "organize" { browserCheckMode = "screen-organize" }
      if screenName == "look" { browserCheckMode = "screen-look" }
      if screenName == "dock" { browserCheckMode = "screen-dock" }
      if screenName == "commandbar" { browserCheckMode = "screen-commandbar" }
      if screenName == "sidebar-rows" { browserCheckMode = "screen-sidebar-rows" }
      if screenName == "folder-empty" { browserCheckMode = "screen-folder-empty" }
      if screenName == "today" { browserCheckMode = "screen-today" }
      if screenName == "space-name" { browserCheckMode = "screen-space-name" }
      if screenName == "errorpages" { browserCheckMode = "screen-errorpages" }
      if screenName == "downloads" { browserCheckMode = "screen-downloads" }
      if screenName == "toasts" { browserCheckMode = "screen-toasts" }
      if screenName == "private-window" { browserCheckMode = "screen-private-window" }
      if screenName == "split-focus" { browserCheckMode = "screen-split-focus" }
      if screenName == "split-commands" { browserCheckMode = "screen-split-commands" }
      if screenName == "header" { browserCheckMode = "screen-header" }
      if screenName == "urlfield" { browserCheckMode = "screen-urlfield" }
      if screenName == "site-controls" { browserCheckMode = "screen-site-controls" }
      if screenName == "ext-actions" { browserCheckMode = "screen-ext-actions" }
      if screenName == "little-window" { browserCheckMode = "screen-little-window" }
      if screenName == "onboarding" { browserCheckMode = "screen-onboarding" }
      if screenName == "window-drag" { browserCheckMode = "screen-window-drag" }
      if screenName == "create-space" { browserCheckMode = "screen-create-space" }
      if screenName == "folder-upload" { browserCheckMode = "screen-folder-upload" }
      // U27a: one launch per settings pane, plus the frame and the search. The argument
      // (`settings-tabs`) becomes the check mode every family uses (`screen-settings-tabs`).
      if let screenName, let mode = SettingsScreenCheck.Mode.screenMode(screenName) { browserCheckMode = mode.checkMode }
      if ["permissions", "dialogs", "protocol", "autofill", "keyboard", "commandbar", "downloads", "download-close", "errorpages", "toasts", "split-focus", "split-commands", "sidebar-rows", "header", "urlfield", "private-downloads", "little-window", "folder-upload"].contains(checkName ?? "") || screenName == "prompts" || screenName == "dialogs" || screenName == "keyboard" || screenName == "commandbar" || screenName == "downloads" || screenName == "errorpages" || screenName == "toasts" || screenName == "sidebar-rows" || screenName == "split-focus" || screenName == "split-commands" || screenName == "header" || screenName == "urlfield" || screenName == "little-window" || screenName == "folder-upload" {
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
      if checkName == "site-controls" || checkName == "ext-actions" || screenName == "site-controls" || screenName == "ext-actions" || screenName == "settings-websites" || screenName == "settings-privacy" {
        do {
          let fixture = try SiteFixtureServer()
          siteFixture = fixture
          fixture.start { [weak self] result in
            DispatchQueue.main.async {
              switch result {
              case .success(let ports):
                self?.siteFixturePorts = ports
                FileHandle.standardError.write(Data("ararat-trace: site-fixture plain=\(ports.plain) secure=\(ports.secure)\n".utf8))
              case .failure(let error):
                self?.siteFixtureError = String(describing: error)
                FileHandle.standardError.write(Data("ararat-trace: site-fixture failed \(error)\n".utf8))
              }
            }
          }
        } catch {
          // The check reports this as its named `fixture` condition instead of a
          // startup failure the harness cannot attribute.
          siteFixtureError = String(describing: error)
          FileHandle.standardError.write(Data("ararat-trace: site-fixture startup \(error)\n".utf8))
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
    let organize = browserCheckMode == "organize" || browserCheckMode == "screen-organize"
    let dockCheckMode = browserCheckMode == "dock" || browserCheckMode == "screen-dock"
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
    if let privateProfile { self.privateProfile = privateProfile }
    guard let purgeSymbol = dlsym(Launcher.handle, "AraratPurgeTabHistory"),
          let finishSymbol = dlsym(Launcher.handle, "AraratFinishCrashRecovery") else {
      throw NSError(domain: "Ararat.history", code: 1)
    }
    typealias PurgeHistory = @convention(c) (UnsafeRawPointer, UnsafeRawPointer, UInt64, @escaping @convention(block) (Bool) -> Void) -> Void
    let purgeHistory = unsafeBitCast(purgeSymbol, to: PurgeHistory.self)
    let finishCrashRecovery = unsafeBitCast(finishSymbol, to: (@convention(c) () -> Void).self)
    running.finishCrashRecovery = { finishCrashRecovery() }
    running.purgeHistory = { profile, item, changedAt, completion in
      let profileObject = profile as NSString
      let itemObject = item as NSString
      purgeHistory(Unmanaged.passUnretained(profileObject).toOpaque(), Unmanaged.passUnretained(itemObject).toOpaque(), changedAt, completion)
    }
    var adoptedWindow = false
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
      let adopted = kept.first { !openIDs.contains($0.id) }
      adoptedWindow = adopted != nil
      windowID = adopted?.id ?? UUID().uuidString
    }
    let card = NSView()
    promptPageCard = card
    let check = session == nil && (arguments.contains("--ararat-check=slice") || quitMode != nil || browserCheckMode != nil)
    let profileCheck = ["profiles", "ext-windows", "incognito", "private-window", "private-isolation", "screen-private-window", "screen-profiles", "keyboard", "screen-keyboard", "screen-dialogs", "downloads", "screen-downloads", "toasts", "screen-toasts", "split-focus", "screen-split-focus", "split-commands", "screen-split-commands"].contains(browserCheckMode ?? "") || quitMode == "quit-cancel"
    let sidebarCheckActive = ["sidebar-rows", "folder-empty", "today", "space-name", "screen-sidebar-rows", "screen-folder-empty", "screen-today", "screen-space-name"].contains(browserCheckMode ?? "")
    self.sidebarChecksActive = sidebarCheckActive
    // U27a's settings screen checks seed their own three spaces (the search needs space rows, the
    // Spaces pane needs more than one row, and U27c's wheel needs a middle space), so they are
    // neither single nor sidebar seeds. U27w's Websites check seeds two profiles instead, so the
    // site summaries name their profile (W2), and seeds it instead of the three spaces.
    let settingsCheckActive = SettingsScreenCheck.Mode.mode(browserCheckMode ?? "") != nil
    let websitesCheckActive = browserCheckMode == "screen-settings-websites"
    // U27x's Extensions check seeds the same two profiles as Websites, not the three spaces: its
    // chooser switches between them (X1).
    let extensionCheckActive = browserCheckMode == "screen-settings-extensions"
    // U27j: the onboarding flow imports Arc into the check's db itself, so the window starts with
    // an empty workspace and no seed of any kind.
    let onboardingCheckActive = ["onboarding", "screen-onboarding"].contains(browserCheckMode ?? "")
    let singleCheck = (browserCheckMode != nil && !profileCheck && !organize && !dockCheckMode && !sidebarCheckActive && !settingsCheckActive && !onboardingCheckActive && browserCheckMode != "little-window" && browserCheckMode != "screen-little-window" && browserCheckMode != "relaunch-seed") || (quitMode != nil && quitMode != "quit")
    let linkCheck = browserCheckMode == "screen-links"
    let profileURL = ["ext-windows", "screen-profiles"].contains(browserCheckMode ?? "")
      ? "chrome-extension://kmgaadhbnkendcanjninlfmfgehagggl/probe.html" : "about:blank"
    let extensionPopupCheck = ["ext-popup", "ext-windows-popup", "screen-extensions"].contains(browserCheckMode ?? "")
    let adapter = try EngineAdapter(path: path, windowID: windowID, card: card, seedCheck: check && !singleCheck && !profileCheck && !organize && !dockCheckMode && !sidebarCheckActive && !settingsCheckActive && !onboardingCheckActive && browserCheckMode != "little-window" && browserCheckMode != "screen-little-window", seedSingleCheck: check && singleCheck && !linkCheck && browserCheckMode != "relaunch-verify" && browserCheckMode != "private-durability-verify", seedLinkCheck: check && linkCheck, seedProfiles: check && profileCheck, seedSplitCheck: check && profileCheck && (arguments.contains("--ararat-split-close-check") || browserCheckMode == "screen-dialogs"), seedSplitCommands: check && (browserCheckMode == "split-commands" || browserCheckMode == "screen-split-commands"), seedToastSplit: check && (browserCheckMode == "toasts" || browserCheckMode == "screen-toasts" || browserCheckMode == "split-focus" || browserCheckMode == "screen-split-focus"), seedOrganize: check && organize, seedDock: check && dockCheckMode, seedSidebar: check && sidebarCheckActive, seedLittleWindow: check && (browserCheckMode == "little-window" || browserCheckMode == "screen-little-window"), seedSettings: check && settingsCheckActive && !websitesCheckActive && !extensionCheckActive, seedWebsites: check && (websitesCheckActive || extensionCheckActive), profileCheckURL: profileURL, singleCheckURL: extensionPopupCheck ? "chrome-extension://kmgaadhbnkendcanjninlfmfgehagggl/probe.html" : nil, requireExisting: browserCheckMode == "relaunch-verify", private: isPrivateWindow, session: running)
    if check && ["screen-dialogs", "downloads", "screen-downloads"].contains(browserCheckMode ?? "") {
      let seeded = adapter.session.queue.sync { adapter.session.store?.snapshot(windowId: windowID) }
      let rows = seeded?.spaces.map { space in
        "\(space.id):profile=\(space.profileName):today=\(space.today.map(\.id)):pinned=\(space.pinned.map(\.id))"
      } ?? []
      let name = browserCheckMode == "screen-dialogs" ? "dialogs" : "downloads"
      FileHandle.standardError.write(Data("ararat-trace: \(name) seed db=\(path) shown=\(seeded?.shownSpaceId ?? "nil") rows=\(rows)\n".utf8))
    }
    if let shownSpace {
      try adapter.session.queue.sync { try adapter.session.store?.showSpace(windowId: windowID, spaceId: shownSpace) }
    }
    let workspace = WorkspaceAdapter(windowID: windowID, session: adapter.session, private: isPrivateWindow)
    // U27k D5: the Theme is one synced setting for the whole app, so it is applied before this
    // window exists (no flash of the other appearance) and again by every later window, which
    // reads the same record. A private window's own workspace starts from the built-in values,
    // so it reads the regular one, and a nil answer leaves the app's appearance alone.
    let themeSession = isPrivateWindow ? (root?.adapter?.session ?? adapter.session) : adapter.session
    if let theme = themeSession.queue.sync(execute: { themeSession.store?.settings().theme }) {
      NSApp.appearance = theme.appearance
    }
    // U27w W1: the Websites defaults are the core's record, pushed into Chromium's profiles
    // before the first page of this window can ask for one.
    if let defaults = themeSession.queue.sync(execute: { themeSession.store?.settings().siteDefaults }) {
      EngineSiteSettingsHost.apply(defaults)
    }
    // U27p P2/P3: the Privacy record is applied before the first page of this window can load, so
    // the cookie mode, the GPC signal and the history retention are already in Chromium's profiles.
    if let privacy = themeSession.queue.sync(execute: { themeSession.store?.settings().privacy }) {
      EnginePrivacySettingsHost.apply(privacy)
    }
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: nil, selectedId: nil, spaces: []))
    sidebar.privateWindow = isPrivateWindow
    sidebar.observeHistoryFailures(running)
    let downloads = DownloadsModel()
    sidebar.setDownloadsModel(downloads)
    let container = SidebarContainerView(sidebar: sidebar, page: card)
    container.privateWindow = isPrivateWindow
    typealias Factory = @convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> UnsafeMutableRawPointer?
    let factory = unsafeBitCast(createSymbol, to: Factory.self)
    let hostID = windowID as NSString
    guard let pointer = factory(Unmanaged.passUnretained(container).toOpaque(), Unmanaged.passUnretained(hostID).toOpaque()),
          let host = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? any ARWindowHostAPI else {
      throw NSError(domain: "Ararat", code: 3)
    }
    self.host = host
    if isPrivateWindow { host.window().appearance = NSAppearance(named: .darkAqua) }
    downloads.onAction = { [weak host] action, identifier in
      host?.performDownloadAction(action, identifier: identifier) ?? false
    }
    adapter.onDownloads = { [weak sidebar, weak card] items, newDownload, flight in
      downloads.update(items)
      if flight, let newDownload, let card { sidebar?.flyDownload(from: card, name: downloads.items.first(where: { $0.id == newDownload })?.name ?? "") }
    }
    observeClose(host)
    self.adapter = adapter
    self.workspace = workspace
    self.airTraffic = AirTrafficModel(adapter: workspace)
    let bindings = KeyBindingsModel(adapter: workspace)
    self.keyBindings = bindings
    bindings.onChange = { [weak sidebar, weak bindings] in
      if let bindings { sidebar?.keyBindings = bindings.bindings }
    }
    bindings.load { [weak self] result in
      if case .failure(let error) = result { self?.report(error) }
    }
    sidebar.onEditURL = { [weak self] in self?.openCommandBar(.editURL) }
    self.sidebar = sidebar
    self.container = container
    adapter.onPageFullscreenChanged = { [weak container] in container?.pageFullscreen = $0 }
    adapter.onWindowFullscreenChanged = { [weak container] in container?.windowFullscreen = $0 }
    adapter.onWorkspaceCommand = { [weak self] command in self?.performWorkspaceCommand(command) }
    adapter.onFindBar = { [weak container, weak host] state in
      if CommandLine.arguments.contains("--ararat-compositor=c2"), state["visible"] as? Bool == true,
         let root = host?.window().contentView { container?.placeFindBarAbovePage(in: root) }
      container?.findBar.update(state: state)
    }
    adapter.findBarHasFocus = { [weak container] in container?.findBar.hasFocus ?? false }
    adapter.onFindPageRect = { [weak container] in container?.setFindPageRect($0) }
    container.findBar.onAction = { [weak host] action, text, selection, live, profile in host?.findAction(action, text: text, selection: selection, liveId: live, profile: profile) }
    container.onHeaderCommand = { [weak self, weak host] command in
      if command == "settings" { self?.openSettings() }
      // U27b: the header's two site commands are core commands now, so its ids go through the
      // one dispatcher the Ararat Commands menu, the command bar and a recorded key use.
      else if command == "clear_cache_site" || command == "clear_cookies_site" { self?.performWorkspaceCommand(command) }
      else { _ = host?.runCommand(command) }
    }
    container.header.siteDomain = { [weak host] in host?.currentSiteDomain() }
    sidebar.onSiteControls = { [weak self, weak container] rect in
      guard let self, let container else { return }
      self.showSiteControls(rect, in: container)
    }
    sidebar.onExtensionAction = { [weak self] item in self?.invokeExtensionAction(item) }
    sidebar.onExtensionMenu = { [weak self] item in self?.extensionMenu(item) }
    sidebar.onExtensionAnchor = { [weak self, weak host] rect in
      self?.lastExtensionAnchor = rect
      host?.setExtensionAnchor(rect)
    }
    adapter.onSiteStateChanged = { [weak self] in self?.refreshSiteState() }
    adapter.onExtensionActionsChanged = { [weak self] in self?.refreshExtensionActions() }
    adapter.onSnapshot = { [weak self, weak sidebar, weak container] snapshot in
      guard self?.host?.isClosing() != true, self?.host?.isClosingAll() != true else { return }
      self?.snapshot = snapshot
      self?.updatePageVisibility(snapshot)
      if let self, (self.root ?? self).settingsOwner === self { (self.root ?? self).settings?.modelUpdate(snapshot: snapshot) }
      if self?.isPrivateWindow != true, self?.host?.isClosingAll() != true, self?.profilePinned != true,
         let space = snapshot.spaces.first(where: { $0.id == snapshot.shownSpaceId }) {
        // A check that pinned this window's profile (relaunch-pins' isolation child) keeps it:
        // the child's own first snapshot names the Default space and would otherwise undo the
        // switch the check made, which is the race that flake showed.
        _ = self?.host?.setProfileDirectory(space.profileName)
      }
      let active = self?.host?.activeItemId()
      if let active, active == snapshot.selectedId, let tab = (self?.host?.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == active }) {
        sidebar?.focusedPane = (active, tab.url)
      } else { sidebar?.focusedPane = nil }
      sidebar?.update(snapshot: snapshot)
      for controller in self?.littleWindows ?? [] { controller.originSnapshotChanged(snapshot) }
      self?.refreshSidebarRowState(snapshot)
      container?.selectionChanged()
      container?.privateEmptyShown = self?.isPrivateWindow == true && snapshot.selectedId == nil
      if check {
        let rows = snapshot.spaces.flatMap { $0.today + $0.pinned + $0.favorites }
        self?.sliceRows = ["One", "Two", "Three"].compactMap { name in
          rows.first { $0.url == "data:text/html,<title>Ararat \(name)</title>" }
        }
        if linkCheck { self?.sliceRows = rows.filter { $0.url?.contains("Open link") == true } }
        if self?.browserCheckMode == "keyboard" || self?.browserCheckMode == "screen-keyboard" {
          self?.sliceRows = snapshot.spaces.first(where: { $0.id == snapshot.shownSpaceId })?.today ?? []
        }
        if self?.browserCheckMode == "screen-dialogs" { self?.sliceRows = Self.dialogSeedRows(snapshot) }
        if extensionPopupCheck { self?.sliceRows = rows.filter { $0.url?.contains("/probe.html") == true } }
      }
    }
    adapter.onTransaction = { [weak self] transaction, applied in
      guard let self else { return }
      if self.browserCheckMode == "screen-dialogs" && self.sliceTransactions == 0 {
        let strips = transaction.strips.map { "window=\($0.window) active=\($0.active ?? "nil") items=\($0.tabs.map { $0.item ?? "nil" })" }
        FileHandle.standardError.write(Data("ararat-trace: dialogs first-transaction rev=\(transaction.rev) cause=\(transaction.cause) applied=\(applied) strips=\(strips)\n".utf8))
      }
      self.recordMatrixTransaction(transaction, applied: applied, usableHost: self.hasUsableHost)
      self.sliceTransactions += 1
      if case .command = transaction.cause, applied, let strip = transaction.strips.first {
        self.keyboardCommandTx += 1
        self.keyboardCommandActive = strip.tabs.first { $0.liveId == strip.active }?.item
      }
      self.sliceLastRev = transaction.rev
      for strip in transaction.strips {
        self.sliceActive = strip.tabs.first { $0.liveId == strip.active }?.item
      }
      self.recordUnread(transaction)
      // R5: a crashed renderer is reported by the strip, not by a snapshot.
      self.sidebar?.crashedItems = Set(self.adapter?.crashedItems ?? [])
      self.sidebar?.rowStates = self.adapter?.rowStates ?? [:]
      let headerState = host.activeItemId().flatMap { self.adapter?.rowStates[$0] }
      self.container?.header.canGoBack = headerState?.canGoBack ?? false
      self.container?.header.canGoForward = headerState?.canGoForward ?? false
      self.container?.header.loading = headerState?.loading ?? false
      self.container?.header.hasTab = host.activeItemId() != nil
      if self.sidebarChecksActive, !self.sidebarFirstTransactionTraced {
        self.sidebarFirstTransactionTraced = true
        let active = transaction.strips.first?.active ?? "-"
        FileHandle.standardError.write(Data("ararat-trace: sidebar-first-transaction epoch=\(transaction.epoch) rev=\(transaction.rev) cause=\(String(describing: transaction.cause)) strips=\(transaction.strips.count) active=\(active)\n".utf8))
      }
      if CommandLine.arguments.contains("--ararat-space-matrix-check"), self.browserCheckMode != nil {
        self.spaceMatrixLastTransaction = ["epoch": transaction.epoch, "rev": transaction.rev,
          "cause": String(describing: transaction.cause), "strips": transaction.strips.prefix(10).map { strip in
            ["window": strip.window, "active": strip.active ?? "", "tabs": strip.tabs.prefix(20).map {
              ["live": $0.liveId, "item": $0.item ?? "", "profile": String(describing: $0.profile)]
            }] as [String: Any]
          }]
      }
    }
    adapter.onWorkspaceChange = { [weak self] in self?.refreshOtherWindows() }
    adapter.onRowClose = { [weak self] id in self?.sidebar?.expectRowClose(id: id) }
    adapter.onQuitProfileSwitch = { [weak self] in self?.quitDuringProfileSwitch = self?.captureCheckRows() }
    adapter.onCloseStarted = { [weak self] in
      self?.selectionGeneration += 1
      self?.workspace?.cancelPendingSpaceSwitches()
      self?.commandPresenter?.close(restoreFocus: false)
      self?.tabSwitcher?.cancel()
      // S1: a region selection does not outlive the window it drew in.
      self?.siteOverlay?.cancel()
    }
    let actions = SidebarActions()
    actions.onSelect = { [weak self, weak adapter] row in
      self?.selectionGeneration += 1
      self?.workspace?.cancelPendingSpaceSwitches()
      self?.host?.setWorkspacePageHidden(false)
      // U25d S4: a tab picked on its own takes that tab alone when its split is shown in another
      // window; the split row's own click below still brings every pane.
      if let url = row.url { adapter?.select(id: row.id, url: url, wholeSplit: false) }
      else if row.kind == .split, let self {
        let generation = self.selectionGeneration
        self.workspace?.select(id: row.id) { [weak self] result in
          guard let self, self.selectionGeneration == generation else { return }
          self.showAndSelect(result)
        }
      }
    }
    actions.configureEditing(adapter: workspace, isActive: { true }, window: { [weak self] in self?.host?.window() }, show: { [weak self] snapshot in self?.show(snapshot) }, record: { [weak self] snapshot in self?.snapshot = snapshot })
    actions.onClose = { [weak self] id in self?.close(id) }
    actions.onCloseSelected = { [weak self] in self?.adapter?.closeSelected() }
    actions.onArchive = { [weak self] id in
      self?.adapter?.close(id: id, archive: true)
    }
    actions.onRemoveFavorite = { [weak self] id in
      self?.adapter?.close(id: id, archive: true, animate: false)
    }
    actions.onNewTab = { [weak self] in self?.performWorkspaceCommand("new_tab") }
    actions.onClearToday = { [weak self] in self?.clearToday() }
    actions.onShowSpace = { [weak self] id in
      self?.switchWorkspaceSpace(id)
    }
    actions.onRestore = { [weak self] id in
      self?.restoreWorkspaceItem(id)
    }
    actions.onArchiveDelete = { [weak self] id in
      self?.workspace?.deleteArchive(id: id) { [weak self] result in self?.showResult(result) }
    }
    actions.onRenameSpace = { [weak self, weak workspace] id, name, done in
      let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !title.isEmpty, let workspace else { done(false); return }
      workspace.renameSpace(id: id, name: title) { [weak self] result in
        if case .success = result { done(true) } else { done(false) }
        self?.showResult(result)
      }
    }
    actions.onDeleteSpace = { [weak self, weak workspace] id in
      workspace?.deleteSpace(id: id) { [weak self] result in
        switch result {
        case .success(let next): self?.showWorkspaceEdit(next)
        case .failure(let error): self?.report(error)
        }
      }
    }
    actions.onSpaceSettings = { [weak self] id in self?.openSettings(spaceID: id) }
    if let keyBindings, let airTraffic {
      actions.lookSettings = SettingsModel(snapshot: snapshot, adapter: workspace, publish: { [weak self] in self?.showWorkspaceEdit($0) },
        resetWidth: { [weak self] in self?.container?.resizeHandle.resetWidth() },
        preview: { [weak self] id, look, active in self?.sidebar?.previewLook(spaceID: id, look: look, active: active) },
        keyBindings: keyBindings, airTraffic: airTraffic)
    }
    actions.onCreateSpace = { [weak self, weak workspace] name in
      guard let self else { return }
      // The create-space check's injected refusal: the counter is 0 unless that check asked
      // for it, so no shipping path reaches this branch.
      if self.createSpaceFailureInjections > 0 {
        self.createSpaceFailureInjections -= 1
        self.report(NSError(domain: "ararat-check", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "injected create-space failure"]))
        self.sidebar?.creationFailed(Self.createSpaceFailureMessage)
        return
      }
      workspace?.createSpace(name: name) { [weak self] result in
        guard let self else { return }
        switch result {
        case .success(let next):
          // P4 item 6: the page must leave its submit state. The harness called
          // applyCreatedSpace; the app only showed the snapshot, so the Create Space button
          // stayed greyed and the page never closed (the owner, 2026-11-15).
          self.sidebar?.applyCreatedSpace(snapshot: next)
          self.show(next)
        case .failure(let error):
          self.report(error)
          self.sidebar?.creationFailed(Self.createSpaceFailureMessage)
        }
      }
    }
    actions.onCreatePageChanged = { [weak self] in self?.container?.selectionChanged() }
    actions.bind(to: sidebar)
    // U25d: the split row's segment menu, the page-half drop and its mark.
    sidebar.onPaneCommand = { [weak self] command, pane in
      guard let self, let adapter = self.adapter else { return }
      switch command {
      case .moveBackward: adapter.movePane(item: pane, forward: false)
      case .moveForward: adapter.movePane(item: pane, forward: true)
      case .addLeft: adapter.addSplitPane(item: pane, side: .left)
      case .addRight: adapter.addSplitPane(item: pane, side: .right)
      case .separate: adapter.separatePane(item: pane)
      case .convert: adapter.convertSplit(item: pane)
      case .close: self.closePane(pane)
      }
    }
    sidebar.splitIsVertical = { [weak adapter] pane in adapter?.splitIsVertical(pane) }
    sidebar.onMakeSplit = { [weak adapter] dragged, target, side, done in
      guard let adapter else { done(false); return }
      adapter.makeSplit(dragged: dragged, target: target, side: side) { made in done(made) }
    }
    sidebar.pageHalfAt = { [weak container] point, axis in container?.paneDropHalf(at: point, axis: axis) }
    sidebar.showPaneDrop = { [weak container] half in container?.showPaneDrop(half) }
    adapter.attach(host)
    refreshSiteState()
    refreshExtensionActions()
    if session == nil && adoptedWindow { adapter.restoreSelection() }
    if session == nil && !adoptedWindow { running.finishCrashRecovery?() }
    if session == nil && !arguments.contains(where: { $0.hasPrefix("--ararat-screen=") }) &&
       (browserCheckMode == "profiles" || browserCheckMode == "keyboard" || browserCheckMode == "today" || quitMode == "quit-cancel" || quitMode == "close") {
      host.installCheckDialogFactory()
    }
    if root == nil { installCoreMenu() }
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
      if browserCheckMode == "sidebar-rows" || browserCheckMode == "folder-empty" || browserCheckMode == "today" || browserCheckMode == "space-name" || browserCheckMode == "screen-links" || browserCheckMode == "screen-profiles" || browserCheckMode == "screen-prompts" || browserCheckMode == "screen-dialogs" || browserCheckMode == "screen-devtools" || browserCheckMode == "screen-extensions" || browserCheckMode == "screen-fullscreen" || browserCheckMode == "screen-keyboard" || browserCheckMode == "screen-organize" || browserCheckMode == "screen-look" || browserCheckMode == "look" || browserCheckMode == "screen-dock" || browserCheckMode == "screen-commandbar" || browserCheckMode == "screen-sidebar-rows" || browserCheckMode == "screen-folder-empty" || browserCheckMode == "screen-today" || browserCheckMode == "screen-space-name" || browserCheckMode == "screen-errorpages" || browserCheckMode == "downloads" || browserCheckMode == "screen-downloads" || browserCheckMode == "toasts" || browserCheckMode == "screen-toasts" || browserCheckMode == "private-window" || browserCheckMode == "screen-private-window" || browserCheckMode == "split-focus" || browserCheckMode == "screen-split-focus" || browserCheckMode == "split-commands" || browserCheckMode == "screen-split-commands" || browserCheckMode == "header" || browserCheckMode == "screen-header" || browserCheckMode == "urlfield" || browserCheckMode == "screen-urlfield" || browserCheckMode == "site-controls" || browserCheckMode == "screen-site-controls" || browserCheckMode == "ext-actions" || browserCheckMode == "screen-ext-actions" || browserCheckMode == "little-window" || browserCheckMode == "screen-little-window" || browserCheckMode == "window-drag" || browserCheckMode == "screen-window-drag" || browserCheckMode == "create-space" || browserCheckMode == "screen-create-space" || browserCheckMode == "folder-upload" || browserCheckMode == "screen-folder-upload" || browserCheckMode == "private-isolation" || browserCheckMode == "private-downloads" || SettingsScreenCheck.Mode.mode(browserCheckMode ?? "") != nil {
        if browserCheckMode == "screen-fullscreen" {
          let window = host.window()
          for (name, object) in [(NSApplication.didBecomeActiveNotification, NSApp as AnyObject), (NSApplication.didResignActiveNotification, NSApp as AnyObject), (NSWindow.didBecomeKeyNotification, window as AnyObject), (NSWindow.didResignKeyNotification, window as AnyObject), (NSWindow.willEnterFullScreenNotification, window as AnyObject), (NSWindow.willExitFullScreenNotification, window as AnyObject), (NSWindow.didExitFullScreenNotification, window as AnyObject)] {
            fullscreenFocusObservers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self, weak window] _ in
              MainActor.assumeIsolated {
                if name == NSWindow.didExitFullScreenNotification { self?.fullscreenExitGate.didExit() }
                if let window { self?.recordFullscreenFocus(name.rawValue, window: window) }
              }
            })
          }
          recordFullscreenFocus("before_activate", window: window)
        }
        NSApp.activate(ignoringOtherApps: true)
        if browserCheckMode == "screen-fullscreen" {
          recordFullscreenFocus("after_activate", window: host.window())
          fullscreenObserver = NotificationCenter.default.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: host.window(), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
              self?.fullscreenEnteredNotification = true
              if let self, let window = self.host?.window() { self.recordFullscreenFocus("did_enter_fullscreen", window: window) }
            }
          }
        }
        host.window().makeKeyAndOrderFront(nil)
        if browserCheckMode == "screen-fullscreen" { recordFullscreenFocus("after_make_key", window: host.window()) }
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
        self?.commandPresenter?.close(restoreFocus: false)
        if let host = weakHost as? any ARWindowHostAPI {
          self?.captureCheckState(host)
          self?.adapter?.closeWindow(quitting: host.isClosingAll())
        }
      }
      DispatchQueue.main.async { [weak self, weak weakHost] in
        guard let self, let weakHost, (self.host as AnyObject?) === weakHost else { return }
        self.host = nil
        self.root?.children.removeAll { $0 === self }
        // The last window of an OTR profile releases its workspace here (a cancelled close
        // never reaches willClose, so the workspace survives it).
        if let pointer = self.privatePointer {
          PrivateWorkspaces.release(pointer: pointer)
          self.privatePointer = nil
        }
      }
    }
  }

  func captureCheckState(_ host: any ARWindowHostAPI) {
    if CommandLine.arguments.contains(where: { $0.hasPrefix("--ararat-selection-race=") }) {
      splitCloseConfirmRaceOK = selectionRaceSettled() && !splitCloseRaceFailed
    }
    if browserCheckMode != nil {
      browserCheckStyleMask = host.window().styleMask.rawValue
      browserCheckStock = host.checkStockBrowsers()
      if browserCheckMode == "profiles" { profileCloseFinal = host.checkProfileCloseState() }
    }
    guard quitMode != nil else { return }
    quitEvents = host.checkClosingEvents()
    quitDialogCount = host.checkDialogCount()
    quitDialogPages = host.checkProfileCloseState()["dialog_pages"] as? [[String: Any]] ?? []
    quitStock = host.checkStockBrowsers()
  }

  func reopen() -> Bool {
    if ["popup", "incognito", "keyboard"].contains(browserCheckMode ?? "") {
      FileHandle.standardError.write(Data("ararat-trace: reopen-callback check=\(browserCheckMode ?? "") phase=\(browserCheckPhase) host=\(hasUsableHost)\n".utf8))
    }
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
    updatePageVisibility(snapshot)
    if (root ?? self).settingsOwner === self { (root ?? self).settings?.modelUpdate(snapshot: snapshot) }
    sidebar?.update(snapshot: snapshot)
    refreshSidebarRowState(snapshot)
    container?.selectionChanged()
    refreshOtherWindows()
  }

  func showWorkspaceEdit(_ next: WorkspaceSnapshot) {
    if let shown = snapshot.shownSpaceId, !next.spaces.contains(where: { $0.id == shown }) {
      showAndSelect(.success(next))
    } else {
      show(next)
    }
  }

  func updatePageVisibility(_ snapshot: WorkspaceSnapshot) {
    if CommandLine.arguments.contains(where: { $0.hasPrefix("--ararat-measure=") }) {
      host?.setWorkspacePageHidden(false)
      return
    }
    let space = snapshot.spaces.first { $0.id == snapshot.shownSpaceId }
    let rows = space.map { $0.today + $0.pinned + $0.favorites } ?? []
    let visible = snapshot.selectedId.map { id in rows.contains { $0.id == splitOwner(id, rows: rows) } } ?? false
    host?.setWorkspacePageHidden(!visible)
  }

  func splitCheckPagesPresented(_ host: any ARWindowHostAPI) -> Bool {
    guard let tabs = host.tabs() as? [any ARTabAPI],
          ["close-split-a", "close-split-b"].allSatisfy({ id in tabs.contains { $0.itemId == id } }) else { return false }
    if CommandLine.arguments.contains("--ararat-compositor=c2") {
      guard let focused = tabs.first(where: { $0.itemId == "close-split-a" }) else { return false }
      return host.checkPagePresentation(focused.liveId)["presented"] as? Bool == true
    }
    return ["close-split-a", "close-split-b"].allSatisfy { id in
      tabs.contains { $0.itemId == id && $0.view?.superview != nil && $0.view?.isHidden == false }
    }
  }

  func selectCheckSeed(_ row: Row) {
    guard let workspace, let host, let adapter, let url = row.url else { checkSeedSelectionStage = "missing_context"; return }
    let space = snapshot.shownSpaceId
    checkSeedSelectionStage = "selecting_workspace"
    workspace.select(id: row.id) { [weak self, weak host, weak adapter] result in
      guard let self, let host, let adapter, let current = self.host,
            (current as AnyObject) === (host as AnyObject), !host.isClosing(), !host.isClosingAll() else { return }
      guard case .success(let selected) = result,
            Self.checkSeedSelectionMatches(selected, item: row.id, space: space),
            let latest = adapter.session.queue.sync(execute: { adapter.session.store?.snapshot(windowId: self.windowID) }),
            Self.checkSeedSelectionMatches(latest, item: row.id, space: space) else {
        self.checkSeedSelectionStage = "workspace_selection_failed_or_stale"; return
      }
      self.checkSeedSelectionStage = "opening_native_page"
      self.show(latest)
      adapter.select(id: row.id, url: url)
      self.checkSeedSelectionStage = "native_page_requested"
    }
  }

  static func checkSeedSelectionMatches(_ snapshot: WorkspaceSnapshot, item: String, space: String?) -> Bool {
    snapshot.shownSpaceId == space && snapshot.selectedId == item &&
      snapshot.spaces.first(where: { $0.id == space })?.today.contains(where: { $0.id == item }) == true
  }

  static func dialogSeedRows(_ snapshot: WorkspaceSnapshot) -> [Row] {
    snapshot.spaces.first(where: { $0.id == snapshot.shownSpaceId })?.today ?? []
  }

  static func popupTabMappings(_ tabs: [(live: String, item: String?)]) -> [String: String]? {
    var items: [String: String] = [:]
    var lives: Set<String> = []
    for tab in tabs {
      guard !tab.live.isEmpty, let item = tab.item, !item.isEmpty,
            lives.insert(tab.live).inserted, items[item] == nil else { return nil }
      items[item] = tab.live
    }
    return items
  }

  func popupStoreMappings(_ items: [String: String]) -> [String: String] {
    guard let adapter else { return [:] }
    return adapter.session.queue.sync {
      var mappings: [String: String] = [:]
      for item in items.keys { mappings[item] = adapter.session.store?.liveTab(item: item) }
      return mappings
    }
  }

  static func checkPopupNewTabInExistingWindow(previousTabs: [(live: String, item: String?)], previousRows: Set<String>,
                                                currentTabs: [(live: String, item: String?)], currentRows: Set<String>,
                                                selected: String?, nativeActive: String?, compositor: String,
                                                presentation: [String: Any], storeMappings: [String: String]) -> Bool {
    guard let old = popupTabMappings(previousTabs), !old.isEmpty,
          let current = popupTabMappings(currentTabs), current.count == old.count + 1,
          old.allSatisfy({ current[$0.key] == $0.value }),
          current.allSatisfy({ storeMappings[$0.key] == $0.value }),
          Set(old.keys).isSubset(of: previousRows), previousRows.isSubset(of: currentRows) else { return false }
    let added = current.filter { old[$0.key] == nil }
    guard added.count == 1, let (item, live) = added.first, !old.values.contains(live),
          currentRows.subtracting(previousRows) == [item], selected == item, nativeActive == item,
          presentation["compositor"] as? String == compositor, presentation["live"] as? String == live,
          presentation["target"] as? Bool == true, presentation["host"] as? Bool == true,
          presentation["visible"] as? Bool == true, presentation["presented"] as? Bool == true else { return false }
    return compositor == "c1" || (compositor == "c2" && presentation["window"] as? Bool == true && presentation["bounds"] as? Bool == true)
  }

  static func checkIncognitoRegularWindowRows(before: [[String]], during: [[String]], after: [[String]],
                                               window: String, item: String) -> Bool {
    guard !window.isEmpty, !item.isEmpty else { return false }
    func records(_ rows: [[String]]) -> [String: String]? {
      var result: [String: String] = [:]
      for row in rows {
        guard row.count == 3 else { return nil }
        let key = row[0] + "\u{0}" + row[1]
        guard result[key] == nil else { return nil }
        result[key] = row[2]
      }
      return result
    }
    guard let old = records(before), let opened = records(during), let closed = records(after),
          old.allSatisfy({ opened[$0.key] == $0.value && closed[$0.key] == $0.value }) else { return false }
    let itemKey = "item\u{0}" + item, windowKey = "window\u{0}" + window, selectedKey = "last_selected\u{0}" + item
    guard Set(opened.keys).subtracting(old.keys) == [itemKey, windowKey, selectedKey],
          Set(closed.keys).subtracting(old.keys) == [itemKey, selectedKey],
          opened[itemKey] == closed[itemKey], opened[selectedKey] == closed[selectedKey],
          let itemBody = opened[itemKey]?.data(using: .utf8),
          let itemRecord = (try? JSONSerialization.jsonObject(with: itemBody)) as? [String: Any],
          itemRecord["id"] as? String == item, itemRecord["lifecycle"] as? String == "Open",
          let membership = itemRecord["membership"] as? [String: Any], membership["parent"] as? String == "today-default",
          let kind = itemRecord["kind"] as? [String: Any], let tab = kind["Tab"] as? [String: Any],
          let url = tab["url"] as? String, url.isEmpty || url.hasPrefix("chrome://newtab/"),
          let windowBody = opened[windowKey]?.data(using: .utf8),
          let windowRecord = (try? JSONSerialization.jsonObject(with: windowBody)) as? [String: Any],
          windowRecord["id"] as? String == window, windowRecord["shown_space"] as? String == "default",
          windowRecord["selected"] as? String == item else { return false }
    return true
  }

  static func checkIncognitoCloseState(tabs: [(live: String, item: String?)], browsers: [[String: Any]],
                                       privateLive: String, privateProfile: String, privateBrowser: String,
                                       childLive: String, childMapping: String?, childReverseMapping: String?) -> Bool {
    guard !privateLive.isEmpty, !privateProfile.isEmpty, !privateBrowser.isEmpty, !childLive.isEmpty,
          childLive != privateLive, childMapping == nil, childReverseMapping == nil, tabs.count == 1,
          tabs[0].live == privateLive, tabs[0].item == nil, browsers.count == 1 else { return false }
    return browsers[0]["off_the_record"] as? Bool == true &&
      browsers[0]["profile_pointer"] as? String == privateProfile &&
      browsers[0]["browser_pointer"] as? String == privateBrowser
  }

  func checkSelectionDiagnostics(item: String?) -> [String: Any] {
    let tabs = (host?.tabs() as? [any ARTabAPI] ?? []).map { tab in
      ["live": tab.liveId, "item": tab.itemId ?? "", "loading": tab.isLoading,
       "navigation_count": tab.navigationCount] as [String: Any]
    }
    let mapped = adapter.map { adapter in
      adapter.session.queue.sync { item.flatMap { adapter.session.store?.liveTab(item: $0) } }
    } ?? nil
    return ["stage": checkSeedSelectionStage, "expected_item": item ?? "", "snapshot_selected": snapshot.selectedId ?? "",
            "snapshot_space": snapshot.shownSpaceId ?? "", "transaction_active": sliceActive ?? "",
            "host_active": host?.activeItemId() ?? "", "host_has_active": host?.hasActiveTab() ?? false,
            "live_mapping": mapped ?? "", "tabs": tabs, "window_visible": host?.window().isVisible ?? false,
            "window_key": host?.window().isKeyWindow ?? false]
  }

  /// The mock's wording for a failed space creation (§7, the B-CreateSpaceStates board).
  static let createSpaceFailureMessage = "The space couldn’t be created. Try again."

  func showResult(_ result: Result<WorkspaceSnapshot, Error>) {
    switch result {
    case .success(let snapshot): show(snapshot)
    case .failure(let error): report(error)
    }
  }

  func showAndSelect(_ result: Result<WorkspaceSnapshot, Error>, expectedSpace: String? = nil, selectedItem: String? = nil) {
    guard case .success(let next) = result else { showResult(result); return }
    guard hasUsableHost, expectedSpace == nil || next.shownSpaceId == expectedSpace,
          let space = next.spaces.first(where: { $0.id == next.shownSpaceId }),
          host?.setProfileDirectory(space.profileName) == true else { return }
    show(next)
    if let id = selectedItem ?? next.selectedId,
       let row = (space.today + space.pinned + space.favorites).first(where: { $0.id == id }),
       let url = row.url { adapter?.select(id: id, url: url) }
  }

  func restoreWorkspaceItem(_ id: String) {
    guard host?.isClosing() != true, host?.isClosingAll() != true else { return }
    selectionGeneration += 1
    workspace?.cancelPendingSpaceSwitches()
    let generation = selectionGeneration
    workspace?.restore(id: id) { [weak self] result in
      guard let self, self.selectionGeneration == generation else { return }
      if case .success = result { self.adapter?.invalidateSelection() }
      self.showAndSelect(result)
      if case .success(let snapshot) = result {
        if let index = snapshot.spaces.firstIndex(where: { $0.id == snapshot.shownSpaceId }) {
          self.sidebar?.showSpaceWithoutNotification(at: index)
        }
        self.sidebar?.setLibraryOpen(false)
      }
    }
  }

  func switchWorkspaceSpace(_ id: String, completion: (() -> Void)? = nil) {
    guard host?.isClosing() != true, host?.isClosingAll() != true else { sidebar?.restoreShownSpace(); return }
    selectionGeneration += 1
    workspace?.cancelPendingSpaceSwitches()
    let generation = selectionGeneration
    workspace?.showSpaceSelecting(id: id) { [weak self] result in
      guard let self, self.selectionGeneration == generation else { return }
      switch result {
      case .failure(let error):
        self.sidebar?.restoreShownSpace()
        self.workspace?.snapshot { [weak self] latest in
          guard let self, self.selectionGeneration == generation, case .success(let snapshot) = latest else { return }
          self.showAndSelect(.success(snapshot))
          if let index = snapshot.spaces.firstIndex(where: { $0.id == snapshot.shownSpaceId }) {
            self.sidebar?.showSpaceWithoutNotification(at: index)
          }
        }
        self.report(error)
      case .success(let snapshot):
        guard snapshot.shownSpaceId == id else { return }
        self.workspace?.snapshot { [weak self] latest in
          guard let self, self.selectionGeneration == generation, case .success(let current) = latest,
                current.shownSpaceId == id else { return }
          self.adapter?.invalidateSelection()
          self.showAndSelect(.success(current), expectedSpace: id)
          if let index = current.spaces.firstIndex(where: { $0.id == id }) {
            self.sidebar?.showSpaceWithoutNotification(at: index)
          }
          completion?()
        }
      }
    }
  }

  func showSuggestedSpace(_ id: String) {
    guard let index = snapshot.spaces.firstIndex(where: { $0.id == id }) else { return }
    sidebar?.showSpace(at: index)
  }

  func showChange(_ result: Result<WorkspaceAdapter.Change, Error>) {
    switch result {
    case .success(let change): show(change.snapshot)
    case .failure(let error): report(error)
    }
  }

  func close(_ id: String) {
    // A row's ✕/− showed its action; the rowwise buttons pass it through this default.
    adapter?.close(id: id, archive: false)
  }

  // U25d: Close Pane in a segment menu closes that pane's tab by the row rule: a Today pane
  // archives, a pin unloads and keeps its place (R1/D2). The split's own row still closes the
  // whole split through ⌘W.
  func closePane(_ id: String) {
    guard let space = snapshot.spaces.first(where: { $0.id == snapshot.shownSpaceId }),
          let row = (space.today + space.pinned + space.favorites).first(where: { $0.id == id }) else { return }
    adapter?.close(id: id, archive: rowCloseArchives(row, in: space))
  }

  // D6: one core batch (live_clear_today) with a Close in flight for every mapped live row,
  // so the engine's replies are accepted; the pages it names are closed beside it.
  func clearToday() {
    if CommandLine.arguments.contains("--ararat-screen=today") {
      FileHandle.standardError.write(Data("ararat-trace: today clear=action space=\(snapshot.shownSpaceId ?? "nil") adapter=\(adapter != nil)\n".utf8))
    }
    guard let spaceID = snapshot.shownSpaceId else { return }
    adapter?.clearToday(spaceID: spaceID) { [weak self] result in
      guard let self, let result else { return }
      self.show(result.snapshot)
      guard result.hasItems, let batch = result.batch else { return }
      self.clearUndo.offer { [weak self] in
        guard let self else { return }
        self.container?.dismissTabsCleared()
        self.adapter?.undoClearToday(batch) { [weak self] snapshot in
          guard let self, let snapshot else { return }
          self.show(snapshot)
          if let row = clearUndoSelection(snapshot), let url = row.url {
            self.adapter?.select(id: row.id, url: url)
          }
        }
      }
      self.container?.showTabsCleared { [weak self] in self?.clearUndo.run() }
    }
  }

  // R7: the unread dot is app state. A loaded tab the window is not showing gets one when its
  // title changes; showing it clears the dot; an id that leaves the strip is forgotten with
  // its title. Nothing here is stored or synced.
  func recordUnread(_ transaction: LiveTransaction) {
    guard let strip = transaction.strips.first(where: { $0.window == windowID }) else { return }
    unread.apply(strip: strip)
    sidebar?.unreadItems = unread.unread
  }

  // The sidebar's per-window row state: the live strip's crashed tabs on every snapshot, its
  // unread ids, and the settings row switch seeded once (the section's chevron rides in the
  // space snapshot).
  func refreshSidebarRowState(_ snapshot: WorkspaceSnapshot) {
    guard let sidebar else { return }
    // The seed and the first transaction, as U26b traced theirs: a check with no native tab
    // and an empty row set is told apart from a check whose seed never landed.
    if sidebarChecksActive, !sidebarSeedTraced, let store = adapter?.session.store {
      sidebarSeedTraced = true
      let seed = adapter?.session.queue.sync { store.snapshot(windowId: windowID) }
      let rows = seed?.spaces.flatMap { $0.today + $0.pinned + $0.favorites }.map(\.id) ?? []
      let profiles = seed?.spaces.map(\.profileName) ?? []
      FileHandle.standardError.write(Data("ararat-trace: sidebar-seed db=\(quitPath ?? "") shown=\(seed?.shownSpaceId ?? "") profiles=\(profiles) rows=\(rows)\n".utf8))
    }
    sidebar.crashedItems = Set(adapter?.crashedItems ?? [])
    sidebar.rowStates = adapter?.rowStates ?? [:]
    sidebar.onMute = { [weak self] id, muted in self?.adapter?.setMuted(muted, item: id) }
    sidebar.unreadItems = unread.unread
    // D4: the settings record lives in the regular workspace. A private window's own workspace
    // always holds the built-in values, so it reads the regular one (U27d review 1 M2).
    guard let settingsSource = settingsSource(), seededNewTabRow != snapshot.shownSpaceId else { return }
    seededNewTabRow = snapshot.shownSpaceId
    settingsSource.newTabRowShown { [weak self] result in
      guard case .success(let shown) = result else { return }
      self?.sidebar?.newTabRowShown = shown
    }
    settingsSource.tooltipsShown { [weak self] result in
      guard case .success(let shown) = result else { return }
      self?.sidebar?.tooltipsShown = shown
      self?.container?.header.tooltipsShown = shown
    }
    settingsSource.spaceScrollDirection { [weak self] result in
      guard case .success(let direction) = result else { return }
      self?.sidebar?.spaceScrollDirection = direction
    }
    // U27k: the theme is app-wide, so a value synced from another device applies here too.
    settingsSource.theme { result in
      guard case .success(let theme) = result else { return }
      NSApp.appearance = theme.appearance
    }
  }

  /// The adapter a window reads the shared settings record from (U27d review 1 M2): a private
  /// window's own workspace starts from the built-in values, so it reads the regular workspace's
  /// record instead, where the settings window writes.
  func settingsSource() -> WorkspaceAdapter? {
    isPrivateWindow ? (root?.workspace ?? workspace) : workspace
  }

  // The command-bar check drives ⌃Tab through a posted key event, so a run that loses the
  // switcher needs the path named: this is silent unless that check is running.
  func commandBarTrace(_ text: @autoclosure () -> String) {
    guard CommandLine.arguments.contains(where: { $0 == "--ararat-check=commandbar" || $0 == "--ararat-screen=commandbar" }) else { return }
    FileHandle.standardError.write(Data("ararat-trace: commandbar \(text())\n".utf8))
  }

  func performWorkspaceCommand(_ command: String) {
    guard host?.isClosing() != true, host?.isClosingAll() != true else { return }
    // A private workspace is one space with Today only: pins, folders, duplicates, space
    // switching and moves are not its operations (the core would refuse them).
    if isPrivateWindow {
      guard privateWorkspaceCommands.contains(command) else { return }
    }
    if (browserCheckMode == "split-focus" || browserCheckMode == "screen-split-focus") && (command == "focus_next_pane" || command == "focus_previous_pane") {
      FileHandle.standardError.write(Data("ararat-trace: split-focus command=\(command) selected=\(snapshot.selectedId ?? "nil") active=\(host?.activeItemId() ?? "nil") count_before=\(splitFocusDispatches[command, default: 0])\n".utf8))
    }
    let shown = snapshot.spaces.first { $0.id == snapshot.shownSpaceId }
    let rows = shown.map { $0.today + $0.pinned + $0.favorites } ?? []
    let selectedIsVisible = snapshot.selectedId.map { id in rows.contains { $0.id == id } } ?? false
    switch command {
    case "cycle_tabs_next": cycleTabs(backwards: false)
    case "cycle_tabs_previous": cycleTabs(backwards: true)
    case "focus_next_pane": splitFocusDispatches[command, default: 0] += 1; adapter?.focusPane(backwards: false)
    case "focus_previous_pane": splitFocusDispatches[command, default: 0] += 1; adapter?.focusPane(backwards: true)
    case "force_reload": host?.forceReload()
    case "clear_cache_site", "clear_cookies_site": _ = host?.runCommand(command)
    case "settings": openSettings()
    case "import_from_arc": openOnboarding()
    case "quit": NSApp.terminate(nil)
    case "new_tab": openCommandBar(.newTab)
    case "edit_url": openCommandBar(.editURL)
    case "copy_link": sidebar?.copySelectedLinkForCommand()
    case "search": openCommandBar(.search)
    case "close_tab": if selectedIsVisible { adapter?.closeSelected() }
    case "pin_tab": if selectedIsVisible { sidebar?.pinSelectedTab(nil) }
    case "duplicate", "new_folder", "rename", "delete_folder": sidebar?.organize(command: command)
    case "toggle_sidebar": container?.toggleSidebar()
    case "toggle_library": sidebar?.toggleLibrary(nil)
    case "reset_sidebar_width": container?.resizeHandle.resetWidth()
    default:
      if command.hasPrefix("move_to_space_") { sidebar?.organize(command: command); return }
      if command.hasPrefix("show_space_"), let index = Int(command.dropFirst("show_space_".count)), snapshot.spaces.indices.contains(index - 1) {
        sidebar?.showSpace(at: index - 1)
      }
    }
  }

  /// U27h: opens a page-only Little Window on `url` (about:blank from the menu command) in
  /// `profile`, at the remembered frame. The engine creates the popup Browser and our
  /// create_host callback builds the bar. `replacing` is closed by that callback once the new
  /// window exists (a profile switch must not lose the page when the open is refused).
  func openLittleWindow(url: String? = nil, profile: String? = nil, frame: NSRect? = nil,
                        replacing: LittleWindowController? = nil) {
    guard !isPrivateWindow, let host, hasUsableHost, let adapter = workspace else { return }
    let name = profile ?? host.profileDirectory()
    func create(_ rect: NSRect) {
      attemptLittleWindow(url: url, profile: name, frame: LittleWindowController.clampedFrame(rect),
                          replacing: replacing, deadline: .now() + 10)
    }
    if let frame { create(frame); return }
    // D8: the remembered frame is used only while this device remembers it; off opens at the
    // default size and place.
    adapter.littleWindowDevice { [weak self] result in
      guard let self else { return }
      let remember = (try? result.get())?.rememberFrame ?? true
      guard remember else { create(LittleWindowController.defaultFrame()); return }
      self.workspace?.littleWindowFrame { [weak self] result in
        guard let self else { return }
        let saved = (try? result.get()) ?? nil
        let rect = saved.map { NSRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
          ?? LittleWindowController.defaultFrame()
        create(rect)
      }
    }
  }

  /// One attempt, used for the first try and every retry. The engine's create_host callback
  /// consumes `Launcher.pendingLittleWindow`; a request still set afterwards means no popup was
  /// made, so it is cleared (never left for an unrelated `window.open` to adopt) and retried
  /// until the deadline. The origin window's own profile is never touched: the engine loads the
  /// profile's Browser into the host without switching what the window shows.
  private func attemptLittleWindow(url: String?, profile: String, frame: NSRect,
                                   replacing: LittleWindowController?, deadline: DispatchTime) {
    guard let host, hasUsableHost else {
      Launcher.pendingLittleWindow = nil
      return
    }
    Launcher.pendingLittleWindow = (self, frame, url, profile, replacing)
    let accepted = host.openLittleWindow(url ?? "about:blank", profile: profile, frame: frame)
    if accepted, Launcher.pendingLittleWindow == nil { return }
    Launcher.pendingLittleWindow = nil
    guard DispatchTime.now() < deadline else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
      self?.attemptLittleWindow(url: url, profile: profile, frame: frame,
                                replacing: replacing, deadline: deadline)
    }
  }

  @objc func newLittleWindow(_ sender: Any?) {
    // The menu's target is the first window; the Little Window belongs to the key window, as
    // the other workspace commands do. With Ararat in the background — the global shortcut's
    // usual case — no window is key, and the root's own window may have closed: fall back to a
    // window that is still usable rather than the root, whose open would do nothing (M1).
    let owner = root ?? self
    let windows = [owner] + owner.children
    let key = windows.first { $0.host?.window().isKeyWindow == true && !$0.isPrivateWindow }
    Runtime.commandWindow(key: key, regular: windows.filter { $0.hasUsableHost && !$0.isPrivateWindow }, root: owner)
      .openLittleWindow()
  }

  /// U27i M1: the window a menu command or the global shortcut acts on. The key window answers
  /// when there is one; otherwise the first still-usable regular window; the root is the last
  /// resort. With no browser window at all nothing can be opened (U27h's limit).
  static func commandWindow(key: Runtime?, regular: [Runtime], root: Runtime) -> Runtime {
    key ?? regular.first ?? root
  }

  func openSettings(spaceID: String? = nil) {
    // Design: Settings opened from a private window is the normal Settings window acting on
    // the regular profile; nothing is written through the private workspace.
    if isPrivateWindow, let root, root !== self {
      root.openSettings(spaceID: nil)
      return
    }
    guard let workspace, let keyBindings, let airTraffic else { return }
    let owner = root ?? self
    let publish: (WorkspaceSnapshot) -> Void = { [weak self] in self?.showWorkspaceEdit($0) }
    let resetWidth: () -> Void = { [weak self] in self?.container?.resizeHandle.resetWidth() }
    let preview: (String, Look?, Bool) -> Void = { [weak self] id, look, active in self?.sidebar?.previewLook(spaceID: id, look: look, active: active) }
    if owner.settings == nil {
      owner.settings = SettingsWindowController(model: SettingsModel(snapshot: snapshot, adapter: workspace, publish: publish,
        resetWidth: resetWidth, preview: preview, keyBindings: keyBindings, airTraffic: airTraffic))
    } else {
      owner.settings?.retarget(snapshot: snapshot, adapter: workspace, publish: publish, resetWidth: resetWidth,
                               preview: preview, keyBindings: keyBindings, airTraffic: airTraffic)
    }
    owner.settingsOwner = self
    // U27i: the Little Window pane's shortcut records into the app-wide registration.
    owner.settings?.setLittleWindowHotKeyCenter(LittleWindowGlobalShortcut.center)
    // U27w: the Websites pane reads and writes Chromium's site settings through the app's
    // engine bridge, and a written default record reaches every regular profile at once.
    owner.settings?.setSiteSettings(host: EngineSiteSettingsHost.shared) { defaults in
      EngineSiteSettingsHost.apply(defaults)
    }
    // U27p: the Privacy pane writes the record through the core and pushes it into every regular
    // profile; Clear browsing data runs for the profile the sheet names.
    owner.settings?.setPrivacySettings(host: EnginePrivacySettingsHost.shared)
    // U27x: the Extensions pane reads and writes one profile's extensions through the same engine
    // bridge. Manage Extension opens the profile's own chrome://extensions page, showing that
    // profile's space first when Settings is on another one (the engine opens a tab in the shown
    // space's profile only).
    owner.settings?.setExtensionSettings(host: EngineExtensionSettingsHost.shared) { [weak owner] profile, id in
      guard let owner, let adapter = owner.adapter, let workspace = owner.workspace,
            let space = owner.snapshot.spaces.first(where: { $0.profileName == profile }) else { return }
      let url = "chrome://extensions/?id=" + id
      let open = { adapter.openCommandURL(url, expectedSpace: space.id, profile: space.profileName) }
      if owner.snapshot.shownSpaceId == space.id {
        open()
      } else {
        workspace.showSpace(id: space.id) { _ in open() }
      }
    }
    // Its two switches reach a Little Window already open, as the Appearance switches reach the
    // sidebars.
    owner.settings?.setLittleWindowHandlers { [weak owner] openIn, remember, closeAfter in
      guard let owner else { return }
      for window in owner.windowTree {
        for little in window.littleWindows {
          little.apply(openIn: openIn, rememberFrame: remember, closeAfter: closeAfter)
        }
      }
    }
    // U27c: a direction the pane writes reaches the sidebars of every window that shows this
    // workspace, so the next sideways scroll pages the other way without a relaunch.
    owner.settings?.setSpaceScrollHandler { [weak owner] direction in
      guard let owner else { return }
      for window in owner.windowTree { window.sidebar?.spaceScrollDirection = direction }
    }
    // U27d: the Appearance pane's switches reach every window of this workspace at once. The New
    // Tab row closes the sidebar's rows up; the Tooltips switch silences the sidebar's and the
    // header's tooltips without touching menus or accessibility help.
    owner.settings?.setAppearanceHandlers(newTabRow: { [weak owner] shown in
      guard let owner else { return }
      for window in owner.windowTree { window.sidebar?.newTabRowShown = shown }
    }, tooltips: { [weak owner] shown in
      guard let owner else { return }
      for window in owner.windowTree {
        window.sidebar?.tooltipsShown = shown
        window.container?.header.tooltipsShown = shown
      }
    }, theme: { theme in
      // U27k D5: one app-wide appearance, so every window, the settings window, popovers, menus
      // and the command bar change together; System hands each window back to the Mac.
      NSApp.appearance = theme.appearance
    })
    if CommandLine.arguments.contains(where: { $0.hasPrefix("--ararat-check=") && $0 != "--ararat-check=dock" }) {
      owner.settings?.prepare(shownSpaceID: spaceID ?? snapshot.shownSpaceId)
    } else {
      owner.settings?.open(shownSpaceID: spaceID ?? snapshot.shownSpaceId)
    }
  }

  /// U27b: the ids the Ararat Commands menu carries; CoreMenuTests checks every one is a table command.
  static let coreMenuCommandIDs = ["cycle_tabs_next", "cycle_tabs_previous", "focus_next_pane", "focus_previous_pane", "force_reload", "clear_cache_site", "clear_cookies_site", "pin_tab", "copy_link", "duplicate", "new_folder", "rename", "delete_folder", "toggle_sidebar", "toggle_library", "reset_sidebar_width"] + (1...9).flatMap { ["show_space_\($0)", "move_to_space_\($0)"] }

  func installCoreMenu() {
    guard !coreMenuInstalled, let menu = NSApp.mainMenu else { return }
    coreMenuInstalled = true
    if let edit = menu.item(withTitle: "Edit")?.submenu {
      // Why not ⌘Z: the page's editable first responder must keep its own undo.
      let undo = NSMenuItem(title: "Undo Clear Tabs", action: #selector(undoClearTabs(_:)), keyEquivalent: "")
      undo.target = self
      edit.insertItem(undo, at: min(1, edit.items.count))
    }
    let ids = Self.coreMenuCommandIDs
    let bindings = defaultKeyBindings().filter { ids.contains($0.command) }
    if let settingsItem = menu.items.first?.submenu?.items.first(where: { $0.action == NSSelectorFromString("showPreferences:") }),
       let binding = defaultKeyBindings().first(where: { $0.command == "settings" }) {
      settingsItem.target = self
      settingsItem.action = #selector(coreMenuCommand(_:))
      settingsItem.representedObject = "settings"
      KeyBindingsModel.setCoreMenuShortcut(binding.key, on: settingsItem)
    }
    displacedMenuItems = KeyBindingsModel.clearCollisions(bindings, in: menu)
    let core = NSMenu(title: "Ararat Commands")
    for binding in bindings {
      let item = core.addItem(withTitle: binding.title, action: #selector(coreMenuCommand(_:)), keyEquivalent: binding.key?.key ?? "")
      item.target = self
      item.representedObject = binding.command
      item.identifier = NSUserInterfaceItemIdentifier(binding.command)
      KeyBindingsModel.setCoreMenuShortcut(binding.key, on: item)
    }
    let coreItem = menu.addItem(withTitle: "Ararat Commands", action: nil, keyEquivalent: "")
    coreItem.tag = 0x4152434d
    coreItem.submenu = core
    keyBindings?.register(core)
    // U27h: the Little Window's menu entry. Its own block so the other U27 branches' command
    // additions merge without touching it.
    if let file = menu.item(withTitle: "File")?.submenu {
      let little = NSMenuItem(title: "New Little Window", action: #selector(newLittleWindow(_:)), keyEquivalent: "")
      little.target = self
      little.identifier = NSUserInterfaceItemIdentifier("new_little_window")
      let index = file.items.firstIndex { $0.action == NSSelectorFromString("newIncognitoWindow:") }.map { $0 + 1 } ?? 0
      file.insertItem(little, at: index)
      // U27j O7: "Import from Arc…" is a command only. The importer does not read real files yet,
      // so a shipping build has no data source and the item is present only while a check runs
      // (hide, not disable: the site-controls rule). Its own block, like the Little Window's.
      if Runtime.onboardingEntryVisible {
        let onboarding = NSMenuItem(title: "Import from Arc…", action: #selector(importFromArc(_:)), keyEquivalent: "")
        onboarding.target = self
        onboarding.identifier = NSUserInterfaceItemIdentifier(OnboardingCommandStore.commandID)
        file.insertItem(onboarding, at: index + 1)
      }
    }
  }

  @objc func importFromArc(_ sender: Any?) { openOnboarding() }

  @objc func coreMenuCommand(_ item: NSMenuItem) {
    let owner = root ?? self
    guard let command = item.representedObject as? String else { return }
    commandBarTrace("core-menu command=\(command) key=\(NSApp.keyWindow?.windowNumber ?? -1) responder=\(NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "-")")
    if ([owner] + owner.children).contains(where: { runtime in
      runtime.popups.contains(where: { $0.host?.window().isKeyWindow == true })
    }),
       let original = owner.displacedMenuItems[command], let action = original.action {
      NSApp.sendAction(action, to: original.target, from: original)
      return
    }
    guard let target = ([owner] + owner.children).first(where: {
      $0.host?.window().isKeyWindow == true || $0.commandPresenter?.panel.isKeyWindow == true
    }) ?? (owner.settings?.window?.isKeyWindow == true ? owner.settingsOwner : nil)
       ?? (command == "settings" ? ([owner] + owner.children).first(where: { $0.popups.contains { $0.host?.window().isKeyWindow == true } }) : nil) else { return }
    if let event = NSApp.currentEvent, let window = NSApp.keyWindow,
       WorkspaceCommands.yieldsToOwnField(target.keyBindings?.bindings ?? defaultKeyBindings(), event: event, in: window) {
      window.firstResponder?.keyDown(with: event)
      return
    }
    target.performWorkspaceCommand(command)
  }

  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    let owner = root ?? self
    let target = ([owner] + owner.children).first { $0.host?.window().isKeyWindow == true }
    if let target, target.isPrivateWindow {
      // The core rejects import into a private workspace; a private workspace has no pins,
      // folders, duplicates, other spaces or moves either.
      if item.title.range(of: "import", options: .caseInsensitive) != nil { return false }
      if item.action == #selector(coreMenuCommand(_:)), let command = item.representedObject as? String,
         !privateWorkspaceCommands.contains(command) {
        return false
      }
    }
    if item.action == #selector(undoClearTabs(_:)) {
      return Self.clearUndoMenuEnabled(target)
    }
    guard item.action == #selector(coreMenuCommand(_:)), let command = item.representedObject as? String else { return true }
    if command == "focus_next_pane" || command == "focus_previous_pane" { return target?.adapter?.canFocusPane == true }
    // U27b: the two site commands match the header's … menu, which disables them without an
    // http(s) page; the menu item is the recorded key's own gate.
    if command == "clear_cache_site" || command == "clear_cookies_site" { return target?.host?.currentSiteDomain() != nil }
    guard command == "delete_folder" else { return true }
    return target?.sidebar?.canDeleteOrganizeFolder == true
  }

  static func clearUndoMenuEnabled(_ target: Runtime?) -> Bool { target?.clearUndo.available == true }

  @objc func undoClearTabs(_ item: NSMenuItem) {
    let owner = root ?? self
    ([owner] + owner.children).first { $0.host?.window().isKeyWindow == true }?.clearUndo.run()
  }

  func cycleTabs(backwards: Bool, holdForCheck: Bool = false) {
    if let switcher = tabSwitcher, switcher.isOpen { switcher.advance(backwards: backwards); return }
    guard hasUsableHost, let host, let workspace else { return }
    commandBarTrace("cycle-tabs backwards=\(backwards) hold=\(holdForCheck) key=\(NSApp.keyWindow?.windowNumber ?? -1) responder=\(NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "-") current=\(NSApp.currentEvent.map { "\($0.type.rawValue)/\($0.modifierFlags.rawValue)" } ?? "nil")")
    let space = snapshot.shownSpaceId
    let switcher = TabSwitcher(parent: host.window(), backwards: backwards) { [weak host] id in
      (host?.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == id })?.favicon
    }
    tabSwitcher = switcher
    commandBarTrace("cycle-tabs created")
    switcher.onClose = { [weak self, weak switcher] in
      if self?.tabSwitcher === switcher { self?.tabSwitcher = nil }
      self?.commandBarTrace("cycle-tabs switcher closed")
    }
    switcher.onSelect = { [weak self] row in
      guard let self, self.snapshot.shownSpaceId == space, case .tab(let id, _) = row.target, let url = row.url else { return }
      self.adapter?.select(id: id, url: url)
    }
    workspace.recentTabs { [weak self, weak switcher] result in
      guard let self, let switcher, self.tabSwitcher === switcher, self.snapshot.shownSpaceId == space else {
        self?.commandBarTrace("cycle-tabs rows skipped same=\(self?.tabSwitcher === switcher) space=\(self?.snapshot.shownSpaceId ?? "-") captured=\(space ?? "-")")
        switcher?.cancel()
        return
      }
      let rows = (try? result.get()) ?? []
      self.commandBarTrace("cycle-tabs rows=\(rows.count)")
      switcher.load(rows)
    }
    if !holdForCheck && NSApp.currentEvent?.modifierFlags.contains(.control) != true {
      commandBarTrace("cycle-tabs committing: current event lacks control")
      switcher.commit()
    }
  }

  // MARK: U26e pass 4: site controls

  func refreshSiteState() {
    guard hasUsableHost else { return }
    let state = adapter?.siteState()
    siteState = state
    sidebar?.siteControlsBlocked = state?.blocked ?? false
    // S1: a navigation or tab switch while the region overlay is up cancels the selection.
    // A nil snapshot (last tab closed) counts as gone too.
    if let overlay = siteOverlay, state?.document != siteOverlayDocument {
      overlay.cancel()
    }
    let fingerprint = Self.siteFingerprint(state)
    if fingerprint != lastSiteFingerprint {
      lastSiteFingerprint = fingerprint
      if let state, let controls = siteControls, controls.isShown { controls.reload(model: state) }
    }
  }

  static func siteFingerprint(_ state: SiteState?) -> String {
    guard let state else { return "" }
    let rows = state.permissions.map { row in
      "\(row.type)=\(row.setting?.title ?? "-")/\(row.mutable ? 1 : 0)/\(row.allowed.count)"
    }
    return "\(state.document)|\(state.security)|\(state.blocked)|\(state.isInternal)|\(rows.joined(separator: ","))"
  }

  func showSiteControls(_ windowRect: NSRect, in container: SidebarContainerView) {
    guard hasUsableHost else { return }
    refreshSiteState()
    guard let state = siteState else { return }
    let anchor = container.convert(windowRect, from: nil)
    let controls: SiteControlsPopover
    if let existing = siteControls {
      controls = existing
    } else {
      controls = SiteControlsPopover()
      controls.onCaptureRegion = { [weak self] model in self?.beginRegionCapture(model) }
      controls.onCaptureFullPage = { [weak self] model in self?.captureFullPage(model) }
      controls.onPermissionChange = { [weak self] _, request in self?.changePermission(request) ?? false }
      controls.onAllSiteSettings = { [weak self] model in self?.openAllSiteSettings(model) }
      controls.onClose = { [weak self] in self?.adapter?.closeSiteControls() }
      controls.hostWindow = { [weak host] in host?.window() }
      siteControls = controls
    }
    if controls.isShown {
      controls.close()
      return
    }
    controls.present(relativeTo: anchor, of: container, model: state)
  }
  @discardableResult
  func changePermission(_ request: [String: Any]) -> Bool {
    let changed = adapter?.changeSitePermission(request) ?? false
    refreshSiteState()
    return changed
  }

  /// U27w W4: "All Site Settings…" opens Settings › Websites on this site's page in the page's
  /// own profile; a site with no exception opens the list. The popover's own callback closes the
  /// popover before this runs.
  func openAllSiteSettings(_ model: SiteState) {
    openSettings()
    let owner = root ?? self
    let shown = owner.snapshot.shownSpaceId
    let profile = host?.profileDirectory() ?? ""
    owner.settings?.openSite(origin: model.origin, profile: profile, shownSpaceID: shown)
  }

  func beginRegionCapture(_ model: SiteState) {
    guard siteOverlay == nil, let container, hasUsableHost else { return }
    // The overlay covers the focused pane only: in a split the page view is offset inside the
    // page card, and a selection outside it would be clipped by the engine anyway.
    let cardBounds = container.pageCard.bounds
    var frame = cardBounds
    if let native = focusedPageView(), native.window === container.window {
      let paneFrame = container.pageCard.convert(native.bounds, from: native)
      if !paneFrame.isEmpty { frame = paneFrame.intersection(cardBounds) }
    }
    let overlay = SiteCaptureOverlay(frame: frame)
    overlay.autoresizingMask = []
    overlay.onFinish = { [weak self, weak overlay] rect in
      guard let self, let overlay else { return }
      // Convert while the view is still attached: a detached view has no window, so its
      // convert(_:to: nil) would return points in the view's own root space.
      let inWindow: NSRect? = rect.map { overlay.convert($0, to: nil) }
      overlay.removeFromSuperview()
      self.siteOverlay = nil
      self.siteOverlayDocument = ""
      guard let inWindow, rect != nil, let native = self.focusedPageView() else { return }
      // The engine takes the page view's own points with the origin at its top left.
      let local = native.convert(inWindow, from: nil)
      let flipped = NSRect(x: local.minX, y: native.bounds.height - local.maxY,
                           width: local.width, height: local.height)
      self.adapter?.captureRegion(flipped, document: model.document) { [weak self] png, error in
        self?.finishCapture(png, error: error, mode: "region")
      }
    }
    // The engine removes non-page children of pageCard while synchronizing tabs.
    container.addSubview(overlay)
    overlay.frame = container.convert(frame, from: container.pageCard)
    siteOverlay = overlay
    siteOverlayDocument = model.document
  }

  func focusedPageView() -> NSView? {
    guard let host, let active = host.activeItemId(),
          let tab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == active }) else { return nil }
    return tab.view
  }

  func captureFullPage(_ model: SiteState) {
    guard hasUsableHost else { return }
    adapter?.captureFullPage(document: model.document) { [weak self] png, error in
      self?.finishCapture(png, error: error, mode: "full")
    }
  }

  func finishCapture(_ png: Data?, error: String?, mode: String) {
    guard let png, let image = NSImage(data: png) else {
      captureError = error ?? "failed"
      // S3: every named failure is visible; only a user cancel is silent.
      let text = error == "tooLarge" ? "The page is too large to capture" : "The page couldn't be captured"
      container?.showToast(text)
      FileHandle.standardError.write(Data("ararat-trace: site-capture mode=\(mode) error=\(error ?? "failed")\n".utf8))
      return
    }
    captureError = ""
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setData(png, forType: .png)
    container?.showToast("Screenshot copied")
    FileHandle.standardError.write(Data("ararat-trace: site-capture mode=\(mode) ok=1 size=\(Int(image.size.width))x\(Int(image.size.height)) pasteboard=\(pasteboard.data(forType: .png)?.count ?? 0)\n".utf8))
  }

  // MARK: U26e pass 5: extension actions

  func refreshExtensionActions() {
    guard hasUsableHost else { return }
    extensionItems = adapter?.extensionActions(iconSize: 16) ?? []
    sidebar?.extensionActions = extensionItems
  }

  func invokeExtensionAction(_ item: ExtensionActionItem) {
    guard hasUsableHost else { return }
    adapter?.runExtensionAction(item.id)
  }

  func extensionMenu(_ item: ExtensionActionItem) -> NSMenu {
    let menu = NSMenu()
    // AppKit would re-enable a disabled item through its automatic validation; the engine's
    // named refused results already tell us which items cannot act.
    menu.autoenablesItems = false
    let pin = NSMenuItem(title: item.pinned ? "Unpin" : "Pin",
                         action: #selector(menuPinExtension(_:)), keyEquivalent: "")
    pin.target = self
    pin.representedObject = item.id
    pin.isEnabled = item.pinMutable
    menu.addItem(pin)
    menu.addItem(.separator())
    let manage = NSMenuItem(title: "Manage Extension",
                            action: #selector(menuManageExtension(_:)), keyEquivalent: "")
    manage.target = self
    manage.representedObject = item.id
    manage.isEnabled = adapter?.extensionManagementURL(item.id) != nil
    menu.addItem(manage)
    let remove = NSMenuItem(title: "Remove…",
                            action: #selector(menuRemoveExtension(_:)), keyEquivalent: "")
    remove.target = self
    remove.representedObject = item.id
    remove.isEnabled = item.removable
    menu.addItem(remove)
    return menu
  }

  @objc func menuPinExtension(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? String,
          let item = extensionItems.first(where: { $0.id == id }) else { return }
    pinExtension(id, pinned: !item.pinned)
  }

  @objc func menuManageExtension(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? String else { return }
    manageExtension(id)
  }

  @objc func menuRemoveExtension(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? String else { return }
    removeExtension(id)
  }

  func pinExtension(_ identifier: String, pinned: Bool) {
    let before = extensionItems.first(where: { $0.id == identifier })?.pinned
    let result = adapter?.setExtensionPinned(identifier, pinned: pinned) ?? "unknown"
    refreshExtensionActions()
    let after = extensionItems.first(where: { $0.id == identifier })?.pinned
    FileHandle.standardError.write(Data("ararat-trace: ext-pin id=\(identifier) pinned=\(pinned) result=\(result) before=\(before.map { "\($0)" } ?? "nil") after=\(after.map { "\($0)" } ?? "nil")\n".utf8))
  }

  func manageExtension(_ identifier: String) {
    guard hasUsableHost, let host, let url = adapter?.extensionManagementURL(identifier) else { return }
    // Pass 3 review S1: the shown space's existing new-tab command path, captured at invocation.
    adapter?.openCommandURL(url, expectedSpace: snapshot.shownSpaceId, profile: host.profileDirectory())
  }

  func removeExtension(_ identifier: String) {
    guard hasUsableHost else { return }
    adapter?.removeExtension(identifier) { [weak self] result, detail in
      FileHandle.standardError.write(Data("ararat-trace: ext-remove id=\(identifier) result=\(result) detail=\(detail)\n".utf8))
      self?.extensionActionsCheck?.removeResult = result
      self?.refreshExtensionActions()
    }
  }

  func openCommandBar(_ requested: CommandBarMode) {
    guard hasUsableHost, let host, let adapter, let workspace else { return }
    commandPresenter?.close()
    let target = adapter.captureNavigationTarget()
    let missingTarget = target == nil && host.hasActiveTab()
    if requested == .editURL && missingTarget { return }
    let capturedProfile = host.profileDirectory()
    let capturedSpace = snapshot.shownSpaceId
    let capturedItem = snapshot.selectedId
    let spec = CommandBarController.openSpec(mode: requested, selectedTabURL: target?["url"] as? String)
    let hidden = CommandLine.arguments.contains { $0.hasPrefix("--ararat-check=") }
    let presenter = CommandBarPresenter(parent: host.window(), visible: !hidden,
      bindings: keyBindings?.bindings ?? [], highlight: .selectedContentBackgroundColor)
    commandPresenter = presenter
    presenter.onClose = { [weak self, weak presenter] in
      if self?.commandPresenter === presenter { self?.commandPresenter = nil }
    }
    presenter.onCommit = { [weak self, weak host, weak adapter] row, mode, forceNew in
      guard let self, let host, let adapter, self.hasUsableHost,
            let current = self.host, (current as AnyObject) === (host as AnyObject),
            host.profileDirectory() == capturedProfile, self.snapshot.shownSpaceId == capturedSpace else { return }
      guard let row else { return }
      switch row.target {
      case .openUrl(let url), .search(let url), .history(let url):
        if let external = URL(string: url), ["mailto", "tel"].contains(external.scheme?.lowercased() ?? "") {
          if !NSWorkspace.shared.open(external) {
            self.report(NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnsupportedSchemeError,
              userInfo: [NSLocalizedDescriptionKey: "No application could open \(url)"]))
          }
          return
        }
        if mode == .search && !forceNew && missingTarget { return }
        if mode != .newTab && !forceNew, let target { _ = adapter.navigateCommandURL(url, target: target) }
        else { adapter.openCommandURL(url, expectedSpace: capturedSpace, profile: capturedProfile) }
      case .tab(let id, let space):
        if let space {
          self.selectionGeneration += 1
          workspace.cancelPendingSpaceSwitches()
          let generation = self.selectionGeneration
          workspace.showSpaceSelectingTab(id: space, item: id) { [weak self] result in
            guard let self, self.selectionGeneration == generation else { return }
            if case .failure(let error) = result { self.report(error); return }
            workspace.snapshot { [weak self] latest in
              guard let self, self.selectionGeneration == generation, case .success(let current) = latest,
                    current.shownSpaceId == space, current.selectedId == id else { return }
              adapter.invalidateSelection()
              self.showAndSelect(.success(current), expectedSpace: space, selectedItem: id)
              if let index = current.spaces.firstIndex(where: { $0.id == space }) {
                self.sidebar?.showSpaceWithoutNotification(at: index)
              }
            }
          }
        } else if let url = row.url { adapter.select(id: id, url: url) }
      case .space(let id):
        self.showSuggestedSpace(id)
      case .folder(let id, let space):
        self.switchWorkspaceSpace(space) { [weak self] in
          workspace.openFolder(id: id) { [weak self] in self?.showResult($0) }
        }
      case .command(let id):
        if id == "pin_tab" || id == "close_tab" {
          guard self.snapshot.selectedId == capturedItem, let target, adapter.isCurrentNavigationTarget(target) else { return }
          if id == "close_tab", let item = capturedItem, let live = target["live"] as? String {
            adapter.close(id: item, expectedLive: live)
            return
          }
          if id == "pin_tab", let live = target["live"] as? String {
            self.sidebar?.pinSelectedTab { [weak self] item, container, index, openFolder, completion in
              workspace.moveIfLive(id: item, container: container, index: index, openFolder: openFolder, expectedLive: live) { result in
                switch result {
                case .success(let snapshot): completion(snapshot); if let snapshot { self?.show(snapshot) }
                case .failure(let error): completion(nil); self?.report(error)
                }
              }
            }
            return
          }
        }
        self.performWorkspaceCommand(id)
      case .moveToSpace(let id):
        guard let item = capturedItem, self.snapshot.selectedId == item, let target, adapter.isCurrentNavigationTarget(target),
              let space = self.snapshot.spaces.first(where: { $0.id == id }) else { return }
        guard let live = target["live"] as? String else { return }
        workspace.moveIfLive(id: item, container: space.todayId, index: Int(space.todayCount), openFolder: false, expectedLive: live) { [weak self] result in
          switch result { case .success(let snapshot): if let snapshot { self?.show(snapshot) }; case .failure(let error): self?.report(error) }
        }
      case .moveToFolder(let id, let spaceID):
        guard let item = capturedItem, self.snapshot.selectedId == item, let target, adapter.isCurrentNavigationTarget(target),
              let space = self.snapshot.spaces.first(where: { $0.id == spaceID }) else { return }
        let index = space.pinned.filter { $0.parentId == id && $0.kind != .noTabs }.map { Int($0.siblingIndex) + 1 }.max() ?? 0
        guard let live = target["live"] as? String else { return }
        workspace.moveIfLive(id: item, container: id, index: index, openFolder: false, expectedLive: live) { [weak self] result in
          switch result { case .success(let snapshot): if let snapshot { self?.show(snapshot) }; case .failure(let error): self?.report(error) }
        }
      }
    }
    presenter.controller.privateWindow = host.isPrivateWindow()
    presenter.controller.onQuery = { [weak self, weak presenter, weak host] text, generation in
      guard let presenter, let host, !presenter.controller.privateWindow, presenter.controller.mode != .search else { return }
      self?.privateHistoryQueries += 1
      host.queryHistory(text) { [weak presenter, weak self] rows in
        let entries = rows.compactMap { row -> HistoryEntry? in
          guard let title = row["title"] as? String, let url = row["url"] as? String,
                let lastVisit = row["lastVisit"] as? NSNumber else { return nil }
          return HistoryEntry(title: title, url: url, lastVisit: lastVisit.uint64Value)
        }
        MainActor.assumeIsolated {
          guard let presenter, let self, self.host?.profileDirectory() == capturedProfile,
                presenter.controller.queryGeneration == generation else { return }
          presenter.controller.updateHistory(entries, for: text)
        }
      }
    }
    presenter.open(mode: spec.mode, prefill: spec.prefill)
    workspace.commandBarSession(privateWindow: presenter.controller.privateWindow) { [weak self, weak presenter] result in
      guard let self, let presenter, self.commandPresenter === presenter else { return }
      switch result {
      case .success(let session):
        let base = CommandBarSessionStore(session: session)
        // U27j O7: the "Import from Arc…" row rides only a check, the same gate as its menu item.
        presenter.applyStore(Runtime.onboardingEntryVisible ? OnboardingCommandStore(base: base) : base)
      case .failure(let error):
        self.report(error)
        presenter.close()
      }
    }
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

static func dispatchPopupCheck(mode: String, phase: Int, devtools: () -> Void, regular: () -> Void) {
  if mode == "popup", (6...10).contains(phase) { devtools() } else { regular() }
}

  /// U26e pass 5: the relaunch-pins driver's first run pins the fixture action through Chrome's
  /// per-profile prefs and commits them, then prints the ready line the driver waits for.
  func pinsSeedTick(_ host: any ARWindowHostAPI) {
    let id = "kmgaadhbnkendcanjninlfmfgehagggl"
    guard let item = extensionItems.first(where: { $0.id == id }) else { return }
    switch browserCheckPhase {
    case 0:
      if item.pinned {
        browserCheckPhase = 1
      } else {
        let result = adapter?.setExtensionPinned(id, pinned: true) ?? "unknown"
        FileHandle.standardError.write(Data("ararat-trace: relaunch-pins seed pin result=\(result)\n".utf8))
        browserCheckPhase = result == "done" ? 1 : 2
      }
    case 1:
      refreshExtensionActions()
      guard extensionItems.first(where: { $0.id == id })?.pinned == true else { return }
      browserCheckPhase = 2
      guard let symbol = dlsym(Launcher.handle, "AraratCheckCommitProfilePrefs") else {
        finishBrowserCheck(ok: false, values: ["error": "missing profile prefs commit API"]); return
      }
      typealias Commit = @convention(c) (UnsafeRawPointer, @escaping @convention(block) (Bool) -> Void) -> Void
      let commit = unsafeBitCast(symbol, to: Commit.self)
      let profile = host.profileDirectory() as NSString
      commit(Unmanaged.passUnretained(profile).toOpaque()) { done in
        MainActor.assumeIsolated {
          guard done else {
            self.finishBrowserCheck(ok: false, values: ["error": "profile unavailable for prefs commit"]); return
          }
          let ready: [String: Any] = ["ready": true, "pinned": id]
          if let data = try? JSONSerialization.data(withJSONObject: ready, options: [.sortedKeys]),
             let line = String(data: data, encoding: .utf8) { print(line); fflush(stdout) }
          self.finishBrowserCheck(ok: true, values: ["pinned": id, "profile": host.profileDirectory()])
        }
      }
    default:
      break
    }
  }

  func pinsVerifyTick(_ host: any ARWindowHostAPI, expected: Bool) {
    let id = "kmgaadhbnkendcanjninlfmfgehagggl"
    let isolationRun = CommandLine.arguments.contains("--ararat-relaunch-mode=pins-isolated")
    if isolationRun {
      pinsIsolationTick(host, id: id)
      return
    }
    let profile = host.profileDirectory()
    guard let item = extensionItems.first(where: { $0.id == id }) else {
      if browserCheckAttempts > 300 {
        finishBrowserCheck(ok: false, values: ["error": "extension fixture action missing", "profile": profile])
      }
      return
    }
    if browserCheckPhase == 0 { browserCheckPhase = 1 }
    guard item.pinned == expected else {
      if browserCheckAttempts > 300 {
        finishBrowserCheck(ok: false, values: ["pinned": item.pinned, "expected": expected, "profile": profile])
      }
      return
    }
    finishBrowserCheck(ok: true, values: ["pinned": item.pinned, "expected": expected, "profile": profile,
                                          "profile_isolation_verified": false])
  }

  /// N2: run 3 must really test Profile 1. `--profile-directory` alone does not move the host
  /// (the shown space picks the profile), so this opens a second window through the same
  /// session and loads Profile 1 into it, then compares the two profiles' pin state. A window
  /// that cannot load Profile 1 fails with the named `profile_isolation` condition.
  func pinsIsolationTick(_ host: any ARWindowHostAPI, id: String) {
    let startupProfile = host.profileDirectory()
    if browserCheckAttempts % 20 == 0 {
      let childProfile = pinsIsolationChild?.host?.profileDirectory() ?? "nil"
      let childPinned = pinsIsolationChild?.extensionItems.first(where: { $0.id == id }).map { "\($0.pinned)" } ?? "nil"
      let defaultPinned = extensionItems.first(where: { $0.id == id }).map { "\($0.pinned)" } ?? "nil"
      FileHandle.standardError.write(Data("ararat-trace: relaunch-pins isolation phase=\(browserCheckPhase) attempts=\(browserCheckAttempts) profile=\(startupProfile) child=\(pinsIsolationChild != nil) child_profile=\(childProfile) child_pinned=\(childPinned) default_pinned=\(defaultPinned)\n".utf8))
    }
    switch browserCheckPhase {
    case 0:
      guard let startupItem = extensionItems.first(where: { $0.id == id }) else {
        if browserCheckAttempts > 300 {
          finishBrowserCheck(ok: false, values: ["profile_isolation": false,
                                                 "error": "extension fixture action missing in the verify window",
                                                 "profile": startupProfile])
        }
        return
      }
      if startupProfile == "Profile 1" {
        // Chromium honoured --profile-directory; this window is the isolated one.
        let passed = startupItem.pinned == false
        finishBrowserCheck(ok: passed, values: ["profile_isolation": passed,
                                                "profile_isolation_verified": passed,
                                                "profile": startupProfile,
                                                "profile1_pinned": startupItem.pinned])
        return
      }
      guard startupItem.pinned else {
        if browserCheckAttempts > 300 {
          finishBrowserCheck(ok: false, values: ["profile_isolation": false,
                                                 "error": "Default profile lost its pin before the Profile 1 check",
                                                 "profile": startupProfile])
        }
        return
      }
      let child = Runtime()
      child.root = self.root
      do {
        try child.start(session: adapter?.session)
      } catch {
        finishBrowserCheck(ok: false, values: ["profile_isolation": false,
                                               "error": "cannot start a Profile 1 window: \(error)",
                                               "profile": startupProfile])
        return
      }
      children.append(child)
      // The check owns this window's profile from here on: its snapshot delivery must not set it
      // back to the space it shows (relaunch-pins isolation flake, u25d-implementation-2-10).
      child.profilePinned = true
      guard child.host?.setProfileDirectory("Profile 1") == true else {
        finishBrowserCheck(ok: false, values: ["profile_isolation": false,
                                               "error": "the window cannot load Profile 1",
                                               "profile": startupProfile])
        return
      }
      pinsIsolationChild = child
      browserCheckPhase = 1
    case 1:
      guard let child = pinsIsolationChild, let childHost = child.host else { return }
      let childProfile = childHost.profileDirectory()
      guard childProfile == "Profile 1" else {
        if browserCheckAttempts > 300 {
          finishBrowserCheck(ok: false, values: ["profile_isolation": false,
                                                 "error": "Profile 1 window reports \(childProfile)",
                                                 "profile": startupProfile])
        }
        return
      }
      guard let profileItem = child.extensionItems.first(where: { $0.id == id }) else {
        if browserCheckAttempts > 300 {
          finishBrowserCheck(ok: false, values: ["profile_isolation": false,
                                                 "error": "Profile 1 window has no extension fixture action",
                                                 "profile": childProfile])
        }
        return
      }
      let defaultPinned = extensionItems.first(where: { $0.id == id })?.pinned ?? false
      let isolated = !profileItem.pinned
      let passed = defaultPinned && isolated
      finishBrowserCheck(ok: passed, values: ["profile_isolation": passed,
                                              "profile_isolation_verified": passed,
                                              "profile": childProfile,
                                              "default_pinned": defaultPinned,
                                              "profile1_pinned": profileItem.pinned])
    default:
      break
    }
  }

  func relaunchCheckTick(_ host: any ARWindowHostAPI, mode: String) {
    let relaunchMode = CommandLine.arguments.first(where: { $0.hasPrefix("--ararat-relaunch-mode=") })
      .map { String($0.dropFirst("--ararat-relaunch-mode=".count)) } ?? ""
    if mode == "relaunch-seed", relaunchMode == "pins" { pinsSeedTick(host); return }
    if mode == "relaunch-verify", relaunchMode == "pins" || relaunchMode == "pins-isolated" {
      pinsVerifyTick(host, expected: relaunchMode == "pins")
      return
    }
    let tabs = (host.tabs() as? [any ARTabAPI]) ?? []
    if mode == "relaunch-seed" {
      if browserCheckPhase == 1, browserCheckAttempts % 100 == 0 {
        let id = relaunchSeedRows.first?.id
        let tab = tabs.first { $0.itemId == id }
        FileHandle.standardError.write(Data("ararat-trace: relaunch-seed waiting rows=\(sliceRows.count) active=\(sliceActive == id) strip_active=\(sliceActive ?? "nil") selected=\(snapshot.selectedId ?? "nil") first=\(id ?? "nil") host_active=\(host.activeItemId() ?? "nil") selection_stage=\(checkSeedSelectionStage) matched=\(tab != nil) loading=\(tab?.isLoading ?? false) navigations=\(tab?.navigationCount ?? 0)\n".utf8))
      }
      if browserCheckPhase == 0, sliceRows.count == 3, sliceRows[0].url != nil {
        relaunchSeedRows = sliceRows
        browserCheckPhase = 1
        selectCheckSeed(relaunchSeedRows[0])
      } else if browserCheckPhase == 1, relaunchSeedRows.count == 3, snapshot.selectedId == relaunchSeedRows[0].id, sliceActive == relaunchSeedRows[0].id,
                tabs.contains(where: { $0.itemId == relaunchSeedRows[0].id && !$0.isLoading && $0.navigationCount > 0 }),
                relaunchSeedRows[1].url != nil {
        browserCheckSeedID = relaunchSeedRows[1].id
        browserCheckPhase = 2
        selectCheckSeed(relaunchSeedRows[1])
      } else if browserCheckPhase == 2, let id = browserCheckSeedID, snapshot.selectedId == id, sliceActive == id,
                let tab = tabs.first(where: { $0.itemId == id }), !tab.isLoading, tab.navigationCount > 0 {
        browserCheckPhase = 3
        host.checkNavigate("data:text/html,<title>Ararat Reloaded</title>", disposition: "current")
      } else if browserCheckPhase == 3, let id = browserCheckSeedID, snapshot.selectedId == id, sliceActive == id,
                let tab = tabs.first(where: { $0.itemId == id }), !tab.isLoading, tab.navigationCount > 1,
                let space = snapshot.spaces.first(where: { $0.id == snapshot.shownSpaceId }),
                let row = space.today.first(where: { $0.id == id }), row.url == tab.url,
                let records = captureCheckRows(), host.checkStockBrowsers() == 0 {
        let ready: [String: Any] = ["ready": true, "space": space.id, "selected": id,
                                    "url": tab.url, "items": space.today.map(\.id),
                                    "records": records.map { Array($0.prefix(2)) },
                                    "entry_count": tab.entryCount, "can_go_back": tab.canGoBack]
        let validHistory = tab.entryCount == 2 && tab.canGoBack
        browserCheckPhase = 4
        tab.checkFlushHistory { written in
          MainActor.assumeIsolated {
            guard written, validHistory else {
              self.finishBrowserCheck(ok: false, values: ["error": "history flush or stack failed"]); return
            }
            guard let symbol = dlsym(Launcher.handle, "AraratCheckCommitProfilePrefs") else {
              self.finishBrowserCheck(ok: false, values: ["error": "missing profile prefs commit API"]); return
            }
            typealias Commit = @convention(c) (UnsafeRawPointer, @escaping @convention(block) (Bool) -> Void) -> Void
            let commit = unsafeBitCast(symbol, to: Commit.self)
            let profile = "Default" as NSString
            commit(Unmanaged.passUnretained(profile).toOpaque()) { done in
              MainActor.assumeIsolated {
                guard done else {
                  self.finishBrowserCheck(ok: false, values: ["error": "profile unavailable for prefs commit"]); return
                }
                guard let data = try? JSONSerialization.data(withJSONObject: ready, options: [.sortedKeys]),
                      let line = String(data: data, encoding: .utf8) else {
                  self.finishBrowserCheck(ok: false, values: ["error": "cannot encode ready state"]); return
                }
                print(line); fflush(stdout)
                if CommandLine.arguments.contains("--ararat-relaunch-mode=relaunch") {
                  self.finishBrowserCheck(ok: true, values: [:])
                }
              }
            }
          }
        }
      }
      return
    }
    guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--ararat-relaunch-expected=") }),
          let data = Data(base64Encoded: String(argument.dropFirst("--ararat-relaunch-expected=".count))),
          let expected = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let spaceID = expected["space"] as? String, let selected = expected["selected"] as? String,
          let url = expected["url"] as? String, let items = expected["items"] as? [String],
          let entryCount = expected["entry_count"] as? Int, expected["can_go_back"] as? Bool == true,
          let committed = expected["records"] as? [[String]] else {
      finishBrowserCheck(ok: false, values: ["error": "invalid expected state"]); return
    }
    guard snapshot.shownSpaceId == spaceID, snapshot.selectedId == selected,
          let space = snapshot.spaces.first(where: { $0.id == spaceID }),
          let tab = tabs.first(where: { $0.itemId == selected }), !tab.isLoading,
          tab.navigationCount > 0, tab.url == url, sliceActive == selected else { return }
    let rows = space.today + space.pinned + space.favorites
    guard let records = captureCheckRows() else { return }
    let present = Set(records.map { Array($0.prefix(2)) })
    let allPresent = Set(committed).isSubset(of: present) && Set(items).isSubset(of: Set(rows.map(\.id)))
    let othersUnloaded = rows.filter { items.contains($0.id) && $0.id != selected }.allSatisfy(\.unloaded)
    let stock = host.checkStockBrowsers()
    let browserViews = host.checkBrowserViews()
    let historyRestored = Int(tab.entryCount) == entryCount && tab.canGoBack
    guard let crashSymbol = dlsym(Launcher.handle, "AraratCheckCrashState") else {
      finishBrowserCheck(ok: false, values: ["error": "missing crash state API"]); return
    }
    let crashCheck = unsafeBitCast(crashSymbol, to: (@convention(c) (UnsafeRawPointer) -> UnsafeRawPointer?).self)
    let defaultProfile = "Default" as NSString
    guard let crashPointer = crashCheck(Unmanaged.passUnretained(defaultProfile).toOpaque()),
          let crashState = Unmanaged<NSDictionary>.fromOpaque(crashPointer).takeUnretainedValue() as? [String: Bool],
          let lastCrashed = crashState["last_exit_crashed"], let waiting = crashState["waiting_for_ack"] else {
      finishBrowserCheck(ok: false, values: ["error": "invalid crash state"]); return
    }
    let crashExpected = CommandLine.arguments.contains("--ararat-relaunch-mode=crash")
    let crashCorrect = lastCrashed == crashExpected && !waiting
    finishBrowserCheck(ok: allPresent && othersUnloaded && historyRestored && crashCorrect && stock == 0 && browserViews == 0,
                       values: ["space_restored": true, "selected_live": true, "url_restored": true,
                                "committed_records_present": allPresent, "others_unloaded": othersUnloaded,
                                "history_restored": historyRestored, "entry_count": tab.entryCount,
                                "can_go_back": tab.canGoBack, "last_exit_crashed": lastCrashed,
                                "waiting_for_ack": waiting, "stock_browsers": stock, "browser_views": browserViews])
  }

  func browserCheckTick() {
    guard let mode = browserCheckMode else { return }
    if settingsCheck?.capturing == true || downloadsCheck?.capturing == true || toastsCheck?.capturing == true || splitFocusCheck?.capturing == true || splitCommandsCheck?.capturing == true || headerCheck?.capturing == true || siteControlsCheck?.capturing == true || extensionActionsCheck?.capturing == true || createSpaceCheck?.capturing == true || windowDragCheck?.capturing == true { return }
    if browserCheckPhase != browserCheckTracedPhase {
      browserCheckTracedPhase = browserCheckPhase
      FileHandle.standardError.write(Data("ararat-trace: browser-check=\(mode) phase=\(browserCheckPhase) tabs=\(host?.tabs().count ?? 0) children=\(children.count) popups=\(popups.count)\n".utf8))
    }
    browserCheckAttempts += 1
    var timeoutValues: [String: Any] = ["timeout": true]
    if mode == "errorpages" || mode == "screen-errorpages" {
      timeoutValues.merge(["phase": browserCheckPhase, "conditions": errorPageConditions,
        "failed_conditions": errorPageConditionNames.filter { errorPageConditions[$0] != true },
        "fixture_error": promptFixtureError as Any? ?? NSNull(),
        "page": errorPageItem.flatMap { adapter?.checkFailureState(item: $0) } ?? [:]]) { _, new in new }
    }
    if mode == "download-close" {
      let names = ["private_window", "download_pending", "close_blocked", "dialog_action", "window_closed"]
      timeoutValues.merge(["phase": browserCheckPhase, "conditions": downloadCloseConditions,
        "failed_conditions": names.filter { downloadCloseConditions[$0] != true },
        "dialog_fallback": downloadCloseFallback,
        "download_count": popups.first?.host?.checkInProgressDownloadCount() as Any? ?? NSNull(),
        "fixture_error": promptFixtureError as Any? ?? NSNull()]) { _, new in new }
      if !errorPageConditions.isEmpty {
        timeoutValues["errorpage_conditions"] = errorPageConditions
        timeoutValues["errorpage_failed_conditions"] = errorPageConditionNames.filter { errorPageConditions[$0] != true }
      }
    }
    if mode == "organize" || mode == "screen-organize" {
      timeoutValues["conditions"] = organizeConditions
      timeoutValues["failed_conditions"] = organizeConditionNames(screen: mode == "screen-organize").filter { organizeConditions[$0] != true }
    }
    if mode == "commandbar" || mode == "screen-commandbar" {
      timeoutValues.merge(commandBarCheckDiagnostics()) { _, new in new }
    }
    if mode == "keyboard" || mode == "screen-keyboard" {
      timeoutValues.merge(keyboardResults) { _, new in new }
      timeoutValues["phase"] = browserCheckPhase
      timeoutValues["fixture_error"] = promptFixtureError as Any? ?? NSNull()
      timeoutValues["script_result"] = keyboardScriptResult as Any? ?? NSNull()
      timeoutValues["script_pending"] = keyboardScriptPending
      timeoutValues["visible_windows"] = NSApp.windows.filter { $0.isVisible || $0.isKeyWindow }.map { ["number": $0.windowNumber, "visible": $0.isVisible, "key": $0.isKeyWindow] as [String: Any] }
      timeoutValues["host_window_number"] = host?.window().windowNumber ?? 0
      timeoutValues["selection_diagnostics"] = checkSelectionDiagnostics(item: browserCheckSeedID)
      timeoutValues["keyboard_command_active"] = keyboardCommandActive as Any? ?? NSNull()
      timeoutValues["keyboard_command_tx"] = keyboardCommandTx
      timeoutValues["keyboard_selection_mark"] = keyboardSelectionMark
      timeoutValues["selection_state"] = adapter?.checkSelectionState() ?? [:]
      timeoutValues["devtools_ready_state"] = keyboardDevToolsReadyState
      if browserCheckAttempts > 900 && CommandLine.arguments.contains("--ararat-space-matrix-check") {
        timeoutValues["matrix_diagnostics"] = matrixDiagnostics()
      }
      if let error = promptFixtureError { finishBrowserCheck(ok: false, values: timeoutValues.merging(["error": error]) { _, new in new }); return }
    }
    if mode == "fullscreen" || mode == "screen-fullscreen" {
      timeoutValues["fullscreen_state"] = host?.checkFullscreenState() ?? [:]
      timeoutValues["fullscreen_element"] = fullscreenElement as Any? ?? NSNull()
      timeoutValues["round"] = fullscreenRound
      timeoutValues["completed"] = fullscreenResults
      if mode == "fullscreen" {
        timeoutValues["shown_profile"] = host?.profileDirectory() ?? ""
        timeoutValues["shown_has_browser"] = host?.hasBrowser() ?? false
        timeoutValues["fullscreen_check_has_browser"] = host?.hasBrowser(forProfile: "Fullscreen Check") ?? false
        timeoutValues["app_activated"] = fullscreenActivated
      } else {
        timeoutValues["app_active"] = NSApp.isActive
        timeoutValues["window_key"] = host?.window().isKeyWindow ?? false
        timeoutValues["window_visible"] = host?.window().isVisible ?? false
        timeoutValues["first_responder"] = host?.window().firstResponder.map { String(describing: type(of: $0)) } ?? "none"
        timeoutValues["fullscreen_entered_notification"] = fullscreenEnteredNotification
        timeoutValues["fullscreen_exited_notification"] = fullscreenExitGate.exited
        timeoutValues["sidebar_state"] = container?.sidebarState ?? "none"
        timeoutValues["sidebar_lights_hidden"] = container?.sidebarLightsHidden ?? false
        timeoutValues["appkit_lights_visible"] = container?.appKitLightsVisible ?? false
        timeoutValues["seed_selected"] = browserCheckSeedID != nil && sliceActive == browserCheckSeedID
        if let tab = (host?.tabs() as? [any ARTabAPI])?.first {
          timeoutValues["tab_loading"] = tab.isLoading
          timeoutValues["tab_navigation_count"] = tab.navigationCount
          timeoutValues["tab_view_in_window"] = tab.view?.window != nil && tab.view?.window === host?.window()
        }
      }
    }
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
      if mode == "incognito" { timeoutValues["selection_diagnostics"] = checkSelectionDiagnostics(item: browserCheckSeedID) }
      if mode == "incognito" {
        timeoutValues["child_hosts"] = children.filter { $0.host != nil }.count
        if CommandLine.arguments.contains("--ararat-incognito-window-check") {
          timeoutValues["regular_rows_before"] = quitBefore ?? []
          timeoutValues["regular_rows_current"] = captureCheckRows() ?? []
          timeoutValues["regular_rows_during"] = incognitoWindowRows ?? []
          timeoutValues["regular_child_window"] = children.first?.windowID ?? incognitoWindowID
          timeoutValues["regular_child_tabs"] = (children.first?.host?.tabs() as? [any ARTabAPI] ?? []).map {
            ["live": $0.liveId, "item": $0.itemId ?? "", "url": $0.url]
          }
          timeoutValues["regular_private_expected"] = ["live": incognitoPrivateLive, "profile_pointer": incognitoPrivateProfile,
                                                       "browser_pointer": incognitoPrivateBrowser]
          timeoutValues["regular_child_expected_live"] = incognitoWindowLive
          timeoutValues["regular_child_expected_item"] = incognitoWindowItem
          if let adapter {
            let mapping = adapter.session.queue.sync {
              (adapter.session.store?.liveTab(item: incognitoWindowItem),
               adapter.session.store?.itemForLive(liveId: incognitoWindowLive))
            }
            timeoutValues["regular_child_current_mapping"] = mapping.0 as Any? ?? NSNull()
            timeoutValues["regular_child_current_reverse_mapping"] = mapping.1 as Any? ?? NSNull()
          }
        }
      }
      timeoutValues["default_rows"] = snapshot.spaces.first(where: { $0.id == "default" })?.today.count ?? 0
      timeoutValues["named_rows"] = snapshot.spaces.first(where: { $0.id == "named" })?.today.count ?? 0
      timeoutValues["application_active"] = NSApp.isActive
      timeoutValues["application_hidden"] = NSApp.isHidden
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
    if mode == "screen-dialogs" {
      timeoutValues["conditions"] = dialogsScreenChecks
      timeoutValues["steps"] = dialogsScreenSteps
      timeoutValues["failed_conditions"] = ["permission_position", "return_keeps_prompt", "sidebar_click", "escape_dismisses", "long_origin_wrapped", "javascript_before_permission", "permission_after_javascript", "split_pane_after_activation", "transfer_dim"].filter { dialogsScreenChecks[$0] != true }
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
    if ["popup", "ext-popup", "ext-windows-popup", "fullscreen", "keyboard"].contains(mode) {
      let front = checkFrontApplication()
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
                           "opener_probe_started": browserCheckPopupOpenerProbeStarted,
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
                           "process_id": ProcessInfo.processInfo.processIdentifier,
                           "front_now": front ?? "", "front_change": popupFrontChange ?? [:],
                           "windows_hidden": popupWindowsHidden]) { _, new in new }
      if mode == "popup" {
        timeoutValues["popup_new_tab_before_tabs"] = popupNewTabBefore.map { ["live": $0.live, "item": $0.item ?? ""] }
        timeoutValues["popup_new_tab_before_rows"] = popupNewTabRows.sorted()
        timeoutValues["popup_workspace_selection"] = checkSelectionDiagnostics(item: snapshot.selectedId)
        timeoutValues["child_hosts"] = children.filter { $0.host != nil }.count
        if let host {
          let tabs = (host.tabs() as? [any ARTabAPI] ?? []).map { (live: $0.liveId, item: $0.itemId) }
          timeoutValues["popup_current_tabs"] = tabs.map { ["live": $0.live, "item": $0.item ?? ""] }
          timeoutValues["popup_current_rows"] = snapshot.spaces.flatMap { $0.today + $0.pinned + $0.favorites }.map(\.id).sorted()
          let oldLives = Set(popupNewTabBefore.map(\.live))
          let added = tabs.filter { !oldLives.contains($0.live) }
          timeoutValues["popup_current_mappings"] = Self.popupTabMappings(tabs).map { popupStoreMappings($0) } ?? [:]
          timeoutValues["popup_new_tab_presentation"] = added.count == 1 ? host.checkPagePresentation(added[0].live) : [:]
        }
      }
    }
    let limit = ["keyboard", "screen-keyboard", "errorpages", "screen-errorpages", "downloads", "screen-downloads", "toasts", "screen-toasts", "private-window", "screen-private-window", "private-isolation", "private-downloads", "private-durability-seed", "private-durability-verify", "split-focus", "screen-split-focus", "split-commands", "screen-split-commands", "urlfield", "screen-urlfield", "site-controls", "screen-site-controls", "ext-actions", "screen-ext-actions", "onboarding", "screen-onboarding", "window-drag", "screen-window-drag", "create-space", "screen-create-space"].contains(mode) || SettingsScreenCheck.Mode.mode(mode) != nil ? 900 : 300
    if browserCheckAttempts > limit {
      if mode == "download-close", !errorPageConditions.isEmpty {
        browserCheckMode = CommandLine.arguments.contains("--ararat-screen=errorpages") ? "screen-errorpages" : "errorpages"
      }
      if mode == "dock" || mode == "screen-dock" {
        timeoutValues.merge(dockCheckDiagnostics(screen: mode == "screen-dock")) { _, new in new }
      }
      if mode == "look" || mode == "screen-look" {
        timeoutValues.merge(lookCheckDiagnostics(screen: mode == "screen-look")) { _, new in new }
      }
      if sidebarCheckMode(mode) != nil {
        timeoutValues.merge(sidebarCheckDiagnostics(mode: mode, screen: mode.hasPrefix("screen-"))) { _, new in new }
      }
      if SettingsScreenCheck.Mode.mode(mode) != nil {
        timeoutValues.merge(settingsCheckDiagnostics(mode: mode)) { _, new in new }
      }
      if mode == "downloads" || mode == "screen-downloads" { timeoutValues.merge(downloadsCheck?.diagnostics(screen: mode == "screen-downloads") ?? [:]) { _, new in new } }
      if mode == "toasts" || mode == "screen-toasts" { timeoutValues.merge((toastsCheck ?? ToastsCheck()).diagnostics(screen: mode == "screen-toasts")) { _, new in new } }
      if mode == "private-window" || mode == "screen-private-window" {
        timeoutValues.merge(privateWindowCheck?.diagnostics() ?? [:]) { _, new in new }
      }
      if mode == "private-isolation" { timeoutValues.merge(privateIsolationCheck?.diagnostics() ?? [:]) { _, new in new } }
      if mode == "private-downloads" { timeoutValues.merge(privateDownloadsCheck?.diagnostics() ?? [:]) { _, new in new } }
      if mode == "split-focus" || mode == "screen-split-focus" { timeoutValues.merge((splitFocusCheck ?? SplitFocusCheck()).diagnostics(screen: mode == "screen-split-focus")) { _, new in new } }
      if mode == "split-commands" || mode == "screen-split-commands" { timeoutValues.merge((splitCommandsCheck ?? SplitCommandsCheck()).diagnostics(screen: mode == "screen-split-commands")) { _, new in new } }
      if mode == "header" || mode == "screen-header" { timeoutValues.merge((headerCheck ?? HeaderCheck()).diagnostics(screen: mode == "screen-header")) { _, new in new } }
      if mode == "urlfield" || mode == "screen-urlfield" { timeoutValues.merge((urlFieldCheck ?? URLFieldCheckState()).diagnostics(screen: mode == "screen-urlfield")) { _, new in new } }
      if mode == "site-controls" || mode == "screen-site-controls" { timeoutValues.merge((siteControlsCheck ?? SiteControlsCheck()).diagnostics(screen: mode == "screen-site-controls")) { _, new in new } }
    if mode == "window-drag" || mode == "screen-window-drag" { timeoutValues.merge((windowDragCheck ?? WindowDragCheckState()).diagnostics(screen: mode == "screen-window-drag")) { _, new in new } }
    if mode == "create-space" || mode == "screen-create-space" { timeoutValues.merge((createSpaceCheck ?? CreateSpaceCheckState()).diagnostics(screen: mode == "screen-create-space")) { _, new in new } }
    if mode == "folder-upload" || mode == "screen-folder-upload" { timeoutValues.merge(folderUploadCheckDiagnostics(screen: mode == "screen-folder-upload")) { _, new in new } }
      if mode == "ext-actions" || mode == "screen-ext-actions" { timeoutValues.merge((extensionActionsCheck ?? ExtensionActionsCheck()).diagnostics(screen: mode == "screen-ext-actions")) { _, new in new } }
      if mode == "little-window" || mode == "screen-little-window" { timeoutValues.merge(littleWindowCheckDiagnostics(screen: mode == "screen-little-window")) { _, new in new } }
      if mode == "onboarding" || mode == "screen-onboarding" {
        timeoutValues.merge(onboardingCheckDiagnostics(screen: mode == "screen-onboarding")) { _, new in new }
      }
      finishBrowserCheck(ok: false, values: timeoutValues); return
    }
    if mode == "profiles", CommandLine.arguments.contains("--ararat-multiple-close-check"), host == nil,
       let symbol = dlsym(Launcher.handle, "AraratBrowserCount") {
      let count = unsafeBitCast(symbol, to: (@convention(c) () -> UInt).self)()
      if browserCheckPhase == 8, count == 1, multipleCloseChildValid(), let childHost = children.first?.host,
         let after = captureCheckRows(), let before = profileCloseBefore,
         let pages = profileCloseFinal["dialog_pages"] as? [[String: Any]] {
        let rowsKept = before.filter { $0.first != "window" } == after.filter { $0.first != "window" }
        let rootRemoved = !after.contains { $0.count >= 2 && $0[0] == "window" && $0[1] == windowID }
        let childKept = after.contains { $0.count >= 2 && $0[0] == "window" && $0[1] == children[0].windowID }
        multiClosePassed = profileCheckPassed && rowsKept && rootRemoved && childKept &&
          profileCloseFinal["close_cancelled"] as? Int == 2 && multipleClosePagesValid(pages, defaultCount: 2, namedCount: 1)
        profileCheckResult["multiple_child_unchanged"] = true
        profileCheckResult["multiple_rows_unchanged"] = rowsKept
        profileCheckResult["multiple_root_removed"] = rootRemoved
        profileCheckResult["multiple_child_kept"] = childKept
        profileCheckResult["multiple_rows_before"] = before
        profileCheckResult["multiple_rows_after"] = after
        profileCheckResult["root_window_id"] = windowID
        profileCheckResult["child_window_id"] = children[0].windowID
        profileCheckResult["expected_dialog_items"] = splitCloseExpected
        profileCheckResult["expected_default_items"] = Array(multiCloseDefaultItems).sorted()
        profileCheckResult["multiple_final"] = profileCloseFinal
        browserCheckPhase = 9
        childHost.close()
        return
      }
      if browserCheckPhase == 9, count == 0, children.isEmpty {
        finishBrowserCheck(ok: multiClosePassed && browserCheckStock == 0, values: profileCheckResult)
        return
      }
      return
    }
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
        profileCloseFinal["beforeunload_profiles"] as? [String] == ["Default", "Profile 1"] &&
        splitClosePagesMatch(profileCloseFinal) && splitCloseConfirmRaceOK
      profileCheckResult.merge(["cancel_run": profileCloseCancelled, "close_run": profileCloseFinal,
        "expected_dialog_items": splitCloseExpected,
        "selection_confirm_race": splitCloseConfirmRaceOK,
        "rows_before_close": profileCloseBefore ?? [], "rows_after_close": after ?? [],
        "rows_unchanged_after_close": unchanged, "window_removed": removed,
        "widget_closed": true, "stock_browsers": browserCheckStock]) { _, new in new }
      finishBrowserCheck(ok: profileCheckPassed && closed && unchanged && removed && browserCheckStock == 0,
                         values: profileCheckResult)
      return
    }
    Self.dispatchPopupCheck(mode: mode, phase: browserCheckPhase) {
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
        browserCheckPhase = 9
        popup.checkOpenDevTools()
      } else if browserCheckPhase == 9, popups.count == 2, popup.checkDevToolsHostCount() == 1,
                let toolsHost = popups.last?.host {
        toolsHost.checkKeyboardCommand("close")
        browserCheckPhase = 10
      } else if browserCheckPhase == 10, popups.count == 1, popup.checkDevToolsHostCount() == 0 {
        devtoolsResults["devtools_command_close"] = true
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
    } regular: {
    guard let host else { return }
    if mode == "history-clear" {
      if historyClearCheck == nil { historyClearCheck = HistoryClearCheck(runtime: self) }
      historyClearCheck?.tick(host)
      return
    }
    if mode == "history-purge" {
      if historyPurgeCheck == nil { historyPurgeCheck = HistoryPurgeCheck(runtime: self) }
      historyPurgeCheck?.tick(host)
      return
    }
    if mode == "devtools" { devtoolsCheckTick(host); return }
    if mode == "screen-devtools" { devtoolsScreenTick(host); return }
    if mode == "permissions" { permissionCheckTick(host); return }
    if mode == "dialogs" { dialogCheckTick(host); return }
    if mode == "protocol" { protocolCheckTick(host); return }
    if mode == "relaunch-seed" || mode == "relaunch-verify" { relaunchCheckTick(host, mode: mode); return }
    if mode == "autofill" { autofillCheckTick(host); return }
    if mode == "dock" || mode == "screen-dock" { dockCheckTick(host, screen: mode == "screen-dock"); return }
    if SettingsScreenCheck.Mode.mode(mode) != nil { settingsCheckTick(mode); return }
    if mode == "look" || mode == "screen-look" { lookCheckTick(host, screen: mode == "screen-look"); return }
    if sidebarCheckMode(mode) != nil { sidebarCheckTick(host, screen: mode.hasPrefix("screen-"), mode: mode); return }
    if mode == "organize" || mode == "screen-organize" { organizeCheckTick(host, screen: mode == "screen-organize"); return }
    if mode == "commandbar" || mode == "screen-commandbar" { commandBarCheckTick(host, screen: mode == "screen-commandbar"); return }
    if mode == "keyboard" || mode == "screen-keyboard" { keyboardCheckTick(host, screen: mode == "screen-keyboard"); return }
    if mode == "screen-prompts" { promptScreenTick(host); return }
    if mode == "screen-dialogs" { dialogsScreenTick(host); return }
    if mode == "empty" { emptyCheckTick(host); return }
    if mode == "profiles" { profileCheckTick(host); return }
    if mode == "incognito" { incognitoCheckTick(host); return }
    if mode == "download-close" { downloadCloseCheckTick(host); return }
    if mode == "downloads" || mode == "screen-downloads" { downloadsCheckTick(host, screen: mode == "screen-downloads"); return }
    if mode == "toasts" || mode == "screen-toasts" { toastsCheckTick(host, screen: mode == "screen-toasts"); return }
    if mode == "private-window" || mode == "screen-private-window" { privateWindowCheckTick(host, screen: mode == "screen-private-window"); return }
    if mode == "private-isolation" { privateIsolationCheckTick(host); return }
    if mode == "private-downloads" { privateDownloadsCheckTick(host); return }
    if mode == "private-durability-seed" || mode == "private-durability-verify" { privateDurabilityTick(host, mode: mode); return }
    if mode == "split-focus" || mode == "screen-split-focus" { splitFocusCheckTick(host, screen: mode == "screen-split-focus"); return }
    if mode == "split-commands" || mode == "screen-split-commands" { splitCommandsCheckTick(host, screen: mode == "screen-split-commands"); return }
    if mode == "header" || mode == "screen-header" { headerCheckTick(host, screen: mode == "screen-header"); return }
    if mode == "urlfield" || mode == "screen-urlfield" { urlFieldCheckTick(host, screen: mode == "screen-urlfield"); return }
    if mode == "site-controls" || mode == "screen-site-controls" { siteControlsCheckTick(host, screen: mode == "screen-site-controls"); return }
    if mode == "window-drag" || mode == "screen-window-drag" { windowDragCheckTick(host, screen: mode == "screen-window-drag"); return }
    if mode == "create-space" || mode == "screen-create-space" { createSpaceCheckTick(host, screen: mode == "screen-create-space"); return }
    if mode == "folder-upload" || mode == "screen-folder-upload" { folderUploadCheckTick(host, screen: mode == "screen-folder-upload"); return }
    if mode == "ext-actions" || mode == "screen-ext-actions" { extensionActionsCheckTick(host, screen: mode == "screen-ext-actions"); return }
    if mode == "little-window" || mode == "screen-little-window" { littleWindowCheckTick(host, screen: mode == "screen-little-window"); return }
    if mode == "onboarding" || mode == "screen-onboarding" { onboardingCheckTick(host, screen: mode == "screen-onboarding"); return }
    if mode == "errorpages" || mode == "screen-errorpages" { errorPagesCheckTick(host, screen: mode == "screen-errorpages"); return }
    if mode == "ext-windows" || mode == "screen-profiles" { extensionCheckTick(host, screen: mode == "screen-profiles"); return }
    if mode == "ext-windows-popup" { extensionPopupWindowCheckTick(host); return }
    if mode == "ext-popup" { extensionActionCheckTick(host); return }
    if mode == "screen-extensions" { extensionScreenTick(host); return }
    if mode == "fullscreen" || mode == "screen-fullscreen" { fullscreenCheckTick(host, screen: mode == "screen-fullscreen"); return }
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
      if mode == "sadtab" {
        if !tab.checkCrashRenderer() { finishBrowserCheck(ok: false, values: ["error": "renderer shutdown failed"]) }
      } else if mode == "newtab" {
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
    } else if mode == "sadtab", browserCheckPhase == 2,
              let id = browserCheckSeedID,
              let tab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == id }),
              tab.crashed, adapter?.crashedItems.contains(id) == true {
      browserCheckPhase = 3
      browserCheckBefore = snapshot
      if let row = sliceRows.first(where: { $0.id == id }), let url = row.url { adapter?.select(id: id, url: url) }
    } else if mode == "sadtab", browserCheckPhase == 3,
              let id = browserCheckSeedID,
              let tab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == id }),
              !tab.crashed, !tab.isLoading, tab.navigationCount > 1,
              adapter?.crashedItems.contains(id) == false, sliceActive == id {
      let stock = host.checkStockBrowsers()
      finishBrowserCheck(ok: stock == 0, values: ["renderer_crashed": true, "strip_crashed": true, "reloaded": true, "stock_browsers": stock])
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
      if CommandLine.arguments.contains("--ararat-page-only-menu-check") {
        guard placed, let rows = captureCheckRows() else { return }
        quitBefore = rows
        let trace: [String: Any] = ["tick": browserCheckAttempts, "capture": "before", "rows": pageOnlyTraceRows(rows) ?? []]
        if let data = try? JSONSerialization.data(withJSONObject: trace, options: [.sortedKeys]),
           let line = String(data: data, encoding: .utf8) {
          FileHandle.standardError.write(Data("ararat-trace: page-only-rows \(line)\n".utf8))
        }
        popup.checkNavigate("data:text/html,<title>Ararat save check</title>save", disposition: "current")
        popup.window().makeKeyAndOrderFront(nil)
        browserCheckPhase = 41
        return
      }
      let stock = host.checkStockBrowsers()
      finishBrowserCheck(ok: placed && stock == 0,
        values: ["command_click": true, "context_menu": true, "popup_placed": placed,
                 "popup_x": frame.origin.x, "popup_y": frame.origin.y, "stock_browsers": stock])
    } else if mode == "screen-links", browserCheckPhase == 41, let popup = popups.first?.host,
              popup.window().isKeyWindow, let tab = (popup.tabs() as? [any ARTabAPI])?.first,
              tab.title == "Ararat save check", !tab.isLoading {
      guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: popup.window().windowNumber,
          context: nil, characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1) else { return }
      NSApp.sendEvent(event)
      browserCheckPhase = 42
    } else if mode == "screen-links", browserCheckPhase == 42, let popup = popups.first?.host,
              popup.checkPageOnlySaveCount() == 1,
              let save = NSApp.windows.compactMap({ $0 as? NSSavePanel }).first(where: { $0.isVisible }) {
      let rows = captureCheckRows()
      let trace: [String: Any] = ["tick": browserCheckAttempts, "capture": "after", "rows": pageOnlyTraceRows(rows) as Any? ?? NSNull(), "diff": checkRecordDiff(quitBefore, rows)]
      if let data = try? JSONSerialization.data(withJSONObject: trace, options: [.sortedKeys]),
         let line = String(data: data, encoding: .utf8) {
        FileHandle.standardError.write(Data("ararat-trace: page-only-rows \(line)\n".utf8))
      }
      guard pageOnlyRowsUnchanged(quitBefore, rows) else { finishBrowserCheck(ok: false, values: ["page_only_menu_rows": false]); return }
      save.cancel(nil)
      browserCheckPhase = 43
    } else if mode == "screen-links", browserCheckPhase == 43, let popup = popups.first?.host,
              !NSApp.windows.contains(where: { $0 is NSSavePanel && $0.isVisible }) {
      let unchanged = pageOnlyRowsUnchanged(quitBefore, captureCheckRows())
      finishBrowserCheck(ok: unchanged && popup.checkPageOnlySaveCount() == 1 && host.checkStockBrowsers() == 0,
        values: ["command_click": true, "context_menu": true, "popup_placed": true, "page_only_save": true,
                 "rows_unchanged": unchanged, "stock_browsers": host.checkStockBrowsers()])
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
    } else if mode == "menu", browserCheckPhase == 4, commandPresenter?.controller.isOpen == true {
      guard host.tabs().count == 3 else {
        finishBrowserCheck(ok: false, values: ["new_tab_created_early": true])
        return
      }
      commandPresenter?.close()
      guard host.checkFocusSearch(), commandPresenter?.controller.mode == .search else {
        finishBrowserCheck(ok: false, values: ["focus_search_opened": false]); return
      }
      commandPresenter?.close()
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
    } else if mode == "menu", browserCheckPhase == 8, commandPresenter?.controller.isOpen == true {
      let bar = commandPresenter?.controller
      bar?.update(query: "https://example.test/menu-empty")
      bar?.commit(forceNewTab: false)
      browserCheckPhase = 13
    } else if mode == "menu", browserCheckPhase == 13, host.hasBrowser(), !host.tabs().isEmpty {
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
        "last_selected": true, "ntp_preserved": true, "reused_empty_host": true, "focus_search_opened": true,
        "stock_browsers": stock])
    } else if mode == "popup", browserCheckPhase == 2,
              let popup = popups.first?.host,
              let tab = (popup.tabs() as? [any ARTabAPI])?.first, !tab.isLoading, tab.title == "Popup" {
      browserCheckPopupSize = popups.first?.createdSize ?? popup.window().frame.size
      popup.checkKeyboardCommand("location")
      popup.checkKeyboardCommand("search")
      guard commandPresenter == nil, tab.itemId == nil else { finishBrowserCheck(ok: false, values: ["popup_workspace_command": true]); return }
      let original = (host.tabs() as? [any ARTabAPI] ?? []).map { (live: $0.liveId, item: $0.itemId) }
      guard let oldMappings = Self.popupTabMappings(original), !oldMappings.isEmpty,
            popupStoreMappings(oldMappings) == oldMappings else { return }
      popupNewTabBefore = original
      popupNewTabRows = Set(snapshot.spaces.flatMap { $0.today + $0.pinned + $0.favorites }.map(\.id))
      popup.checkKeyboardCommand("new")
      browserCheckPhase = 20
    } else if mode == "popup", browserCheckPhase == 20 {
      if let child = children.first(where: { $0.host != nil }), let childHost = child.host, childHost.hasBrowser() {
        popupNewTabDestination = "new_window"
        childHost.close()
        browserCheckPhase = 21
      } else {
        let tabs = (host.tabs() as? [any ARTabAPI] ?? []).map { (live: $0.liveId, item: $0.itemId) }
        let rows = Set(snapshot.spaces.flatMap { $0.today + $0.pinned + $0.favorites }.map(\.id))
        let oldLives = Set(popupNewTabBefore.map(\.live))
        let newTabs = tabs.filter { !oldLives.contains($0.live) }
        let presentation = newTabs.count == 1 ? host.checkPagePresentation(newTabs[0].live) : [:]
        let mappings = Self.popupTabMappings(tabs).map { popupStoreMappings($0) } ?? [:]
        let compositor = CommandLine.arguments.contains("--ararat-compositor=c2") ? "c2" : "c1"
        if Self.checkPopupNewTabInExistingWindow(previousTabs: popupNewTabBefore, previousRows: popupNewTabRows,
                                                 currentTabs: tabs, currentRows: rows, selected: snapshot.selectedId,
                                                 nativeActive: host.activeItemId(), compositor: compositor,
                                                 presentation: presentation, storeMappings: mappings) {
          popupNewTabDestination = "existing_window"
          browserCheckPhase = 21
        }
      }
    } else if mode == "popup", browserCheckPhase == 21, children.allSatisfy({ $0.host == nil }),
              let popup = popups.first?.host {
      popup.checkKeyboardCommand("window")
      browserCheckPhase = 22
    } else if mode == "popup", browserCheckPhase == 22,
              let child = children.first(where: { $0.host != nil }), let childHost = child.host, childHost.hasBrowser() {
      childHost.close()
      browserCheckPhase = 23
    } else if mode == "popup", browserCheckPhase == 23, children.allSatisfy({ $0.host == nil }),
              let popup = popups.first?.host {
      // A normal OTR window is a full private window now, not a page-only popup (U26f).
      popup.checkNewIncognitoWindow()
      browserCheckPhase = 24
    } else if mode == "popup", browserCheckPhase == 24,
              let privateChild = children.first(where: { $0.isPrivateWindow && $0.host != nil }),
              privateChild.host?.isPrivateWindow() == true {
      privateChild.host?.close()
      browserCheckPhase = 25
    } else if mode == "popup", browserCheckPhase == 25, popups.count == 1,
              let tab = (popups.first?.host?.tabs() as? [any ARTabAPI])?.first {
      browserCheckBefore = snapshot
      FileHandle.standardError.write(Data("ararat-trace: popup loaded navigation_count=\(tab.navigationCount)\n".utf8))
      browserCheckPhase = 3
      browserCheckPopupOpenerProbeStarted = true
      tab.probeCheckOpener()
    } else if mode == "popup", browserCheckPhase == 3,
              let tab = (popups.first?.host?.tabs() as? [any ARTabAPI])?.first, tab.checkOpenerAlive() {
      browserCheckPopupOpenerAlive = true
      browserCheckPhase = 4
      FileHandle.standardError.write(Data("ararat-trace: popup close requested\n".utf8))
      popups.first?.host?.checkKeyboardCommand("close")
    } else if mode == "popup", browserCheckPhase == 4, popups.isEmpty,
              let symbol = dlsym(Launcher.handle, "AraratBrowserCount"),
              unsafeBitCast(symbol, to: (@convention(c) () -> UInt).self)() == 1 {
      let stock = host.checkStockBrowsers()
      let rowsUnchanged = snapshot == browserCheckBefore
      let sizeOK = abs(browserCheckPopupSize.width - 400) <= 20 && abs(browserCheckPopupSize.height - 300) <= 40
      devtoolsResults = ["opener_alive": true, "popup_closed": true, "rows_unchanged": rowsUnchanged,
                         "native_new_tab": true, "native_new_window": true, "native_new_incognito_window": true, "location_search_noop": true,
                         "native_new_tab_destination": popupNewTabDestination,
                         "width": browserCheckPopupSize.width, "height": browserCheckPopupSize.height, "stock_browsers": stock]
      guard rowsUnchanged && sizeOK && stock == 0 && hiddenPopupSafe(),
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
    } else if browserCheckPhase == 3, host.hasBrowser(), commandPresenter?.controller.isOpen == true {
      guard host.tabs().isEmpty else { finishBrowserCheck(ok: false, values: ["new_tab_created_early": true]); return }
      commandPresenter?.close()
      host.checkKeyboardCommand("location")
      browserCheckPhase = 31
    } else if browserCheckPhase == 31, commandPresenter?.controller.isOpen == true {
      guard commandPresenter?.controller.mode == .newTab else { finishBrowserCheck(ok: false, values: ["empty_location_fallback": false]); return }
      commandPresenter?.close()
      host.checkMenuCommand(false)
      browserCheckPhase = 32
    } else if browserCheckPhase == 32, commandPresenter?.controller.isOpen == true {
      let bar = commandPresenter?.controller
      bar?.update(query: "https://example.test/empty")
      bar?.commit(forceNewTab: false)
      browserCheckPhase = 4
    } else if browserCheckPhase == 4, host.hasBrowser(),
              let tab = (host.tabs() as? [any ARTabAPI])?.first,
              let id = tab.itemId, !emptyRowsBefore.contains(id),
              snapshot.spaces.flatMap({ $0.today + $0.pinned + $0.favorites }).contains(where: { $0.id == id }) {
      let stock = host.checkStockBrowsers()
      finishBrowserCheck(ok: stock == 0 && emptyMenuCount > 0 && emptyRestorePassed, values: ["empty_windows_probe": emptyProbe,
        "menu_items_validated": emptyMenuCount, "enabled_command_ids": emptyMenuEnabled,
        "session_restore": emptyRestore, "new_tab": true, "new_tab_row_id": id,
        "command_bar_available": true, "empty_location_fallback": true, "stock_browsers": stock])
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
      adapter?.close(id: item, archive: false)
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
      guard promptFixturePort != nil, let row = sliceRows.first, row.url != nil else { return false }
      browserCheckSeedID = row.id
      browserCheckPhase = -1
      FileHandle.standardError.write(Data("ararat-trace: \(name) seed-select id=\(row.id)\n".utf8))
      selectCheckSeed(row)
      return false
    }
    if browserCheckPhase == -1 {
      guard let port = promptFixturePort, sliceActive == browserCheckSeedID,
            let tab = (host.tabs() as? [any ARTabAPI])?.first,
            tab.itemId == browserCheckSeedID, !tab.isLoading, tab.navigationCount > 0 else { return false }
      let url = "http://127.0.0.1:\(port)/\(name)"
      FileHandle.standardError.write(Data("ararat-trace: \(name) tab-ready\n".utf8))
      checkSeedSelectionStage = "native_page_ready"
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
      guard tab.checkPermissionShownCount() == 1 else { return }
      permissionWidgetState = tab.checkPermissionWidgetState()
      guard tab.checkPermissionDecision(0) else { return }
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
      tab.checkRequestPermission(2)
      browserCheckPhase = 8
    case 8:
      guard tab.checkPermissionShownCount() == 4, let port = promptFixturePort else { return }
      host.checkNavigate("http://127.0.0.1:\(port)/auth", disposition: "current")
      browserCheckPhase = 9
    case 9:
      guard tab.checkIsDialogActive(), !tab.checkPermissionPending(), tab.checkDialogHostIsOurs() else { return }
      permissionNavigationCleared = true
      guard tab.checkCloseModalDialogs() else { return }
      browserCheckPhase = 10
    case 10:
      guard !tab.checkIsDialogActive(), tab.url.contains("/auth"), !tab.isLoading else { return }
      let stock = host.checkStockBrowsers()
      let viewlessAnchor = host.checkViewlessBubbleAnchor()
      let anchorGeometry = host.checkViewlessBubbleAnchorGeometry()
      let geometryOK = anchorGeometry["initial"] as? Bool == true && anchorGeometry["negative_origin"] as? Bool == true && anchorGeometry["missing_host"] as? Bool == true
      let sheetOK = permissionWidgetState["no_default"] as? Bool == true && permissionWidgetState["escape_closes"] as? Bool == true && abs((permissionWidgetState["width"] as? Int ?? 0) - 340) <= 8
      finishBrowserCheck(ok: stock == 0 && tab.checkPermissionShownCount() == 4 && viewlessAnchor && geometryOK && sheetOK && permissionNavigationCleared,
        values: ["notifications": "granted", "location": "1", "midi_result": "NotAllowedError",
                 "midi_state": "prompt", "prompt_shown": tab.checkPermissionShownCount(),
                 "pending": false, "viewless_anchor_empty": viewlessAnchor, "anchor_geometry": anchorGeometry, "permission_widget": permissionWidgetState, "same_site_permission_cleared_auth_shown": permissionNavigationCleared, "stock_browsers": stock])
    default: break
    }
  }

  // Why not host.activeItemId() alone: it flips when Chrome activates the tab, while the command
  // transaction reporting it is still in flight, and a space switch issued before it lands lets that late
  // report re-select the old space's tab (record_active). Why not any strip's active tab: setProfileDirectory
  // emits an engine strip with the Browser's old active tab before the selection's activate runs.
  // The mark is set where the selection is issued, so a transaction from an earlier one cannot satisfy this.
  func keyboardSelectionSettled(_ item: String?) -> Bool {
    guard let item, keyboardCommandTx > keyboardSelectionMark, keyboardCommandActive == item,
          (adapter?.checkSelectionState()["pending_commands"] as? [String])?.isEmpty == true else { return false }
    return true
  }

  func keyboardRead(_ tab: any ARTabAPI, script: Int) {
    guard !keyboardScriptPending else { return }
    keyboardScriptPending = true
    tab.checkKeyboardScript(script) { [weak self] value in
      MainActor.assumeIsolated { self?.keyboardScriptPending = false; self?.keyboardScriptResult = value }
    }
  }

  func keyboardSend(_ host: any ARWindowHostAPI, command: String, key: String, code: UInt16, flags: NSEvent.ModifierFlags, screen: Bool) {
    if !screen { host.checkKeyboardCommand(command); return }
    guard let window = NSApp.keyWindow,
          let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: flags.contains(.shift) ? key.lowercased() : key,
            charactersIgnoringModifiers: key, isARepeat: false, keyCode: code) else { return }
    NSApp.sendEvent(event)
  }

  func keyboardCheckTick(_ host: any ARWindowHostAPI, screen: Bool) {
    if CommandLine.arguments.contains("--ararat-space-matrix-check") {
      commandSpaceMatrixTick(host, screen: screen)
      return
    }
    guard preparePromptFixture(host, name: "keyboard"), let port = promptFixturePort else { return }
    if browserCheckPhase == 35 {
      guard !(host.tabs() as? [any ARTabAPI] ?? []).contains(where: { $0.itemId == browserCheckSeedID }) else { return }
      guard snapshot.spaces.flatMap(\.pinned).first(where: { $0.id == browserCheckSeedID })?.url == keyboardSavedURL else {
        finishBrowserCheck(ok: false, values: ["pinned_close_lost_destination": true]); return
      }
      keyboardResults["fullscreen_close"] = true
      let stock = host.checkStockBrowsers()
      keyboardResults["stock_browsers"] = stock
      let required = ["page_ime", "reload", "new_tab_panel", "location_focus", "location_navigated", "today_committed",
        "pinned_saved", "back", "find_previous", "protocol_requested", "extension_command", "extension_action",
        "devtools", "forced_search", "default_space_cross_profile", "suggestion_space_cross_profile", "archive_restore", "library_restore_press", "library_delete_press", "profile_shortcuts", "inactive_reassignment", "two_window_shortcuts",
        "two_window_teardown", "inactive_profile_teardown", "profile_reload", "stale_profile_rejected", "stale_search_rejected",
        "closed_host_rejected", "invalid_targets", "stale_suggestion_actions", "core_menu_collision", "command_suggestions", "suggestion_panel_commands", "suggestion_space_commands", "suggestion_close_tab", "folder_and_move_suggestions", "tab_suggestion", "duplicate", "close", "fullscreen_new", "fullscreen_location",
        "fullscreen_find_dismissed", "fullscreen_page_escape", "fullscreen_close", "find_pasteboard", "find_zero", "find_visibility", "find_reopen_navigation", "find_devtools_geometry", "find_resized_geometry", "find_tab_guard", "find_background_result", "find_delayed_background", "find_replace_guard", "find_pending_teardown", "find_host_teardown", "find_profile_guard"]
      let requiredOK = required.allSatisfy { keyboardResults[$0] as? Bool == true }
      let hiddenWindowSafe = screen || hiddenPopupSafe()
      if !hiddenWindowSafe {
        keyboardResults["front_before_final"] = popupFrontBefore ?? ""
        keyboardResults["front_after_final"] = checkFrontApplication() ?? ""
        keyboardResults["front_change_final"] = popupFrontChange ?? [:]
        keyboardResults["windows_hidden_final"] = popupWindowsHidden
        keyboardResults["visible_windows_final"] = NSApp.windows.filter { $0.isVisible || $0.isKeyWindow }.map {
          ["number": $0.windowNumber, "visible": $0.isVisible, "key": $0.isKeyWindow] as [String: Any]
        }
      }
      let modeOK = screen
        ? keyboardResults["command_ime"] as? Bool == true && keyboardResults["find_ime_escape"] as? Bool == true &&
          keyboardResults["devtools_find"] as? Bool == true && keyboardResults["fullscreen_command_marked_escape"] as? Bool == true &&
          keyboardResults["fullscreen_find_marked_escape"] as? Bool == true && keyboardResults["core_menu_shortcut"] as? Bool == true &&
          keyboardResults["core_menu_library"] as? Bool == true && keyboardResults["core_menu_reset_width"] as? Bool == true &&
          keyboardResults["core_menu_pin"] as? Bool == true && keyboardResults["core_menu_space"] as? Bool == true && keyboardResults["core_menu_settings"] as? Bool == true &&
          keyboardResults["page_menu_settings"] as? Bool == true && keyboardResults["app_menu_settings"] as? Bool == true && keyboardResults["engine_settings"] as? Bool == true &&
          keyboardResults["extension_reserved_priority"] as? Bool == true &&
          keyboardResults["own_field_noncommand"] as? Bool == true &&
          keyboardResults["chooser_screenshot"] != nil && keyboardResults["restore_screenshot"] != nil
        : keyboardResults["beforeunload_cancel"] as? Bool == true && keyboardResults["viewless_anchor_empty"] as? Bool == true &&
          keyboardResults["hidden_settings"] as? Bool == true && keyboardResults["shared_settings"] as? Bool == true &&
          keyboardResults["settings_edit_target"] as? Bool == true && keyboardResults["settings_space_edit"] as? Bool == true && hiddenWindowSafe
      let c2 = CommandLine.arguments.contains("--ararat-compositor=c2")
      let c2OK = !c2 || (keyboardResults["c2_page_attachment"] as? Bool == true &&
        keyboardResults["c2_find_attachment"] as? Bool == true && keyboardResults["c2_find_resized_attachment"] as? Bool == true &&
        (!screen || (keyboardResults["c2_page_input_hit"] as? Bool == true && keyboardResults["c2_find_stacking_input"] as? Bool == true)))
      let caseOK = requiredOK && modeOK && c2OK && stock == 0
      keyboardResults["hidden_window_safe"] = hiddenWindowSafe
      keyboardResults["unverified_reach"] = ["core_menu_and_suggestion_reach",
        "page_only_menu_actions", "find_lifetime_and_geometry"]
      let scoped = CommandLine.arguments.contains("--ararat-keyboard-main-scope")
      finishBrowserCheck(ok: scoped && caseOK, values: keyboardResults.merging(["case": "keyboard-main", "u16_complete": false,
        "case_ok": caseOK]) { _, new in new })
      return
    }
    if (40...68).contains(browserCheckPhase) || [470, 490, 500, 520, 521, 522, 523, 524, 5241, 525, 560, 641, 642, 643, 644, 645, 680, 681].contains(browserCheckPhase) {
      keyboardProfileCheckTick(host, port: port, screen: screen)
      return
    }
    guard
          let tab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == browserCheckSeedID }) else { return }
    let baseURL = "http://127.0.0.1:\(port)/keyboard"
    func send(_ name: String, _ key: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = .command) {
      keyboardSend(host, command: name, key: key, code: code, flags: flags, screen: screen)
    }
    func fail(_ reason: String) {
      keyboardResults["error"] = reason
      keyboardResults["phase"] = browserCheckPhase
      finishBrowserCheck(ok: false, values: keyboardResults)
    }
    func bubbleNearAnchor(_ state: [String: Any], frame: NSRect) -> Bool {
      guard let x = state["anchor_x"] as? CGFloat else { return false }
      let hostFrame = NSRectFromString(state["host_frame"] as? String ?? "")
      let rtl = state["rtl"] as? Bool == true
      let expectedX = rtl ? hostFrame.maxX - 40 : hostFrame.minX + 40
      return abs(x - expectedX) <= 2 && x >= frame.minX - 32 && x <= frame.maxX + 32 &&
        frame.maxY <= hostFrame.maxY + 80 && frame.maxY >= hostFrame.maxY - 120
    }
    if (408...415).contains(browserCheckPhase),
       Set((host.tabs() as? [any ARTabAPI] ?? []).map(\.liveId)) != keyboardSettingsTabs {
      fail("settings created or closed a tab"); return
    }
    switch browserCheckPhase {
    case 1:
      guard tab.url == baseURL, !tab.isLoading else { return }
      if CommandLine.arguments.contains("--ararat-compositor=c2") {
        let presentation = host.checkPagePresentation(tab.liveId)
        guard presentation["compositor"] as? String == "c2", presentation["presented"] as? Bool == true,
              !screen || presentation["page_hit"] as? Bool == true else { return }
        keyboardResults["c2_page_attachment"] = true
        if screen { keyboardResults["c2_page_input_hit"] = true }
      }
      keyboardLiveID = tab.liveId
      guard let target = host.navigationTarget() else { fail("capture navigation target"); return }
      if !screen {
        guard host.checkViewlessBubbleAnchor() else { fail("viewless anchor"); return }
        let geometry = host.checkViewlessBubbleAnchorGeometry()
        guard geometry["initial"] as? Bool == true, geometry["negative_origin"] as? Bool == true,
              geometry["missing_host"] as? Bool == true else { fail("viewless anchor geometry"); return }
        keyboardResults["viewless_anchor_empty"] = true
        keyboardResults["anchor_geometry"] = geometry
      }
      guard !host.navigateURL("http://[", target: target) else { fail("invalid URL accepted"); return }
      var invalid = target
      invalid["epoch"] = 0
      guard !host.navigateURL(baseURL + "?invalid", target: invalid) else { fail("invalid epoch accepted"); return }
      invalid = target
      invalid["live"] = "invalid-live-id"
      guard !host.navigateURL(baseURL + "?invalid", target: invalid) else { fail("invalid live id accepted"); return }
      invalid = target
      invalid["item"] = "invalid-item-id"
      guard !host.navigateURL(baseURL + "?invalid", target: invalid) else { fail("invalid item id accepted"); return }
      invalid = target
      invalid["profile"] = "invalid-profile"
      guard !host.navigateURL(baseURL + "?invalid", target: invalid) else { fail("invalid profile accepted"); return }
      keyboardResults["invalid_targets"] = true
      if screen {
        tab.focusCheckPage()
        browserCheckPhase = 1002
        return
      }
      keyboardRead(tab, script: 1)
      browserCheckPhase = 2
    case 1002:
      guard NSApp.isActive, host.window().isKeyWindow,
            host.checkFullscreenState()["view_focused"] as? Bool == true else { return }
      keyboardRead(tab, script: 1)
      browserCheckPhase = 2
    case 2:
      guard let result = keyboardScriptResult else { return }
      keyboardScriptResult = nil
      guard result == "ready" else { fail("page IME dispatch"); return }
      let dispatched = tab.checkKeyboardIME()
      keyboardResults["ime_diagnostics"] = tab.checkKeyboardIMEState()
      guard dispatched else { fail("page IME dispatch"); return }
      browserCheckPhase = 3
    case 3:
      if let result = keyboardScriptResult {
        keyboardScriptResult = nil
        if result.contains("漢") {
          keyboardResults["page_ime"] = true
          keyboardNavigation = tab.navigationCount
          send("reload", "r", 15)
          browserCheckPhase = 4
          return
        }
      }
      keyboardRead(tab, script: 0)
    case 4:
      guard tab.navigationCount > keyboardNavigation, !tab.isLoading else { return }
      keyboardResults["reload"] = true
      guard let save = displacedMenuItems["toggle_sidebar"], save.keyEquivalent.isEmpty,
            let bookmark = displacedMenuItems["pin_tab"], bookmark.keyEquivalent.isEmpty,
            let library = displacedMenuItems["toggle_library"], library.keyEquivalent.isEmpty else { fail("core menu collision"); return }
      keyboardResults["core_menu_collision"] = true
      if screen && keyboardResults["extension_reserved_priority"] as? Bool != true {
        guard host.checkReassignProbeCommand(true) else { fail("reassign extension shortcut"); return }
        keyboardRead(tab, script: 4)
        browserCheckPhase = 401
        return
      }
      if screen, let container {
        keyboardSidebarBefore = container.sidebarState
        keyboardSend(host, command: "", key: "s", code: 1, flags: .command, screen: true)
        browserCheckPhase = 404
        return
      }
      send("new", "t", 17)
      browserCheckPhase = 5
    case 404:
      guard let container, container.sidebarState != keyboardSidebarBefore else { return }
      keyboardSend(host, command: "", key: "s", code: 1, flags: .command, screen: true)
      browserCheckPhase = 405
    case 405:
      guard let container, container.sidebarState == keyboardSidebarBefore, let sidebar else { return }
      keyboardResults["core_menu_shortcut"] = true
      keyboardLibraryBefore = sidebar.libraryOpen
      keyboardSend(host, command: "", key: "L", code: 37, flags: [.command, .shift], screen: true)
      browserCheckPhase = 406
    case 406:
      guard let sidebar, sidebar.libraryOpen != keyboardLibraryBefore else { return }
      keyboardSend(host, command: "", key: "L", code: 37, flags: [.command, .shift], screen: true)
      browserCheckPhase = 407
    case 407:
      guard let sidebar, sidebar.libraryOpen == keyboardLibraryBefore, let container else { return }
      keyboardResults["core_menu_library"] = true
      container.resizeHandle.resetWidth()
      let defaultWidth = container.resizeHandle.sidebarWidth
      container.resizeHandle.sidebarWidth = defaultWidth + 40
      guard let item = NSApp.mainMenu?.item(withTitle: "Ararat Commands")?.submenu?.items.first(where: {
        $0.representedObject as? String == "reset_sidebar_width"
      }), let action = item.action, NSApp.sendAction(action, to: item.target, from: item),
            container.resizeHandle.sidebarWidth == defaultWidth else { fail("reset width menu"); return }
      keyboardResults["core_menu_reset_width"] = true
      keyboardSettingsTabs = Set((host.tabs() as? [any ARTabAPI] ?? []).map(\.liveId))
      keyboardSend(host, command: "", key: ",", code: 43, flags: .command, screen: true)
      browserCheckPhase = 408
    case 408:
      guard let settingsWindow = (root ?? self).settings?.window, settingsWindow.isVisible,
            (root ?? self).settingsOwner === self else { return }
      keyboardSettingsWindow = settingsWindow
      settingsWindow.orderOut(nil)
      host.window().makeKeyAndOrderFront(nil)
      keyboardResults["core_menu_settings"] = true
      browserCheckPhase = 409
    case 409:
      guard host.window().isKeyWindow else { return }
      tab.focusCheckPage()
      guard host.checkFullscreenState()["view_focused"] as? Bool == true else { return }
      keyboardSend(host, command: "", key: ",", code: 43, flags: .command, screen: true)
      browserCheckPhase = 410
    case 410:
      guard let settingsWindow = keyboardSettingsWindow, settingsWindow.isVisible,
            (root ?? self).settings?.window === settingsWindow, (root ?? self).settingsOwner === self else { return }
      settingsWindow.orderOut(nil)
      host.window().makeKeyAndOrderFront(nil)
      keyboardResults["page_menu_settings"] = true
      browserCheckPhase = 411
    case 411:
      guard host.window().isKeyWindow else { return }
      guard let item = NSApp.mainMenu?.items.first?.submenu?.items.first(where: { $0.representedObject as? String == "settings" }),
            let action = item.action, NSApp.sendAction(action, to: item.target, from: item) else { fail("settings app menu dispatch"); return }
      browserCheckPhase = 412
    case 412:
      guard let settingsWindow = keyboardSettingsWindow, settingsWindow.isVisible,
            (root ?? self).settings?.window === settingsWindow, (root ?? self).settingsOwner === self else { return }
      settingsWindow.orderOut(nil)
      host.window().makeKeyAndOrderFront(nil)
      keyboardResults["app_menu_settings"] = true
      browserCheckPhase = 413
    case 413:
      guard host.window().isKeyWindow else { return }
      host.checkKeyboardCommand("settings")
      browserCheckPhase = 414
    case 414:
      guard let settingsWindow = keyboardSettingsWindow, settingsWindow.isVisible,
            (root ?? self).settings?.window === settingsWindow, (root ?? self).settingsOwner === self else { return }
      settingsWindow.orderOut(nil)
      host.window().makeKeyAndOrderFront(nil)
      keyboardResults["engine_settings"] = true
      browserCheckPhase = 415
    case 415:
      guard host.window().isKeyWindow else { return }
      send("new", "t", 17)
      browserCheckPhase = 5
    case 401:
      guard keyboardScriptResult == "cleared" else { return }
      keyboardScriptResult = nil
      keyboardSend(host, command: "", key: "l", code: 37, flags: .command, screen: true)
      guard commandPresenter == nil else { fail("location intercepted extension shortcut"); return }
      browserCheckPhase = 402
    case 402:
      if let result = keyboardScriptResult {
        keyboardScriptResult = nil
        if result == "probe-command" {
          guard commandPresenter == nil, host.checkReassignProbeCommand(false) else { fail("restore extension shortcut"); return }
          keyboardRead(tab, script: 4)
          browserCheckPhase = 403
          return
        }
      }
      keyboardRead(tab, script: 3)
    case 403:
      guard keyboardScriptResult == "cleared" else { return }
      keyboardScriptResult = nil
      keyboardResults["extension_reserved_priority"] = true
      browserCheckPhase = 4
    case 5:
      guard let presenter = commandPresenter, presenter.controller.isOpen else { return }
      guard host.tabs().count == 1, screen || (!presenter.panel.isVisible && presenter.panel.parent == nil && !host.window().isVisible) else { fail("new tab panel visibility or unexpected tab"); return }
      keyboardResults["new_tab_panel"] = true
      presenter.close()
      openCommandBar(.newTab)
      guard let newBar = commandPresenter?.controller else { fail("new tab suggestion panel"); return }
      newBar.commit(Suggestion(title: "New Tab", subtitle: "", url: nil, key: nil, target: .command(id: "new_tab"), score: 0))
      guard commandPresenter?.controller.isOpen == true, commandPresenter?.controller.mode == .newTab else { fail("new tab suggestion"); return }
      commandPresenter?.close()
      openCommandBar(.newTab)
      guard let editBar = commandPresenter?.controller else { fail("edit URL suggestion panel"); return }
      editBar.commit(Suggestion(title: "Edit URL", subtitle: "", url: nil, key: nil, target: .command(id: "edit_url"), score: 0))
      guard commandPresenter?.controller.isOpen == true, commandPresenter?.controller.mode == .editURL else { fail("edit URL suggestion"); return }
      commandPresenter?.close()
      keyboardResults["suggestion_panel_commands"] = true
      guard let container, let sidebar else { fail("workspace command views"); return }
      let initialSidebar = container.sidebarState
      let initialLibrary = sidebar.libraryOpen
      for command in ["toggle_sidebar", "toggle_sidebar", "toggle_library", "toggle_library"] {
        let previousSidebar = container.sidebarState
        let previousLibrary = sidebar.libraryOpen
        openCommandBar(.newTab)
        guard let bar = commandPresenter?.controller else { fail("command suggestion panel"); return }
        bar.commit(Suggestion(title: command, subtitle: "", url: nil, key: nil, target: .command(id: command), score: 0))
        if command == "toggle_sidebar" && container.sidebarState == previousSidebar { fail("sidebar suggestion did not toggle"); return }
        if command == "toggle_library" && sidebar.libraryOpen == previousLibrary { fail("library suggestion did not toggle"); return }
      }
      guard container.sidebarState == initialSidebar, sidebar.libraryOpen == initialLibrary else { fail("command suggestion toggles"); return }
      container.resizeHandle.resetWidth()
      let defaultWidth = container.resizeHandle.sidebarWidth
      container.resizeHandle.sidebarWidth = defaultWidth + 40
      openCommandBar(.newTab)
      guard let bar = commandPresenter?.controller else { fail("reset width suggestion panel"); return }
      bar.commit(Suggestion(title: "Reset Sidebar Width", subtitle: "", url: nil, key: nil,
                            target: .command(id: "reset_sidebar_width"), score: 0))
      guard container.resizeHandle.sidebarWidth == defaultWidth else { fail("reset width suggestion"); return }
      keyboardResults["command_suggestions"] = true
      keyboardRead(tab, script: 1)
      browserCheckPhase = 6
    case 6:
      guard let result = keyboardScriptResult else { return }
      keyboardScriptResult = nil
      guard result == "ready" else { fail("page selection setup"); return }
      send("location", "l", 37)
      if screen {
        guard let presenter = commandPresenter, presenter.controller.isOpen, presenter.panel.isKeyWindow,
              let editor = presenter.view.field.currentEditor(), presenter.panel.firstResponder === editor else { fail("synchronous field focus"); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("ararat-paste", forType: .string)
        keyboardSend(host, command: "", key: "v", code: 9, flags: .command, screen: true)
        guard presenter.view.field.stringValue == "ararat-paste" else { fail("immediate paste"); return }
      }
      browserCheckPhase = 7
    case 7:
      guard let presenter = commandPresenter, presenter.controller.isOpen else { return }
      guard presenter.controller.mode == .editURL, screen || presenter.controller.query == tab.url else { fail("location prefill"); return }
      if screen {
        guard presenter.panel.isKeyWindow, let editor = presenter.view.field.currentEditor(), presenter.panel.firstResponder === editor else { fail("synchronous field focus"); return }
        let savedBindings = presenter.panel.menuCommandBindings
        presenter.panel.menuCommandBindings = [KeyBinding(command: "toggle_sidebar", title: "Toggle Sidebar", menu: "View", description: "",
          defaultKey: nil, key: KeyCombination(key: "w", command: false, control: false, option: true, shift: false),
          customized: true, conflicting: false, assignedKey: nil)]
        let oldSidebar = container?.sidebarState
        editor.selectAll(nil)
        guard let optionW = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .option,
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: presenter.panel.windowNumber,
          context: nil, characters: "∞", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13) else { fail("own-field key event"); return }
        NSApp.sendEvent(optionW)
        guard editor.string == "∞", presenter.controller.isOpen, container?.sidebarState == oldSidebar else { fail("non-command key did not reach own field"); return }
        presenter.panel.menuCommandBindings = savedBindings
        keyboardResults["own_field_noncommand"] = true
        guard let textView = presenter.view.field.currentEditor() as? NSTextView else { fail("command field editor"); return }
        textView.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        keyboardSend(host, command: "", key: "\r", code: 36, flags: [], screen: true)
        guard presenter.controller.isOpen else { fail("marked Return closed command field"); return }
        textView.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        keyboardSend(host, command: "", key: "\r", code: 36, flags: .command, screen: true)
        guard presenter.controller.isOpen else { fail("marked Command-Return closed command field"); return }
        textView.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        keyboardSend(host, command: "", key: "\u{1b}", code: 53, flags: [], screen: true)
        guard presenter.controller.isOpen else { fail("marked Escape closed command field"); return }
        textView.unmarkText()
        keyboardResults["command_ime"] = true
        keyboardSend(host, command: "", key: "\u{1b}", code: 53, flags: [], screen: true)
      } else { presenter.close() }
      keyboardResults["location_focus"] = true
      keyboardRead(tab, script: 0)
      browserCheckPhase = 8
    case 8:
      guard let result = keyboardScriptResult else { return }
      keyboardScriptResult = nil
      guard result.contains("\"start\":2"), result.contains("\"end\":6") else { fail("page selection after cancel"); return }
      send("location", "l", 37)
      browserCheckPhase = 9
    case 9:
      guard let presenter = commandPresenter, presenter.controller.isOpen else { return }
      if screen {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(baseURL + "?second", forType: .string)
        keyboardSend(host, command: "", key: "v", code: 9, flags: .command, screen: true)
        keyboardSend(host, command: "", key: "\r", code: 36, flags: [], screen: true)
      } else {
        presenter.controller.update(query: baseURL + "?second")
        presenter.controller.commit(forceNewTab: false)
      }
      browserCheckPhase = 10
    case 10:
      guard tab.url == baseURL + "?second", !tab.isLoading,
            snapshot.spaces.flatMap(\.today).first(where: { $0.id == browserCheckSeedID })?.url == baseURL + "?second" else { return }
      guard tab.liveId == keyboardLiveID else { fail("live identity changed"); return }
      keyboardResults["location_navigated"] = true
      keyboardResults["today_committed"] = true
      if screen {
        keyboardSend(host, command: "", key: "d", code: 2, flags: .command, screen: true)
      } else {
        openCommandBar(.newTab)
        guard let bar = commandPresenter?.controller else { fail("pin suggestion panel"); return }
        bar.commit(Suggestion(title: "Pin", subtitle: "", url: nil, key: nil, target: .command(id: "pin_tab"), score: 0))
      }
      browserCheckPhase = 101
    case 101:
      guard let row = snapshot.spaces.flatMap(\.pinned).first(where: { $0.id == browserCheckSeedID }), let url = row.url else { return }
      if screen { keyboardResults["core_menu_pin"] = true }
      keyboardSavedURL = url
      send("location", "l", 37)
      browserCheckPhase = 102
    case 102:
      guard let presenter = commandPresenter, presenter.controller.isOpen else { return }
      presenter.controller.update(query: baseURL + "?pinned")
      presenter.controller.commit(forceNewTab: false)
      browserCheckPhase = 103
    case 103:
      guard tab.url == baseURL + "?pinned", !tab.isLoading else { return }
      guard snapshot.spaces.flatMap(\.pinned).first(where: { $0.id == browserCheckSeedID })?.url == keyboardSavedURL else { fail("pinned saved URL changed"); return }
      keyboardResults["pinned_saved"] = true
      guard let pin = snapshot.spaces.first(where: { $0.id == "default" })?.pinnedId else { fail("default pinned root"); return }
      workspace?.edit(.createFolder(id: "keyboard-folder", container: pin, index: 0)) { [weak self] in self?.showResult($0) }
      browserCheckPhase = 1031
    case 1031:
      guard snapshot.spaces.flatMap(\.pinned).contains(where: { $0.id == "keyboard-folder" }) else { return }
      workspace?.edit(.collapse(id: "keyboard-folder", collapsed: true)) { [weak self] in self?.showResult($0) }
      browserCheckPhase = 1032
    case 1032:
      guard snapshot.spaces.flatMap(\.pinned).first(where: { $0.id == "keyboard-folder" })?.collapsed == true else { return }
      openCommandBar(.newTab)
      guard let bar = commandPresenter?.controller else { fail("folder suggestion panel"); return }
      bar.commit(Suggestion(title: "Folder", subtitle: "", url: nil, key: nil, target: .folder(id: "keyboard-folder", spaceId: "default"), score: 0))
      browserCheckPhase = 1033
    case 1033:
      guard snapshot.spaces.flatMap(\.pinned).first(where: { $0.id == "keyboard-folder" })?.collapsed == false else { return }
      openCommandBar(.newTab)
      guard let bar = commandPresenter?.controller else { fail("move folder suggestion panel"); return }
      bar.commit(Suggestion(title: "Move", subtitle: "", url: nil, key: nil, target: .moveToFolder(id: "keyboard-folder", spaceId: "default"), score: 0))
      browserCheckPhase = 1034
    case 1034:
      guard snapshot.spaces.flatMap(\.pinned).first(where: { $0.id == browserCheckSeedID })?.parentId == "keyboard-folder" else { return }
      openCommandBar(.newTab)
      guard let bar = commandPresenter?.controller else { fail("move space suggestion panel"); return }
      bar.commit(Suggestion(title: "Move", subtitle: "", url: nil, key: nil, target: .moveToSpace(id: "default"), score: 0))
      browserCheckPhase = 1035
    case 1035:
      guard snapshot.spaces.flatMap(\.today).contains(where: { $0.id == browserCheckSeedID }) else { return }
      openCommandBar(.newTab)
      guard let bar = commandPresenter?.controller else { fail("restore pinned suggestion panel"); return }
      bar.commit(Suggestion(title: "Pin", subtitle: "", url: nil, key: nil, target: .command(id: "pin_tab"), score: 0))
      browserCheckPhase = 1036
    case 1036:
      guard snapshot.spaces.flatMap(\.pinned).contains(where: { $0.id == browserCheckSeedID }) else { return }
      keyboardResults["folder_and_move_suggestions"] = true
      send("back", "[", 33)
      browserCheckPhase = 104
    case 104:
      guard tab.url == baseURL + "?second", !tab.isLoading else { return }
      send("back", "[", 33)
      browserCheckPhase = 11
    case 11:
      guard tab.url == baseURL, !tab.isLoading else { return }
      keyboardResults["back"] = true
      host.checkSetFindPasteboard("ararat-find")
      send("find", "f", 3)
      browserCheckPhase = 12
    case 12:
      guard let find = container?.findBar, !find.isHidden else { return }
      guard find.field.stringValue == "ararat-find", host.checkCloseFindEnabled() else { fail("find pasteboard or command state"); return }
      keyboardResults["find_pasteboard"] = true
      if screen {
        guard let editor = find.field.currentEditor() as? NSTextView else { fail("find field focus"); return }
        editor.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let ordinal = find.ordinal
        keyboardSend(host, command: "", key: "\r", code: 36, flags: .command, screen: true)
        guard !find.isHidden, find.ordinal == ordinal else { fail("marked Command-Return changed find"); return }
        editor.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        keyboardSend(host, command: "", key: "\u{1b}", code: 53, flags: [], screen: true)
        guard !find.isHidden else { fail("marked Escape closed find"); return }
        editor.unmarkText()
        editor.selectAll(nil)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("ararat-find", forType: .string)
        keyboardSend(host, command: "", key: "v", code: 9, flags: .command, screen: true)
        keyboardResults["find_ime_escape"] = true
      } else {
        host.findAction("change", text: "ararat-find", selection: NSRange(location: 11, length: 0), liveId: tab.liveId, profile: host.profileDirectory())
      }
      keyboardFindRequest = find.requestID
      host.findAction("change", text: "ararat-no-such-match", selection: NSRange(location: 20, length: 0), liveId: tab.liveId, profile: host.profileDirectory())
      browserCheckPhase = 130
    case 130:
      guard let find = container?.findBar, find.matches == 0, find.requestID > keyboardFindRequest, find.finalUpdate else { return }
      keyboardResults["find_zero"] = true
      keyboardFindRequest = find.requestID
      host.findAction("change", text: "ararat-find", selection: NSRange(location: 11, length: 0), liveId: tab.liveId, profile: host.profileDirectory())
      browserCheckPhase = 13
    case 13:
      guard let find = container?.findBar, find.matches == 3, find.ordinal > 0, find.requestID > keyboardFindRequest, find.finalUpdate else { return }
      keyboardResults["find_count"] = find.matches
      keyboardResults["find_initial"] = find.ordinal
      host.findAction("next", text: "ararat-find", selection: NSRange(location: 11, length: 0), liveId: tab.liveId, profile: host.profileDirectory())
      browserCheckPhase = 14
    case 14:
      guard let find = container?.findBar, find.ordinal != keyboardResults["find_initial"] as? Int else { return }
      keyboardResults["find_next"] = find.ordinal
      host.findAction("previous", text: "ararat-find", selection: NSRange(location: 11, length: 0), liveId: tab.liveId, profile: host.profileDirectory())
      browserCheckPhase = 15
    case 15:
      guard let find = container?.findBar, find.ordinal == keyboardResults["find_initial"] as? Int else { return }
      if screen {
        keyboardSend(host, command: "", key: "\u{1b}", code: 53, flags: [], screen: true)
      } else {
        host.findAction("close", text: "ararat-find", selection: NSRange(location: 11, length: 0), liveId: tab.liveId, profile: host.profileDirectory())
      }
      browserCheckPhase = 150
    case 150:
      guard let find = container?.findBar, find.isHidden else { return }
      guard !host.checkCloseFindEnabled() else { fail("find command remained enabled after hide"); return }
      keyboardResults["find_visibility"] = true
      keyboardResults["find_previous"] = true
      send("find", "f", 3)
      browserCheckPhase = 151
    case 151:
      guard let find = container?.findBar, !find.isHidden else { return }
      guard find.field.stringValue == "ararat-find" else { fail("find text lost after reopen"); return }
      host.checkNavigate(baseURL + "?find-navigation", disposition: "current")
      browserCheckPhase = 152
    case 152:
      guard tab.url == baseURL + "?find-navigation", !tab.isLoading else { return }
      send("find", "f", 3)
      browserCheckPhase = 153
    case 153:
      guard let find = container?.findBar, !find.isHidden else { return }
      guard find.field.stringValue == "ararat-find" else { fail("find text lost after navigation"); return }
      host.findAction("close", text: "ararat-find", selection: NSRange(location: 11, length: 0), liveId: tab.liveId, profile: host.profileDirectory())
      keyboardResults["find_reopen_navigation"] = true
      send("back", "[", 33)
      browserCheckPhase = 154
    case 154:
      guard tab.url == baseURL, !tab.isLoading else { return }
      adapter?.openCommandURL(baseURL + "?find-second", expectedSpace: "default", profile: "Default")
      browserCheckPhase = 155
    case 155:
      guard let row = snapshot.spaces.first(where: { $0.id == "default" })?.today.first(where: { $0.url == baseURL + "?find-second" }),
            let other = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == row.id }),
            host.activeItemId() == row.id, !other.isLoading else { return }
      keyboardFindOtherItem = row.id
      guard let seed = browserCheckSeedID else { fail("tab suggestion seed"); return }
      openCommandBar(.newTab)
      guard let bar = commandPresenter?.controller else { fail("tab suggestion panel"); return }
      bar.commit(Suggestion(title: "First tab", subtitle: "", url: baseURL, key: nil, target: .tab(id: seed, spaceId: "default"), score: 0))
      browserCheckPhase = 1551
    case 1551:
      guard host.activeItemId() == browserCheckSeedID else { return }
      openCommandBar(.newTab)
      guard let bar = commandPresenter?.controller else { fail("return tab suggestion panel"); return }
      bar.commit(Suggestion(title: "Second tab", subtitle: "", url: baseURL + "?find-second", key: nil,
                            target: .tab(id: keyboardFindOtherItem, spaceId: "default"), score: 0))
      browserCheckPhase = 1552
    case 1552:
      guard host.activeItemId() == keyboardFindOtherItem else { return }
      keyboardResults["tab_suggestion"] = true
      send("find", "f", 3)
      browserCheckPhase = 156
    case 156:
      guard let other = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == keyboardFindOtherItem }),
            let find = container?.findBar, !find.isHidden else { return }
      guard find.field.stringValue == "ararat-find" else { fail("global find on new tab"); return }
      host.findAction("change", text: "stale-background", selection: NSRange(location: 16, length: 0), liveId: tab.liveId, profile: host.profileDirectory())
      guard find.field.stringValue == "ararat-find" else { fail("background find changed active field"); return }
      guard tab.checkHoldFindReply("held-background") else { fail("hold background find reply"); return }
      let held = other.checkDeliverHeldFindReply()
      guard held["alive"] as? Bool == true, held["delivered"] as? Bool == true,
            tab.checkBackgroundFindState()["matches"] as? Int == 19,
            find.field.stringValue == "ararat-find", host.activeItemId() == keyboardFindOtherItem else {
        fail("delayed background find changed active field"); return
      }
      keyboardResults["find_delayed_background"] = true
      tab.checkStartBackgroundFind("stale-background")
      browserCheckPhase = 1560
    case 1560:
      guard let other = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == keyboardFindOtherItem }),
            let find = container?.findBar else { return }
      let background = tab.checkBackgroundFindState()
      guard background["text"] as? String == "stale-background", background["final"] as? Bool == true,
            background["matches"] as? Int == 0, (background["request_id"] as? Int ?? 0) > 0 else { return }
      guard find.field.stringValue == "ararat-find", host.activeItemId() == keyboardFindOtherItem else { fail("background find result changed active field"); return }
      keyboardResults["find_background_result"] = true
      keyboardFindOtherLive = other.liveId
      guard other.checkHoldFindReply("pending-before-replace") else { fail("hold replacement find reply"); return }
      guard host.checkReplaceActiveForKeyboard() else { fail("replace find target"); return }
      browserCheckPhase = 1561
    case 1561:
      guard let other = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == keyboardFindOtherItem }),
            other.liveId == keyboardFindOtherLive, let find = container?.findBar, !tab.checkHeldFindTargetAlive() else { return }
      let replaced = tab.checkDeliverHeldFindReply()
      guard replaced["alive"] as? Bool == false, replaced["delivered"] as? Bool == false else { fail("replaced contents retained find reply"); return }
      guard !["stale-background", "pending-before-replace"].contains(find.field.stringValue) else { fail("stale find result after replacement"); return }
      keyboardResults["find_replace_guard"] = true
      if find.isHidden { send("find", "f", 3) }
      guard !find.isHidden else { fail("find not visible before tab closure"); return }
      guard other.checkHoldFindReply("pending-before-close") else { fail("hold closing find reply"); return }
      openCommandBar(.newTab)
      guard let bar = commandPresenter?.controller else { fail("close tab suggestion panel"); return }
      bar.commit(Suggestion(title: "Close Tab", subtitle: "", url: nil, key: nil, target: .command(id: "close_tab"), score: 0))
      browserCheckPhase = 158
    case 158:
      guard !(host.tabs() as? [any ARTabAPI] ?? []).contains(where: { $0.itemId == keyboardFindOtherItem }),
            host.activeItemId() == browserCheckSeedID, !tab.checkHeldFindTargetAlive() else { return }
      let text = container?.findBar.field.stringValue
      let closed = tab.checkDeliverHeldFindReply()
      guard closed["alive"] as? Bool == false, closed["delivered"] as? Bool == false else { fail("closed contents retained find reply"); return }
      guard let text, !["pending-before-close", "pending-before-replace"].contains(text) else { fail("closed tab changed find field"); return }
      keyboardResults["find_pending_teardown"] = true
      keyboardResults["suggestion_close_tab"] = true
      if container?.findBar.isHidden == false {
        host.findAction("close", text: "ararat-find", selection: NSRange(location: 0, length: 0), liveId: tab.liveId, profile: host.profileDirectory())
      }
      keyboardResults["find_tab_guard"] = true
      keyboardRead(tab, script: 2)
      browserCheckPhase = 16
    case 16:
      guard let result = keyboardScriptResult else { return }
      keyboardScriptResult = nil
      guard result == "requested" else { fail("protocol registration: \(result)"); return }
      keyboardResults["protocol_requested"] = true
      browserCheckPhase = 160
    case 160:
      let state = host.checkDevToolsState()
      keyboardResults["protocol_dialog"] = state["find_dialog_kind"]
      guard state["find_dialog_kind"] as? String == "register_protocol_handler_permission",
            tab.checkPermissionDecision(3) else { return }
      browserCheckPhase = 161
    case 161:
      guard !tab.checkPermissionPending(), !tab.checkIsDialogActive() else { return }
      host.checkExtensionAction(5)
      guard host.checkKeyboardAccelerator(false) else { fail("extension command accelerator"); return }
      browserCheckPhase = 17
    case 17:
      if let result = keyboardScriptResult {
        keyboardScriptResult = nil
        if result == "probe-command" {
          keyboardResults["extension_command"] = true
          guard host.checkKeyboardAccelerator(true) else { fail("extension action accelerator"); return }
          browserCheckPhase = 18
          return
        }
      }
      keyboardRead(tab, script: 3)
    case 18:
      let state = host.checkExtensionActionState()
      guard (state["loaded"] as? Int ?? 0) > 0 else { return }
      keyboardResults["extension_action"] = true
      host.checkExtensionAction(1)
      browserCheckPhase = 181
    case 181:
      guard (host.checkExtensionActionState()["destroyed"] as? Int ?? 0) > 0,
            !screen || host.window().isKeyWindow else { return }
      send("devtools", "i", 34, [.command, .option])
      browserCheckPhase = 19
    case 19:
      guard host.checkKeyboardDevTools() else { return }
      if screen, CommandLine.arguments.contains("--ararat-compositor=c2") {
        // Why not assert right after the open: the docked frontend becomes a hit-test target only after its first layout.
        let ready = host.checkDevToolsState()
        keyboardDevToolsReadyState = ready
        guard ready["page_hit"] as? Bool == true, ready["devtools_hit"] as? Bool == true else { return }
      }
      keyboardResults["devtools"] = true
      host.checkKeyboardCommand("find")
      guard let find = container?.findBar, !find.isHidden else { fail("find with DevTools"); return }
      let geometry = host.checkDevToolsState()
      let page = NSRectFromString(geometry["strategy_page_frame"] as? String ?? "")
      let overlay = find.convert(find.bounds, to: nil)
      guard !page.isEmpty, overlay.minX >= page.minX - 2, overlay.maxX <= page.maxX + 2,
            overlay.minY >= page.minY - 2, overlay.maxY <= page.maxY + 2 else { fail("find outside DevTools page rect"); return }
      if CommandLine.arguments.contains("--ararat-compositor=c2") {
        let presentation = host.checkPagePresentation(tab.liveId)
        guard presentation["compositor"] as? String == "c2", presentation["presented"] as? Bool == true,
              NSRectFromString(geometry["page_frame"] as? String ?? "") == page else { fail("c2 docked page geometry"); return }
        keyboardResults["c2_find_attachment"] = true
        if screen {
          let root = host.window().contentView
          let point = NSPoint(x: overlay.midX, y: overlay.midY)
          let hit = root.flatMap { root in root.superview.flatMap { root.hitTest($0.convert(point, from: nil)) } }
          let checks: [(String, Bool)] = [("page_above", geometry["page_above"] as? Bool == true),
            ("page_hit", geometry["page_hit"] as? Bool == true), ("devtools_hit", geometry["devtools_hit"] as? Bool == true),
            ("find_hit", hit?.isDescendant(of: find) == true)]
          keyboardResults["c2_find_hit_checks"] = ["failed": checks.filter { !$0.1 }.map { $0.0 },
            "results": Dictionary(uniqueKeysWithValues: checks), "point": NSStringFromPoint(point),
            "find_frame": NSStringFromRect(overlay)] as [String: Any]
          guard checks.allSatisfy({ $0.1 }) else {
            fail("c2 find stacking or input"); return
          }
          keyboardResults["c2_find_stacking_input"] = true
        }
      }
      keyboardResults["find_devtools_geometry"] = true
      let window = host.window()
      let originalFrame = window.frame
      let (resizeOK, c2ResizeOK): (Bool, Bool) = {
        defer { window.setFrame(originalFrame, display: false) }
        window.setFrame(NSRect(x: originalFrame.minX, y: originalFrame.minY, width: max(500, originalFrame.width - 120), height: originalFrame.height), display: false)
        window.contentView?.layoutSubtreeIfNeeded()
        let resized = host.checkDevToolsState()
        let resizedPage = NSRectFromString(resized["strategy_page_frame"] as? String ?? "")
        let resizedOverlay = find.convert(find.bounds, to: nil)
        let contained = window.frame != originalFrame && !resizedPage.isEmpty && resizedOverlay.minX >= resizedPage.minX - 2 && resizedOverlay.maxX <= resizedPage.maxX + 2 &&
          resizedOverlay.minY >= resizedPage.minY - 2 && resizedOverlay.maxY <= resizedPage.maxY + 2
        let c2 = !CommandLine.arguments.contains("--ararat-compositor=c2") ||
          (host.checkPagePresentation(tab.liveId)["presented"] as? Bool == true &&
           NSRectFromString(resized["page_frame"] as? String ?? "") == resizedPage)
        return (contained, c2)
      }()
      guard resizeOK else { fail("find outside resized DevTools page rect"); return }
      if CommandLine.arguments.contains("--ararat-compositor=c2") {
        guard c2ResizeOK else { fail("c2 resized page geometry"); return }
        keyboardResults["c2_find_resized_attachment"] = true
      }
      keyboardResults["find_resized_geometry"] = true
      host.findAction("close", text: "", selection: NSRange(location: 0, length: 0), liveId: tab.liveId, profile: host.profileDirectory())
      if screen {
        keyboardScriptResult = nil
        browserCheckPhase = 191
        return
      }
      send("devtools", "i", 34, [.command, .option])
      browserCheckPhase = 20
    case 191:
      if let result = keyboardScriptResult {
        keyboardScriptResult = nil
        if result.contains("\"ready\":true"), NSApp.isActive, host.window().isKeyWindow {
          guard host.checkFocusDevTools() else { return }
          keyboardSend(host, command: "", key: "f", code: 3, flags: .command, screen: true)
          browserCheckPhase = 190
          return
        }
      }
      if !keyboardScriptPending {
        keyboardScriptPending = true
        host.checkDevToolsFrontend { [weak self] value in
          MainActor.assumeIsolated { self?.keyboardScriptPending = false; self?.keyboardScriptResult = value }
        }
      }
    case 190:
      if let result = keyboardScriptResult {
        keyboardScriptResult = nil
        if result.contains("\"search\":true") && container?.findBar.isHidden == true {
          keyboardResults["devtools_find"] = true
          send("devtools", "i", 34, [.command, .option])
          browserCheckPhase = 20
          return
        }
      }
      if !keyboardScriptPending {
        keyboardScriptPending = true
        host.checkDevToolsFrontend { [weak self] value in
          MainActor.assumeIsolated { self?.keyboardScriptPending = false; self?.keyboardScriptResult = value }
        }
      }
    case 20:
      guard !host.checkKeyboardDevTools() else { return }
      send("search", "f", 3, [.command, .option])
      browserCheckPhase = 21
    case 21:
      guard let presenter = commandPresenter, presenter.controller.mode == .search else { return }
      let commit = presenter.controller.onCommit
      presenter.controller.onCommit = { row, mode, forceNew in
        guard let row, case .search(let url) = row.target,
              url == "https://www.google.com/search?q=example.com" else { return }
        let fixture = Suggestion(title: row.title, subtitle: row.subtitle, url: nil, key: nil,
          target: .search(url: "http://127.0.0.1:\(port)/search?q=example.com"), score: row.score)
        commit(fixture, mode, forceNew)
      }
      if screen {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("example.com", forType: .string)
        keyboardSend(host, command: "", key: "v", code: 9, flags: .command, screen: true)
        keyboardSend(host, command: "", key: "\r", code: 36, flags: [], screen: true)
      } else {
        presenter.controller.update(query: "example.com")
        guard let row = presenter.controller.result.rows.first else { return }
        guard case .search(let url) = row.target, url == "https://www.google.com/search?q=example.com" else {
          fail("forced search URL"); return
        }
        presenter.controller.commit(forceNewTab: false)
      }
      browserCheckPhase = 22
    case 22:
      let fixtureURL = "http://127.0.0.1:\(port)/search?q=example.com"
      guard tab.url == fixtureURL, !tab.isLoading,
            tab.checkNavigationState()["committed_url"] as? String == fixtureURL else { return }
      keyboardResults["forced_search"] = true
      send("back", "[", 33)
      browserCheckPhase = 23
    case 23:
      guard tab.url == baseURL, !tab.isLoading else { return }
      if screen {
        host.checkShowViewlessBubble(0)
        browserCheckPhase = 230
        return
      }
      keyboardRead(tab, script: 4)
      browserCheckPhase = 36
    case 230:
      let state = host.checkViewlessBubbleState()
      guard state["visible"] as? Bool == true else { return }
      let frame = NSRectFromString(state["frame"] as? String ?? "")
      guard frame.width > 0, frame.height > 0, bubbleNearAnchor(state, frame: frame),
            let bubble = NSApp.windows.first(where: { $0.isVisible && $0.frame == frame }),
            let screenshot = promptScreenScreenshot(bubble, name: "keyboard-chooser", withoutShadow: true) else { fail("chooser bubble capture"); return }
      keyboardResults["chooser_bubble"] = state
      keyboardResults["chooser_screenshot"] = screenshot
      host.checkCloseViewlessBubble()
      browserCheckPhase = 231
    case 231:
      guard host.window().isKeyWindow else { return }
      host.checkShowViewlessBubble(1)
      browserCheckPhase = 232
    case 232:
      let state = host.checkViewlessBubbleState()
      guard state["visible"] as? Bool == true else { return }
      let frame = NSRectFromString(state["frame"] as? String ?? "")
      guard frame.width > 0, frame.height > 0, bubbleNearAnchor(state, frame: frame),
            let bubble = NSApp.windows.first(where: { $0.isVisible && $0.frame == frame }),
            let screenshot = promptScreenScreenshot(bubble, name: "keyboard-restore", withoutShadow: true) else { fail("restore bubble capture"); return }
      keyboardResults["restore_bubble"] = state
      keyboardResults["restore_screenshot"] = screenshot
      host.checkCloseViewlessBubble()
      keyboardRead(tab, script: 4)
      browserCheckPhase = 36
    case 36:
      guard keyboardScriptResult == "cleared" else { return }
      keyboardScriptResult = nil
      guard let row = snapshot.spaces.first(where: { $0.id == "named" })?.today.first, row.url != nil else { fail("named profile seed"); return }
      keyboardOtherItem = row.id
      guard let workspace else { fail("named profile workspace"); return }
      keyboardSelectionMark = keyboardCommandTx
      selectionGeneration += 1
      workspace.cancelPendingSpaceSwitches()
      let generation = selectionGeneration
      browserCheckPhase = 369
      workspace.showSpaceSelectingTab(id: "named", item: row.id) { [weak self] result in
        guard let self, self.selectionGeneration == generation else { return }
        if case .failure = result { self.finishBrowserCheck(ok: false, values: ["error": "named profile setup selection"]); return }
        workspace.snapshot { [weak self] latest in
          guard let self, self.selectionGeneration == generation, case .success(let current) = latest,
                current.shownSpaceId == "named", current.selectedId == row.id else { return }
          self.adapter?.invalidateSelection()
          self.showAndSelect(.success(current), expectedSpace: "named", selectedItem: row.id)
        }
      }
    case 369:
      guard snapshot.shownSpaceId == "named", snapshot.selectedId == keyboardOtherItem,
            host.profileDirectory() == "Profile 1", host.activeItemId() == keyboardOtherItem,
            (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == keyboardOtherItem })?.isLoading == false,
            keyboardSelectionSettled(keyboardOtherItem) else { return }
      keyboardSelectionMark = keyboardCommandTx
      switchWorkspaceSpace("default")
      browserCheckPhase = 3690
    case 3690:
      guard snapshot.shownSpaceId == "default", snapshot.selectedId == browserCheckSeedID,
            host.profileDirectory() == "Default", host.activeItemId() == browserCheckSeedID,
            keyboardSelectionSettled(browserCheckSeedID) else { return }
      keyboardSelectionMark = keyboardCommandTx
      if screen { keyboardSend(host, command: "", key: "2", code: 19, flags: .control, screen: true) }
      else { performWorkspaceCommand("show_space_2") }
      browserCheckPhase = 360
    case 360:
      guard snapshot.shownSpaceId == "named", host.profileDirectory() == "Profile 1", host.activeItemId() == keyboardOtherItem,
            keyboardSelectionSettled(keyboardOtherItem) else { return }
      keyboardResults["default_space_cross_profile"] = true
      if screen { keyboardResults["core_menu_space"] = true }
      send("find", "f", 3)
      browserCheckPhase = 368
    case 368:
      guard let find = container?.findBar, !find.isHidden,
            let other = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == keyboardOtherItem }) else { return }
      guard find.field.stringValue == "ararat-find" else { fail("global find on new profile"); return }
      host.findAction("change", text: "stale-profile", selection: NSRange(location: 13, length: 0), liveId: tab.liveId, profile: "Default")
      guard find.field.stringValue == "ararat-find" else { fail("background profile changed find"); return }
      host.findAction("close", text: "ararat-find", selection: NSRange(location: 11, length: 0), liveId: other.liveId, profile: "Profile 1")
      keyboardResults["find_profile_guard"] = true
      openCommandBar(.newTab)
      guard let bar = commandPresenter?.controller else { fail("space suggestion panel"); return }
      keyboardSelectionMark = keyboardCommandTx
      bar.commit(Suggestion(title: "Default", subtitle: "", url: nil, key: nil, target: .space(id: "default"), score: 0))
      browserCheckPhase = 361
    case 361:
      guard snapshot.shownSpaceId == "default", host.profileDirectory() == "Default", host.activeItemId() == browserCheckSeedID,
            keyboardSelectionSettled(browserCheckSeedID) else { return }
      openCommandBar(.newTab)
      guard let bar = commandPresenter?.controller else { fail("space suggestion return panel"); return }
      keyboardSelectionMark = keyboardCommandTx
      bar.commit(Suggestion(title: "Named", subtitle: "", url: nil, key: nil, target: .space(id: "named"), score: 0))
      browserCheckPhase = 362
    case 362:
      guard snapshot.shownSpaceId == "named", host.profileDirectory() == "Profile 1", host.activeItemId() == keyboardOtherItem,
            keyboardSelectionSettled(keyboardOtherItem) else { return }
      keyboardResults["suggestion_space_cross_profile"] = true
      openCommandBar(.newTab)
      guard let bar = commandPresenter?.controller else { fail("show space command suggestion"); return }
      keyboardSelectionMark = keyboardCommandTx
      bar.commit(Suggestion(title: "Show Space 1", subtitle: "", url: nil, key: nil, target: .command(id: "show_space_1"), score: 0))
      browserCheckPhase = 3621
    case 3621:
      guard snapshot.shownSpaceId == "default", host.profileDirectory() == "Default", host.activeItemId() == browserCheckSeedID,
            keyboardSelectionSettled(browserCheckSeedID) else { return }
      openCommandBar(.newTab)
      guard let bar = commandPresenter?.controller else { fail("return space command suggestion"); return }
      keyboardSelectionMark = keyboardCommandTx
      bar.commit(Suggestion(title: "Show Space 2", subtitle: "", url: nil, key: nil, target: .command(id: "show_space_2"), score: 0))
      browserCheckPhase = 3622
    case 3622:
      guard snapshot.shownSpaceId == "named", host.profileDirectory() == "Profile 1", host.activeItemId() == keyboardOtherItem,
            keyboardSelectionSettled(keyboardOtherItem) else { return }
      keyboardResults["suggestion_space_commands"] = true
      adapter?.openCommandURL(baseURL + "?restore", expectedSpace: "named", profile: "Profile 1")
      browserCheckPhase = 363
    case 363:
      guard let row = snapshot.spaces.first(where: { $0.id == "named" })?.today.first(where: { $0.url == baseURL + "?restore" }),
            host.activeItemId() == row.id else { return }
      keyboardRestoreItem = row.id
      keyboardLibraryDeleteItem = ""
      // p4checks: a second archived row, so the Library's own delete button has one to remove.
      workspace?.createTab(url: "data:text/html,<title>keyboard delete row</title>") { [weak self] result in
        guard let self else { return }
        guard case .success(let created) = result, let id = created.selectedId else { return }
        self.keyboardLibraryDeleteItem = id
        self.adapter?.close(id: id, archive: true)
        self.adapter?.close(id: row.id, archive: true)
        self.browserCheckPhase = 364
      }
      browserCheckPhase = 100
    case 364:
      guard snapshot.archive.contains(where: { $0.id == keyboardRestoreItem }),
            !keyboardLibraryDeleteItem.isEmpty,
            snapshot.archive.contains(where: { $0.id == keyboardLibraryDeleteItem }),
            !(host.tabs() as? [any ARTabAPI] ?? []).contains(where: { $0.itemId == keyboardRestoreItem }),
            !(host.tabs() as? [any ARTabAPI] ?? []).contains(where: { $0.itemId == keyboardLibraryDeleteItem }) else { return }
      // Leaving the item's space first makes the restore prove it selects and shows it.
      switchWorkspaceSpace("default")
      browserCheckPhase = 3641
    case 3641:
      guard snapshot.shownSpaceId == "default", host.profileDirectory() == "Default" else { return }
      guard let sidebar, !sidebar.libraryOpen else { return }
      sidebar.setLibraryOpen(true)
      browserCheckPhase = 3642
    case 3642:
      guard let sidebar, sidebar.libraryOpen, !keyboardLibraryDeleteItem.isEmpty else { return }
      // The Library row's own delete button: the closure the app wires to deleteArchive.
      guard sidebar.checkPressArchiveRowButton(id: keyboardLibraryDeleteItem, restore: false) else {
        keyboardResults["library_delete_press"] = false
        browserCheckPhase = 3643
        return
      }
      browserCheckPhase = 3643
    case 3643:
      guard let sidebar else { return }
      let archived = snapshot.archive.contains { $0.id == keyboardLibraryDeleteItem }
      let listed = sidebar.checkLibraryRowPresent(id: keyboardLibraryDeleteItem)
      if archived || listed {
        if keyboardRowWaited < 60 { keyboardRowWaited += 1; return }
        keyboardResults["library_delete_press"] = false
      } else {
        keyboardResults["library_delete_press"] = true
      }
      keyboardRowWaited = 0
      // The archive row's own restore control; the app's A3 completion closes the Library and
      // moves the sidebar to the item's space.
      guard sidebar.checkPressArchiveRowButton(id: keyboardRestoreItem, restore: true) else {
        keyboardResults["library_restore_press"] = false
        browserCheckPhase = 365
        return
      }
      browserCheckPhase = 365
    case 365:
      guard let sidebar else { return }
      let ready = snapshot.selectedId == keyboardRestoreItem && host.activeItemId() == keyboardRestoreItem
        && (host.tabs() as? [any ARTabAPI] ?? []).contains { $0.itemId == keyboardRestoreItem && $0.url == baseURL + "?restore" }
      if !ready {
        if keyboardRestoreWaited < 120 { keyboardRestoreWaited += 1; return }
        keyboardResults["archive_restore"] = false
        browserCheckPhase = 366
        return
      }
      keyboardResults["archive_restore"] = true
      // A3: the restore's own completion closes the Library, shows the item's space and selects
      // the row. The restore alone (above) does not.
      let libraryClosed = !sidebar.libraryOpen
      let spaceShown = snapshot.shownSpaceId == "named" && sidebar.spaceShown == snapshot.spaces.firstIndex { $0.id == "named" }
      let rowSelected = sidebar.selectedRowID == keyboardRestoreItem
      keyboardResults["library_restore_press"] = libraryClosed && spaceShown && rowSelected
        && (keyboardResults["library_delete_press"] as? Bool) == true
      keyboardRestoreWaited = 0
      adapter?.close(id: keyboardRestoreItem, archive: false)
      browserCheckPhase = 366
    case 366:
      guard !(host.tabs() as? [any ARTabAPI] ?? []).contains(where: { $0.itemId == keyboardRestoreItem }),
            host.activeItemId() == keyboardOtherItem else { return }
      browserCheckPhase = 40
    case 24:
      guard host.tabs().count == 2, let selected = snapshot.selectedId, selected != browserCheckSeedID else { return }
      keyboardResults["duplicate"] = true
      host.checkKeyboardCommand("close")
      browserCheckPhase = 25
    case 25:
      guard host.tabs().count == 1, host.activeItemId() == browserCheckSeedID else { return }
      if screen {
        guard NSApp.isActive, host.window().isKeyWindow else { return }
        tab.focusCheckPage()
        guard host.checkFullscreenState()["view_focused"] as? Bool == true else { return }
      }
      keyboardResults["close"] = true
      resetFullscreenProbe()
      tab.checkFullscreenRequest(true)
      browserCheckPhase = 26
    case 26:
      probeFullscreen(tab)
      let state = host.checkFullscreenState()
      guard fullscreenElement == true, state["tab"] as? Bool == true,
            state["window"] as? Bool == true, state["transitioning"] as? Bool == false,
            !screen || (NSApp.isActive && host.window().isKeyWindow) else { return }
      send("new", "t", 17)
      browserCheckPhase = 27
    case 27:
      guard let presenter = commandPresenter, presenter.controller.isOpen else { return }
      keyboardResults["fullscreen_new"] = true
      if screen {
        guard let editor = presenter.view.field.currentEditor() as? NSTextView else { fail("fullscreen command field focus"); return }
        editor.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        keyboardSend(host, command: "", key: "\u{1b}", code: 53, flags: [], screen: true)
        guard presenter.controller.isOpen, host.checkFullscreenState()["tab"] as? Bool == true else { fail("fullscreen marked command Escape"); return }
        editor.unmarkText()
        keyboardResults["fullscreen_command_marked_escape"] = true
        keyboardSend(host, command: "", key: "\u{1b}", code: 53, flags: [], screen: true)
      }
      else { presenter.close() }
      resetFullscreenProbe()
      browserCheckPhase = 28
    case 28:
      probeFullscreen(tab)
      guard fullscreenElement == true, commandPresenter == nil else { return }
      send("location", "l", 37)
      browserCheckPhase = 29
    case 29:
      guard let presenter = commandPresenter, presenter.controller.isOpen else { return }
      keyboardResults["fullscreen_location"] = true
      if screen { keyboardSend(host, command: "", key: "\u{1b}", code: 53, flags: [], screen: true) }
      else { presenter.close() }
      resetFullscreenProbe()
      browserCheckPhase = 30
    case 30:
      probeFullscreen(tab)
      guard fullscreenElement == true, commandPresenter == nil else { return }
      send("find", "f", 3)
      browserCheckPhase = 31
    case 31:
      guard let find = container?.findBar, !find.isHidden else { return }
      if screen {
        guard let editor = find.field.currentEditor() as? NSTextView else { fail("fullscreen find focus"); return }
        editor.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        keyboardSend(host, command: "", key: "\u{1b}", code: 53, flags: [], screen: true)
        guard !find.isHidden, host.checkFullscreenState()["tab"] as? Bool == true else { fail("fullscreen marked find Escape"); return }
        editor.unmarkText()
        keyboardResults["fullscreen_find_marked_escape"] = true
        keyboardSend(host, command: "", key: "\u{1b}", code: 53, flags: [], screen: true)
      }
      else { host.findAction("close", text: "", selection: NSRange(location: 0, length: 0), liveId: tab.liveId, profile: host.profileDirectory()) }
      resetFullscreenProbe()
      browserCheckPhase = 32
    case 32:
      probeFullscreen(tab)
      guard fullscreenElement == true, container?.findBar.isHidden == true else { return }
      keyboardResults["fullscreen_find_dismissed"] = true
      if screen {
        tab.focusCheckPage()
        keyboardSend(host, command: "", key: "\u{1b}", code: 53, flags: [], screen: true)
      } else { host.checkFullscreenAction(0) }
      resetFullscreenProbe()
      browserCheckPhase = 33
    case 33:
      probeFullscreen(tab)
      let fullscreenState = host.checkFullscreenState()
      guard fullscreenElement == false, fullscreenState["transitioning"] as? Bool == false,
            fullscreenState["window"] as? Bool == false else { return }
      if screen {
        guard NSApp.isActive, host.window().isKeyWindow else { return }
        tab.focusCheckPage()
        guard host.checkFullscreenState()["view_focused"] as? Bool == true else { return }
      }
      keyboardResults["fullscreen_page_escape"] = true
      resetFullscreenProbe()
      tab.checkFullscreenRequest(true)
      browserCheckPhase = 34
    case 34:
      probeFullscreen(tab)
      let state = host.checkFullscreenState()
      guard fullscreenElement == true, state["tab"] as? Bool == true,
            state["window"] as? Bool == true, state["transitioning"] as? Bool == false,
            !screen || (NSApp.isActive && host.window().isKeyWindow) else { return }
      send("close", "w", 13)
      browserCheckPhase = 35
    default: break
    }
  }

  func commandSpaceMatrixTick(_ host: any ARWindowHostAPI, screen: Bool) {
    guard let adapter else { return }
    if spaceMatrixPhase == 0 {
      do {
        let seeded = try adapter.session.queue.sync { () -> (WorkspaceSnapshot, [MatrixTarget]) in
          guard let store = adapter.session.store else { throw NSError(domain: "Ararat.space-matrix", code: 1) }
          let initial = store.snapshot(windowId: windowID)
          guard initial.spaces.map(\.id) == ["default", "named"] else { throw NSError(domain: "Ararat.space-matrix", code: 2) }
          var targets: [MatrixTarget] = []
          for space in initial.spaces {
            let rows = (space.today + space.pinned + space.favorites).filter { $0.url != nil }
            guard rows.count == 1, let row = rows.first, let url = row.url else { throw NSError(domain: "Ararat.space-matrix", code: 3) }
            targets.append(MatrixTarget(space: space.id, item: row.id, profile: space.profileName, url: url))
          }
          for number in 3...9 {
            _ = try store.createSpace(windowId: windowID, name: "Matrix \(number)", spaceId: "matrix-\(number)")
            let created = try store.createTab(windowId: windowID, url: "about:blank?matrix=\(number)")
            guard let space = created.spaces.first(where: { $0.id == "matrix-\(number)" }),
                  (space.today + space.pinned + space.favorites).filter({ $0.url != nil }).count == 1,
                  let id = created.selectedId, let row = space.today.first(where: { $0.id == id }), let url = row.url else {
              throw NSError(domain: "Ararat.space-matrix", code: 4)
            }
            targets.append(MatrixTarget(space: space.id, item: id, profile: space.profileName, url: url))
          }
          return (store.snapshot(windowId: windowID), targets)
        }
        guard seeded.0.spaces.map(\.id) == seeded.1.map(\.space), seeded.1.count == 9,
              Set(seeded.1.map(\.item)).count == 9 else {
          finishBrowserCheck(ok: false, values: ["space_matrix_setup": false]); return
        }
        matrixTargets = seeded.1
        spaceMatrixIDs = seeded.0.spaces.map(\.id)
        spaceMatrixSetup = Self.matrixSnapshotDiagnostics(seeded.0)
        adapter.refresh()
        spaceMatrixPhase = 9
      } catch { finishBrowserCheck(ok: false, values: ["space_matrix_setup_error": "\(error)"]) }
      return
    }
    guard spaceMatrixIDs.count == 9 else { return }
    if (6...8).contains(spaceMatrixPhase) {
      let afterClose = spaceMatrixPhase == 8 && spaceMatrixCommandIndex == 10
      let retained = matrixRetained(host, excluding: afterClose ? matrixTargets.last?.item : nil)
      let current = afterClose || (matrixTargets.indices.contains(8) && matrixTargets[8].live.map {
        matrixCurrentTargetReady(host, index: 8, live: $0)
      } == true)
      guard !matrixCommandInvariantFailed, retained, current else {
        matrixCommandInvariantFailed = true
        return
      }
    }
    if spaceMatrixPhase == 9 {
      guard let workspace, matrixTargets.indices.contains(matrixSetupIndex), hasUsableHost else { return }
      let target = matrixTargets[matrixSetupIndex]
      matrixCommand = nil
      matrixAcknowledgedLive = nil
      matrixAcknowledgedEpoch = nil
      selectionGeneration += 1
      workspace.cancelPendingSpaceSwitches()
      let generation = selectionGeneration
      matrixSetupGeneration = generation
      adapter.checkSelectionCommand = { [weak self] item, command, opens in
        guard let self, self.spaceMatrixPhase == 10, self.selectionGeneration == generation,
              self.hasUsableHost, item == target.item else { return }
        self.matrixCommand = command
        self.matrixCommandOpens = opens
      }
      spaceMatrixPhase = 10
      workspace.showSpaceSelectingTab(id: target.space, item: target.item) { [weak self] result in
        guard let self, self.selectionGeneration == generation, self.hasUsableHost,
              case .success = result else { return }
        workspace.snapshot { [weak self] latest in
          guard let self, self.selectionGeneration == generation, self.hasUsableHost,
                case .success(let current) = latest, current.shownSpaceId == target.space,
                current.selectedId == target.item else { return }
          adapter.invalidateSelection()
          self.showAndSelect(.success(current), expectedSpace: target.space, selectedItem: target.item)
          if let index = current.spaces.firstIndex(where: { $0.id == target.space }) {
            self.sidebar?.showSpaceWithoutNotification(at: index)
          }
        }
      }
    } else if spaceMatrixPhase == 10 {
      guard selectionGeneration == matrixSetupGeneration, hasUsableHost, !matrixEpochChanged,
            let live = matrixAcknowledgedLive, matrixCurrentTargetReady(host, index: matrixSetupIndex, live: live) else { return }
      if matrixReturning {
        guard matrixTargets[matrixSetupIndex].live == live, matrixRetained(host) else { return }
        adapter.checkSelectionCommand = nil
        spaceMatrixPhase = 1
      } else {
        matrixTargets[matrixSetupIndex].live = live
        if matrixSetupIndex < 8 { matrixSetupIndex += 1; spaceMatrixPhase = 9 }
        else {
          guard matrixRetained(host) else { return }
          matrixReturning = true
          matrixCommand = nil
          matrixAcknowledgedLive = nil
          matrixAcknowledgedEpoch = nil
          let generation = selectionGeneration + 1
          matrixSetupGeneration = generation
          adapter.checkSelectionCommand = { [weak self] item, command, opens in
            guard let self, self.spaceMatrixPhase == 10, self.selectionGeneration == generation,
                  self.hasUsableHost, item == self.matrixTargets[8].item else { return }
            self.matrixCommand = command
            self.matrixCommandOpens = opens
          }
          switchWorkspaceSpace(matrixTargets[8].space)
        }
      }
    } else if spaceMatrixPhase == 1 {
      guard matrixRetained(host), let live = matrixTargets[8].live,
            matrixCurrentTargetReady(host, index: 8, live: live) else { return }
      openCommandBar(.newTab)
      guard matrixPanelIsSafe(host, screen: screen), let bar = commandPresenter?.controller else { finishBrowserCheck(ok: false, values: ["space_matrix_panel": false]); return }
      bar.update(query: "Show Space \(spaceMatrixNumber)")
      spaceMatrixPhase = 2
    } else if spaceMatrixPhase == 2, let bar = commandPresenter?.controller, bar.isOpen {
      let expected = "show_space_\(spaceMatrixNumber)"
      guard let index = bar.result.rows.firstIndex(where: { row in
        if case .command(let id) = row.target { return id == expected }
        return false
      }) else { return }
      bar.moveSelection(by: index - bar.selectedIndex)
      bar.commit(forceNewTab: false)
      spaceMatrixPhase = 3
    } else if spaceMatrixPhase == 3 {
      guard matrixRetained(host), spaceMatrixTargetIsDisplayed(host) else { return }
      spaceMatrixSuggestionPassed.append(spaceMatrixNumber)
      if spaceMatrixNumber < 9 {
        spaceMatrixNumber += 1
        openCommandBar(.newTab)
        guard matrixPanelIsSafe(host, screen: screen), let bar = commandPresenter?.controller else { finishBrowserCheck(ok: false, values: ["space_matrix_panel": false]); return }
        bar.update(query: "Show Space \(spaceMatrixNumber)")
        spaceMatrixPhase = 2
      } else if screen {
        spaceMatrixNumber = 1
        spaceMatrixPhase = 4
      } else { spaceMatrixPhase = 6 }
    } else if spaceMatrixPhase == 4 {
      guard host.window().isKeyWindow else { return }
      let codes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
      keyboardSend(host, command: "", key: "\(spaceMatrixNumber)", code: codes[spaceMatrixNumber - 1], flags: .control, screen: true)
      spaceMatrixPhase = 5
    } else if spaceMatrixPhase == 5 {
      guard matrixRetained(host), spaceMatrixTargetIsDisplayed(host) else { return }
      spaceMatrixMenuPassed.append(spaceMatrixNumber)
      if spaceMatrixNumber < 9 { spaceMatrixNumber += 1; spaceMatrixPhase = 4 }
      else { spaceMatrixPhase = 6 }
    } else if spaceMatrixPhase == 6 {
      let commands = ["new_tab", "edit_url", "toggle_sidebar", "toggle_sidebar", "toggle_library", "toggle_library", "reset_sidebar_width", "pin_tab", "pin_tab", "settings", "close_tab"]
      guard commands.indices.contains(spaceMatrixCommandIndex), let container, let sidebar,
            let binding = defaultKeyBindings().first(where: { $0.command == commands[spaceMatrixCommandIndex] }) else {
        finishBrowserCheck(ok: false, values: ["command_matrix_setup": false]); return
      }
      spaceMatrixSidebarBefore = container.sidebarState
      spaceMatrixLibraryBefore = sidebar.libraryOpen
      spaceMatrixBeforeRows = captureCheckRows()
      spaceMatrixBeforeTabCount = host.tabs().count
      spaceMatrixBeforeSelected = snapshot.selectedId
      guard spaceMatrixBeforeRows != nil else { return }
      if binding.command == "reset_sidebar_width" {
        container.resizeHandle.resetWidth()
        spaceMatrixDefaultWidth = container.resizeHandle.sidebarWidth
        container.resizeHandle.sidebarWidth = spaceMatrixDefaultWidth + 40
      }
      if binding.command == "pin_tab" || binding.command == "close_tab" {
        guard let item = snapshot.selectedId, let active = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == item }) else { return }
        spaceMatrixCommandItem = item
        spaceMatrixCommandLive = active.liveId
        spaceMatrixWasPinned = snapshot.spaces.flatMap(\.pinned).contains(where: { $0.id == item })
      }
      openCommandBar(.newTab)
      guard matrixPanelIsSafe(host, screen: screen), let bar = commandPresenter?.controller else { finishBrowserCheck(ok: false, values: ["space_matrix_panel": false]); return }
      bar.update(query: binding.title)
      spaceMatrixPhase = 7
    } else if spaceMatrixPhase == 7, let bar = commandPresenter?.controller, bar.isOpen {
      let commands = ["new_tab", "edit_url", "toggle_sidebar", "toggle_sidebar", "toggle_library", "toggle_library", "reset_sidebar_width", "pin_tab", "pin_tab", "settings", "close_tab"]
      let expected = commands[spaceMatrixCommandIndex]
      guard let index = bar.result.rows.firstIndex(where: { row in
        if case .command(let id) = row.target { return id == expected }
        return false
      }) else { return }
      bar.moveSelection(by: index - bar.selectedIndex)
      bar.commit(forceNewTab: false)
      spaceMatrixPhase = 8
    } else if spaceMatrixPhase == 8 {
      let commands = ["new_tab", "edit_url", "toggle_sidebar", "toggle_sidebar", "toggle_library", "toggle_library", "reset_sidebar_width", "pin_tab", "pin_tab", "settings", "close_tab"]
      let command = commands[spaceMatrixCommandIndex]
      guard let container, let sidebar else { return }
      switch command {
      case "new_tab", "edit_url":
        guard let presenter = commandPresenter, presenter.controller.isOpen,
              presenter.controller.mode == (command == "new_tab" ? .newTab : .editURL) else { return }
        guard matrixPanelIsSafe(host, screen: screen) else { finishBrowserCheck(ok: false, values: ["space_matrix_panel": false]); return }
        guard host.tabs().count == spaceMatrixBeforeTabCount, snapshot.selectedId == spaceMatrixBeforeSelected,
              host.activeItemId() == spaceMatrixBeforeSelected, captureCheckRows() == spaceMatrixBeforeRows else {
          finishBrowserCheck(ok: false, values: ["command_matrix_unexpected_tab": command]); return
        }
        presenter.close()
      case "toggle_sidebar": guard container.sidebarState != spaceMatrixSidebarBefore else { return }
      case "toggle_library": guard sidebar.libraryOpen != spaceMatrixLibraryBefore else { return }
      case "reset_sidebar_width": guard container.resizeHandle.sidebarWidth == spaceMatrixDefaultWidth else { return }
      case "pin_tab":
        guard snapshot.spaces.flatMap(\.pinned).contains(where: { $0.id == spaceMatrixCommandItem }) != spaceMatrixWasPinned,
              host.activeItemId() == spaceMatrixCommandItem,
              (host.tabs() as? [any ARTabAPI])?.contains(where: { $0.itemId == spaceMatrixCommandItem && $0.liveId == spaceMatrixCommandLive }) == true else { return }
      case "settings":
        guard let owner = (root ?? self).settings, let window = owner.window,
              screen ? window.isVisible : (!window.isVisible && !window.isKeyWindow) else { return }
        guard host.tabs().count == spaceMatrixBeforeTabCount, snapshot.selectedId == spaceMatrixBeforeSelected,
              host.activeItemId() == spaceMatrixBeforeSelected, captureCheckRows() == spaceMatrixBeforeRows else {
          finishBrowserCheck(ok: false, values: ["command_matrix_settings_mutated_workspace": true]); return
        }
        if screen { window.orderOut(nil); host.window().makeKeyAndOrderFront(nil) }
      case "close_tab":
        guard !(host.tabs() as? [any ARTabAPI] ?? []).contains(where: { $0.liveId == spaceMatrixCommandLive }),
              snapshot.selectedId != spaceMatrixCommandItem else { return }
      default: return
      }
      spaceMatrixCommandsPassed.append(command)
      spaceMatrixCommandIndex += 1
      if spaceMatrixCommandIndex == commands.count { finishSpaceMatrix(host, screen: screen) }
      else { spaceMatrixPhase = 6 }
    }
  }

  static func matrixSnapshotDiagnostics(_ value: WorkspaceSnapshot) -> [String: Any] {
    ["shown": value.shownSpaceId ?? "", "selected": value.selectedId ?? "",
     "spaces": value.spaces.prefix(12).map { space in
       ["id": space.id, "profile": space.profileName, "rows": (space.today + space.pinned + space.favorites).prefix(32).map {
         ["id": $0.id, "url": $0.url ?? "", "unloaded": $0.unloaded] as [String: Any]
       }] as [String: Any]
     }, "space_count": value.spaces.count]
  }

  func matrixDiagnostics() -> [String: Any] {
    let target = [9, 10].contains(spaceMatrixPhase) && matrixTargets.indices.contains(matrixSetupIndex) ? matrixTargets[matrixSetupIndex].space :
      spaceMatrixPhase == 1 ? (spaceMatrixIDs.last ?? "") :
      (spaceMatrixIDs.indices.contains(spaceMatrixNumber - 1) ? spaceMatrixIDs[spaceMatrixNumber - 1] : "")
    let waiting = [0: "setup", 1: "last_space_and_active", 2: "space_suggestion", 3: "space_presentation",
                   4: "screen_window_key", 5: "screen_space_presentation", 6: "command_setup",
                   7: "command_suggestion", 8: "command_effect", 9: "fixture_dispatch", 10: "fixture_completion_and_presentation"]
    var result: [String: Any] = ["phase": spaceMatrixPhase, "number": spaceMatrixNumber, "target_space": target,
      "waiting_for": waiting[spaceMatrixPhase] ?? "unknown",
      "ids": spaceMatrixIDs, "suggestions_passed": spaceMatrixSuggestionPassed, "menu_passed": spaceMatrixMenuPassed,
      "command_index": spaceMatrixCommandIndex, "commands_passed": spaceMatrixCommandsPassed,
      "setup": spaceMatrixSetup, "ui": Self.matrixSnapshotDiagnostics(snapshot),
      "last_transaction": spaceMatrixLastTransaction, "transaction_count": sliceTransactions,
      "last_transaction_rev": sliceLastRev, "transaction_active": sliceActive ?? ""]
    result["fixture"] = ["index": matrixSetupIndex + 1, "returning": matrixReturning,
      "generation": matrixSetupGeneration, "current_generation": selectionGeneration,
      "command": matrixCommand ?? "", "opens": matrixCommandOpens, "ack_live": matrixAcknowledgedLive ?? "",
      "ack_epoch": matrixAcknowledgedEpoch as Any? ?? NSNull(),
      "epoch_changed": matrixEpochChanged,
      "command_invariant_failed": matrixCommandInvariantFailed,
      "targets": matrixTargets.map { ["space": $0.space, "item": $0.item, "profile": $0.profile, "live": $0.live ?? ""] }]
    if let adapter {
      result["selection"] = adapter.checkSelectionState()
      let storeState: [String: Any]? = adapter.session.queue.sync {
        guard let store = adapter.session.store else { return nil }
        let current = store.snapshot(windowId: windowID)
        let selected = current.selectedId
        let targetItems = current.spaces.first(where: { $0.id == target }).map { Array(($0.today + $0.pinned + $0.favorites).prefix(32)) } ?? []
        return ["snapshot": Self.matrixSnapshotDiagnostics(current),
                "selected_live": selected.flatMap { store.liveTab(item: $0) } as Any? ?? NSNull(),
                "target_mappings": Dictionary(uniqueKeysWithValues: Set(targetItems.map(\.id)).sorted().compactMap {
                  item in store.liveTab(item: item).map { (item, $0) }
                })]
      }
      result["store"] = storeState as Any? ?? NSNull()
    }
    if let host {
      let tabs = (host.tabs() as? [any ARTabAPI] ?? [])
      result["native"] = ["profile": host.profileDirectory(), "active": host.activeItemId() ?? "",
        "has_active": host.hasActiveTab(), "tabs": tabs.prefix(32).map {
          ["live": $0.liveId, "item": $0.itemId ?? "", "loading": $0.isLoading, "url": $0.url] as [String: Any]
        }]
      if let activeID = host.activeItemId(), let active = tabs.first(where: { $0.itemId == activeID }) {
        result["presentation"] = host.checkPagePresentation(active.liveId)
      }
    }
    if let bar = commandPresenter?.controller {
      result["panel"] = ["open": bar.isOpen, "selected_index": bar.selectedIndex,
                         "rows": bar.result.rows.prefix(32).map { String(describing: $0.target) }]
    }
    return result
  }

  func matrixPanelIsSafe(_ host: any ARWindowHostAPI, screen: Bool) -> Bool {
    guard let presenter = commandPresenter, presenter.controller.isOpen else { return false }
    return screen || (!presenter.panel.isVisible && !presenter.panel.isKeyWindow && presenter.panel.parent == nil &&
      !host.window().isVisible && !host.window().isKeyWindow)
  }

  func spaceMatrixTargetIsDisplayed(_ host: any ARWindowHostAPI) -> Bool {
    let index = spaceMatrixNumber - 1
    guard matrixTargets.indices.contains(index), let live = matrixTargets[index].live else { return false }
    return matrixCurrentTargetReady(host, index: index, live: live)
  }

  static func matrixAcceptedLive(_ transaction: LiveTransaction, applied: Bool, command: String, window: String, target: MatrixTarget) -> String? {
    guard applied, case .command(let actual) = transaction.cause, actual == command else { return nil }
    for strip in transaction.strips where strip.window == window {
      for tab in strip.tabs where tab.item == target.item && strip.active == tab.liveId {
        let profile: String
        switch tab.profile { case .default: profile = "Default"; case .named(let name): profile = name }
        if profile == target.profile { return tab.liveId }
      }
    }
    return nil
  }

  func recordMatrixTransaction(_ transaction: LiveTransaction, applied: Bool, usableHost: Bool) {
    if applied, let epoch = matrixEpoch, epoch != transaction.epoch { matrixEpochChanged = true }
    guard spaceMatrixPhase == 10, selectionGeneration == matrixSetupGeneration, usableHost,
          matrixTargets.indices.contains(matrixSetupIndex), let command = matrixCommand,
          let live = Self.matrixAcceptedLive(transaction, applied: applied, command: command,
              window: windowID, target: matrixTargets[matrixSetupIndex]),
          !matrixCommandOpens || live == command else { return }
    matrixAcknowledgedLive = live
    matrixAcknowledgedEpoch = transaction.epoch
    if matrixEpoch == nil { matrixEpoch = transaction.epoch }
  }

  func matrixCurrentTargetReady(_ host: any ARWindowHostAPI, index: Int, live: String) -> Bool {
    guard matrixTargets.indices.contains(index), let adapter else { return false }
    let target = matrixTargets[index]
    let tabs = host.tabs() as? [any ARTabAPI] ?? []
    guard snapshot.shownSpaceId == target.space, snapshot.selectedId == target.item,
          host.profileDirectory() == target.profile, host.activeItemId() == target.item,
          tabs.filter({ $0.itemId == target.item }).count == 1,
          tabs.filter({ $0.liveId == live }).count == 1,
          let tab = tabs.first(where: { $0.itemId == target.item && $0.liveId == live }), !tab.isLoading,
          adapter.session.queue.sync(execute: {
            guard let store = adapter.session.store else { return false }
            let current = store.snapshot(windowId: windowID)
            guard current.shownSpaceId == target.space, current.selectedId == target.item,
                  let space = current.spaces.first(where: { $0.id == target.space }), space.profileName == target.profile,
                  let row = (space.today + space.pinned + space.favorites).first(where: { $0.id == target.item }),
                  !row.unloaded, row.url == target.url,
                  store.liveTab(item: target.item) == live, store.itemForLive(liveId: live) == target.item,
                  let profile = store.itemProfile(itemId: target.item) else { return false }
            switch profile { case .default: return target.profile == "Default"; case .named(let name): return name == target.profile }
          }) else { return false }
    let state = host.checkPagePresentation(live)
    return Self.matrixPagePresented(state, live: live, c2: CommandLine.arguments.contains("--ararat-compositor=c2"),
                                    screen: browserCheckMode == "screen-keyboard")
  }

  static func matrixPagePresented(_ state: [String: Any], live: String, c2: Bool, screen: Bool) -> Bool {
    guard state["live"] as? String == live, state["target"] as? Bool == true,
          state["presented"] as? Bool == true else { return false }
    return !c2 || (state["compositor"] as? String == "c2" && state["window"] as? Bool == true &&
      state["bounds"] as? Bool == true && (!screen || state["page_hit"] as? Bool == true))
  }

  func matrixRetained(_ host: any ARWindowHostAPI, excluding item: String? = nil) -> Bool {
    guard matrixTargets.count == 9, !matrixEpochChanged, let adapter else { return false }
    let tabs = host.tabs() as? [any ARTabAPI] ?? []
    return adapter.session.queue.sync {
      guard let store = adapter.session.store else { return false }
      let current = store.snapshot(windowId: windowID)
      for target in matrixTargets {
        if target.item == item { continue }
        guard let live = target.live,
              tabs.filter({ $0.itemId == target.item }).count == 1,
              tabs.filter({ $0.liveId == live }).count == 1,
              tabs.contains(where: { $0.itemId == target.item && $0.liveId == live }),
              let space = current.spaces.first(where: { $0.id == target.space }), space.profileName == target.profile,
              let row = (space.today + space.pinned + space.favorites).first(where: { $0.id == target.item }),
              !row.unloaded, row.url == target.url,
              store.liveTab(item: target.item) == live, store.itemForLive(liveId: live) == target.item,
              let profile = store.itemProfile(itemId: target.item) else { return false }
        switch profile { case .default: if target.profile != "Default" { return false }
                         case .named(let name): if name != target.profile { return false } }
      }
      return true
    }
  }

  func matrixFinalValid(_ host: any ARWindowHostAPI) -> Bool {
    guard !matrixCommandInvariantFailed, !matrixEpochChanged, matrixTargets.count == 9,
          let target = matrixTargets.last, let live = target.live, let adapter,
          matrixRetained(host, excluding: target.item), snapshot.selectedId != target.item,
          !(host.tabs() as? [any ARTabAPI] ?? []).contains(where: { $0.itemId == target.item || $0.liveId == live }) else { return false }
    return adapter.session.queue.sync {
      guard let store = adapter.session.store else { return false }
      return store.snapshot(windowId: windowID).selectedId != target.item &&
        store.liveTab(item: target.item) == nil && store.itemForLive(liveId: live) == nil
    }
  }

  func finishSpaceMatrix(_ host: any ARWindowHostAPI, screen: Bool) {
    let expected = Array(1...9)
    let expectedCommands = ["new_tab", "edit_url", "toggle_sidebar", "toggle_sidebar", "toggle_library", "toggle_library", "reset_sidebar_width", "pin_tab", "pin_tab", "settings", "close_tab"]
    let finalValid = matrixFinalValid(host)
    let stock = host.checkStockBrowsers()
    let hiddenSafe = screen || hiddenPopupSafe()
    let checks: [(String, Bool)] = [("matrix_final", finalValid),
      ("suggestions", spaceMatrixSuggestionPassed == expected), ("menu", !screen || spaceMatrixMenuPassed == expected),
      ("indexed_commands", spaceMatrixCommandsPassed == expectedCommands), ("stock_browsers", stock == 0), ("hidden_safety", hiddenSafe)]
    let passed = checks.allSatisfy { $0.1 }
    let target = matrixTargets.last
    let live = target?.live
    let storeState: [String: Any] = adapter?.session.queue.sync {
      guard let store = adapter?.session.store else { return ["available": false] }
      return ["available": true, "selected": store.snapshot(windowId: windowID).selectedId ?? "",
              "target_live": target.flatMap { store.liveTab(item: $0.item) } ?? "",
              "live_item": live.flatMap { store.itemForLive(liveId: $0) } ?? ""]
    } ?? ["available": false]
    let finalValues: [String: Any] = ["invariant_failed": matrixCommandInvariantFailed, "epoch_changed": matrixEpochChanged,
      "target_count": matrixTargets.count, "expected_target_count": 9, "target_item": target?.item ?? "", "target_live": live ?? "",
      "retained": target.map { matrixRetained(host, excluding: $0.item) } ?? false,
      "snapshot_selected": snapshot.selectedId ?? "", "tabs": (host.tabs() as? [any ARTabAPI] ?? []).map { ["item": $0.itemId ?? "", "live": $0.liveId] },
      "store": storeState]
    finishBrowserCheck(ok: passed, values: ["case": "space-command-matrix", "u16_complete": false,
      "observed_direction": (host.checkPagePresentation("")["rtl"] as? Bool).map { $0 ? "rtl" : "ltr" } as Any? ?? NSNull(),
      "space_matrix_suggestion": spaceMatrixSuggestionPassed,
      "space_matrix_menu": spaceMatrixMenuPassed, "indexed_commands": spaceMatrixCommandsPassed,
      "failed_assertions": checks.filter { !$0.1 }.map { $0.0 }, "matrix_final_values": finalValues,
      "expected_suggestions": expected, "expected_menu": screen ? expected : [], "expected_commands": expectedCommands,
      "stock_browsers_final": stock, "hidden_safety": hiddenSafe,
      "front_before_final": popupFrontBefore ?? "", "front_after_final": checkFrontApplication() ?? "",
      "front_change_final": popupFrontChange ?? [:], "windows_hidden_final": popupWindowsHidden,
      "visible_windows_final": NSApp.windows.filter { $0.isVisible || $0.isKeyWindow }.map { ["number": $0.windowNumber, "visible": $0.isVisible, "key": $0.isKeyWindow] as [String: Any] },
      "c2_matrix_attachment": CommandLine.arguments.contains("--ararat-compositor=c2") && passed,
      "c2_matrix_input_hit": CommandLine.arguments.contains("--ararat-compositor=c2") && screen && passed,
      "unverified_reach": ["remaining_keyboard_matrix", "runtime_verification"]])
  }

  func keyboardProfileCheckTick(_ host: any ARWindowHostAPI, port: UInt16, screen: Bool) {
    if browserCheckPhase == 641 {
      guard commandPresenter?.controller.isOpen == true, let seed = browserCheckSeedID else { return }
      adapter?.close(id: seed, archive: false)
      browserCheckPhase = 642
      return
    }
    if browserCheckPhase == 642 {
      guard let seed = browserCheckSeedID, !(host.tabs() as? [any ARTabAPI] ?? []).contains(where: { $0.itemId == seed }) else { return }
      adapter?.select(id: seed, url: keyboardSavedURL)
      browserCheckPhase = 643
      return
    }
    if browserCheckPhase == 643 {
      guard let seed = browserCheckSeedID, let reopened = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == seed }),
            reopened.liveId != keyboardLiveID, !reopened.isLoading, let bar = commandPresenter?.controller else { return }
      keyboardLiveID = reopened.liveId
      let target: SuggestionTarget = keyboardStaleIndex == 0 ? .command(id: "close_tab") :
        keyboardStaleIndex == 1 ? .command(id: "pin_tab") : .moveToSpace(id: "default")
      bar.commit(Suggestion(title: "stale", subtitle: "", url: nil, key: nil, target: target, score: 0))
      workspace?.snapshot { [weak self] result in
        guard let self, case .success(let value) = result else { return }
        self.keyboardResults["stale_snapshot_ok"] = value.spaces.first(where: { $0.id == "default" })?.pinned.contains(where: { $0.id == seed }) == true
      }
      browserCheckPhase = 644
      return
    }
    if browserCheckPhase == 644 {
      guard let unchanged = keyboardResults.removeValue(forKey: "stale_snapshot_ok") as? Bool,
            let seed = browserCheckSeedID else { return }
      guard unchanged, (host.tabs() as? [any ARTabAPI] ?? []).contains(where: { $0.itemId == seed && $0.liveId == keyboardLiveID }) else {
        finishBrowserCheck(ok: false, values: ["stale_suggestion_changed_target": keyboardStaleIndex]); return
      }
      keyboardStaleIndex += 1
      if keyboardStaleIndex < 3 {
        host.checkKeyboardCommand("location")
        browserCheckPhase = 641
      } else {
        keyboardResults["stale_suggestion_actions"] = true
        if screen { browserCheckPhase = 680 }
        else {
          guard let workspace else { return }
          selectionGeneration += 1
          workspace.cancelPendingSpaceSwitches()
          let generation = selectionGeneration
          browserCheckPhase = 645
          workspace.select(id: seed) { [weak self] result in
            guard let self, self.selectionGeneration == generation else { return }
            self.showAndSelect(result, expectedSpace: "default", selectedItem: seed)
          }
        }
      }
      return
    }
    if browserCheckPhase == 645 {
      guard snapshot.selectedId == browserCheckSeedID, host.activeItemId() == browserCheckSeedID,
            let target = host.navigationTarget(), target["item"] as? String == browserCheckSeedID,
            let seed = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == browserCheckSeedID }),
            target["live"] as? String == seed.liveId, !seed.isLoading, seed.url == keyboardSavedURL else { return }
      keyboardRead(seed, script: 5)
      browserCheckPhase = 65
      return
    }
    if browserCheckPhase == 54 {
      guard !host.hasBrowser(forProfile: "Profile 1") else { return }
      guard host.checkKeyboardAccelerator(false), host.checkShortcutActivation() else {
        finishBrowserCheck(ok: false, values: ["inactive_profile_teardown": false]); return
      }
      keyboardResults["inactive_profile_teardown"] = true
      adapter?.windowHost(host, showProfile: "Profile 1")
      adapter?.openCommandURL("http://127.0.0.1:\(port)/keyboard?profile-reload", expectedSpace: "named", profile: "Profile 1")
      browserCheckPhase = 55
      return
    }
    if browserCheckPhase == 55 {
      guard host.profileDirectory() == "Profile 1", host.hasBrowser(forProfile: "Profile 1"), host.activeItemId() != nil,
            let tab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == host.activeItemId() }),
            tab.url == "http://127.0.0.1:\(port)/keyboard?profile-reload", !tab.isLoading, tab.navigationCount > 0,
            host.extensionActions().contains(where: { $0["id"] as? String == "kmgaadhbnkendcanjninlfmfgehagggl" }) else { return }
      host.checkExtensionAction(5)
      guard host.checkReassignedAction() else { finishBrowserCheck(ok: false, values: ["profile_reload_action": false]); return }
      FileHandle.standardError.write(Data("ararat-trace: keyboard profile_reload_action=true profile=\(host.profileDirectory()) active=\(host.activeItemId() ?? "nil") popup=\(host.checkExtensionActionState())\n".utf8))
      browserCheckPhase = 56
      return
    }
    if browserCheckPhase == 56 {
      let state = host.checkExtensionActionState()
      guard (state["loaded"] as? Int ?? 0) > 0 else {
        if browserCheckAttempts % 20 == 0 {
          let tabs = (host.tabs() as? [any ARTabAPI] ?? []).map { "\($0.itemId):loading=\($0.isLoading)" }
          FileHandle.standardError.write(Data("ararat-trace: keyboard wait=profile_reload_popup profile=\(host.profileDirectory()) active=\(host.activeItemId() ?? "nil") popup=\(state) tabs=\(tabs)\n".utf8))
        }
        return
      }
      host.checkExtensionAction(1)
      browserCheckPhase = 560
      return
    }
    if browserCheckPhase == 560 {
      guard (host.checkExtensionActionState()["destroyed"] as? Int ?? 0) > 0 else { return }
      adapter?.windowHost(host, showProfile: "Default")
      host.checkCloseTabs(forProfile: "Profile 1")
      browserCheckPhase = 57
      return
    }
    if browserCheckPhase == 57 {
      guard !host.hasBrowser(forProfile: "Profile 1"), host.profileDirectory() == "Default" else { return }
      keyboardResults["profile_reload"] = true
      host.checkKeyboardCommand("location")
      browserCheckPhase = 58
      return
    }
    if browserCheckPhase == 58 {
      guard let original = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == browserCheckSeedID }),
            let bar = commandPresenter?.controller, bar.isOpen else { return }
      keyboardNavigation = original.navigationCount
      adapter?.windowHost(host, showProfile: "Profile 1")
      bar.update(query: "http://127.0.0.1:\(port)/keyboard?stale")
      bar.commit(forceNewTab: false)
      browserCheckPhase = 59
      return
    }
    if browserCheckPhase == 59 {
      guard commandPresenter == nil, host.hasBrowser(forProfile: "Profile 1"),
            let original = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == browserCheckSeedID }) else { return }
      guard original.navigationCount == keyboardNavigation, !original.url.contains("stale") else {
        finishBrowserCheck(ok: false, values: ["stale_target_navigated": true]); return
      }
      keyboardResults["stale_profile_rejected"] = true
      adapter?.windowHost(host, showProfile: "Default")
      host.checkCloseTabs(forProfile: "Profile 1")
      browserCheckPhase = 60
      return
    }
    if browserCheckPhase == 60 {
      guard host.profileDirectory() == "Default" else { return }
      host.checkKeyboardCommand("search")
      browserCheckPhase = 61
      return
    }
    if browserCheckPhase == 61 {
      guard commandPresenter?.controller.mode == .search else { return }
      host.checkKeyboardCommand("close")
      browserCheckPhase = 62
      return
    }
    if browserCheckPhase == 62 {
      guard let seed = browserCheckSeedID,
            !(host.tabs() as? [any ARTabAPI] ?? []).contains(where: { $0.itemId == seed }) else { return }
      adapter?.select(id: seed, url: keyboardSavedURL)
      browserCheckPhase = 63
      return
    }
    if browserCheckPhase == 63 {
      guard let reopened = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == browserCheckSeedID }),
            reopened.liveId != keyboardLiveID, !reopened.isLoading, reopened.url == keyboardSavedURL,
            let bar = commandPresenter?.controller else { return }
      keyboardLiveID = reopened.liveId
      keyboardNavigation = reopened.navigationCount
      bar.update(query: "example.com")
      bar.commit(forceNewTab: false)
      browserCheckPhase = 64
      return
    }
    if browserCheckPhase == 64 {
      guard commandPresenter == nil, let reopened = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == browserCheckSeedID }) else { return }
      guard reopened.navigationCount == keyboardNavigation, reopened.url == keyboardSavedURL else {
        finishBrowserCheck(ok: false, values: ["stale_search_navigated": true]); return
      }
      keyboardResults["stale_search_rejected"] = true
      keyboardStaleIndex = 0
      host.checkKeyboardCommand("location")
      browserCheckPhase = 641
      return
    }
    if browserCheckPhase == 65 {
      guard keyboardScriptResult == "armed", let reopened = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == browserCheckSeedID }),
            reopened.checkHasBeforeUnload(), snapshot.selectedId == browserCheckSeedID,
            host.activeItemId() == browserCheckSeedID, host.navigationTarget()?["live"] as? String == reopened.liveId else { return }
      keyboardScriptResult = nil
      host.checkKeyboardCommand("location")
      browserCheckPhase = 66
      return
    }
    if browserCheckPhase == 66 {
      guard let bar = commandPresenter?.controller, bar.isOpen, bar.mode == .editURL,
            let target = host.navigationTarget(), target["item"] as? String == browserCheckSeedID else { return }
      let rejectedURL = "http://127.0.0.1:\(port)/keyboard?rejected"
      bar.update(query: rejectedURL)
      guard let row = bar.result.rows.first else { return }
      guard case .openUrl(let url) = row.target, url == rejectedURL else {
        finishBrowserCheck(ok: false, values: ["error": "beforeunload location target"]); return
      }
      host.expectCheckDialogs(1)
      bar.commit(forceNewTab: false)
      browserCheckPhase = 67
      return
    }
    if browserCheckPhase == 67 {
      guard host.checkDialogCount() > 0, let reopened = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == browserCheckSeedID }),
            !reopened.isLoading, reopened.url == keyboardSavedURL,
            reopened.checkNavigationState()["committed_url"] as? String == keyboardSavedURL,
            reopened.checkNavigationState()["visible_url"] as? String == keyboardSavedURL,
            reopened.checkNavigationState()["loading"] as? Bool == false else { return }
      guard snapshot.spaces.flatMap(\.pinned).first(where: { $0.id == browserCheckSeedID })?.url == keyboardSavedURL else {
        finishBrowserCheck(ok: false, values: ["beforeunload_saved_url_changed": true]); return
      }
      keyboardResults["beforeunload_cancel"] = true
      keyboardRead(reopened, script: 6)
      browserCheckPhase = 68
      return
    }
    if browserCheckPhase == 68 {
      guard keyboardScriptResult == "disarmed" else { return }
      keyboardScriptResult = nil
      browserCheckPhase = 680
      return
    }
    if browserCheckPhase == 680 {
      guard let workspace, let seed = browserCheckSeedID else { return }
      keyboardSelectionMark = keyboardCommandTx
      selectionGeneration += 1
      workspace.cancelPendingSpaceSwitches()
      let generation = selectionGeneration
      browserCheckPhase = 681
      workspace.select(id: seed) { [weak self] result in
        guard let self, self.selectionGeneration == generation else { return }
        self.showAndSelect(result, expectedSpace: "default", selectedItem: seed)
      }
      return
    }
    if browserCheckPhase == 681 {
      guard snapshot.selectedId == browserCheckSeedID, host.activeItemId() == browserCheckSeedID,
            let seed = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == browserCheckSeedID }),
            !seed.isLoading, seed.url == keyboardSavedURL, keyboardSelectionSettled(browserCheckSeedID) else { return }
      host.checkKeyboardCommand("duplicate")
      browserCheckPhase = 24
      return
    }
    guard let original = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == browserCheckSeedID }) else { return }
    switch browserCheckPhase {
    case 40:
      guard let other = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == keyboardOtherItem }),
            host.profileDirectory() == "Profile 1", !other.isLoading, other.navigationCount > 0 else { return }
      host.checkNavigate("http://127.0.0.1:\(port)/keyboard", disposition: "current")
      browserCheckPhase = 41
    case 41:
      guard let other = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == keyboardOtherItem }),
            other.url.contains("/keyboard"), !other.isLoading, host.checkKeyboardAccelerator(false) else { return }
      browserCheckPhase = 42
    case 42:
      guard let other = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == keyboardOtherItem }) else { return }
      if let result = keyboardScriptResult {
        keyboardScriptResult = nil
        if result == "probe-command" {
          keyboardRead(other, script: 4)
          browserCheckPhase = 43
          return
        }
      }
      keyboardRead(other, script: 3)
    case 43:
      guard keyboardScriptResult == "cleared" else { return }
      keyboardScriptResult = nil
      adapter?.windowHost(host, showProfile: "Default")
      browserCheckPhase = 44
    case 44:
      guard host.profileDirectory() == "Default", host.activeItemId() == browserCheckSeedID,
            host.checkKeyboardAccelerator(false) else { return }
      browserCheckPhase = 45
    case 45:
      guard let other = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == keyboardOtherItem }) else { return }
      if let result = keyboardScriptResult {
        keyboardScriptResult = nil
        if result == "probe-command" {
          keyboardRead(other, script: 3)
          browserCheckPhase = 46
          return
        }
      }
      keyboardRead(original, script: 3)
    case 46:
      guard let result = keyboardScriptResult else { return }
      keyboardScriptResult = nil
      guard result.isEmpty else {
        keyboardResults["inactive_profile_received_shortcut"] = true
        finishBrowserCheck(ok: false, values: keyboardResults)
        return
      }
      guard host.checkReassignInactiveAction(), !host.checkReassignedAction(), host.checkKeyboardAccelerator(true) else {
        keyboardResults["inactive_reassignment"] = false
        finishBrowserCheck(ok: false, values: keyboardResults)
        return
      }
      browserCheckPhase = 47
    case 47:
      let state = host.checkExtensionActionState()
      guard (state["loaded"] as? Int ?? 0) >= 2 else { return }
      host.checkExtensionAction(1)
      browserCheckPhase = 470
    case 470:
      guard (host.checkExtensionActionState()["destroyed"] as? Int ?? 0) >= 2 else { return }
      adapter?.windowHost(host, showProfile: "Profile 1")
      browserCheckPhase = 48
    case 48:
      guard host.profileDirectory() == "Profile 1" else { return }
      host.checkExtensionAction(5)
      guard host.checkReassignedAction() else {
        keyboardResults["reassigned_action_fired"] = false
        finishBrowserCheck(ok: false, values: keyboardResults)
        return
      }
      browserCheckPhase = 49
    case 49:
      guard (host.checkExtensionActionState()["loaded"] as? Int ?? 0) > 0 else { return }
      host.checkExtensionAction(1)
      browserCheckPhase = 490
    case 490:
      guard (host.checkExtensionActionState()["destroyed"] as? Int ?? 0) > 0 else { return }
      adapter?.windowHost(host, showProfile: "Default")
      browserCheckPhase = 50
    case 50:
      guard host.profileDirectory() == "Default", host.activeItemId() == browserCheckSeedID else { return }
      host.checkExtensionAction(5)
      guard host.checkKeyboardAccelerator(true) else {
        keyboardResults["default_action_after_switch"] = false
        finishBrowserCheck(ok: false, values: keyboardResults)
        return
      }
      browserCheckPhase = 500
    case 500:
      guard (host.checkExtensionActionState()["loaded"] as? Int ?? 0) > 0 else { return }
      host.checkExtensionAction(1)
      browserCheckPhase = 51
    case 51:
      guard (host.checkExtensionActionState()["destroyed"] as? Int ?? 0) > 0 else { return }
      keyboardResults["profile_shortcuts"] = true
      keyboardResults["inactive_reassignment"] = true
      guard host.checkShortcutActivation() else { finishBrowserCheck(ok: false, values: ["shortcut_activation": false]); return }
      host.checkMenuCommand(true)
      browserCheckPhase = 52
    case 52:
      guard let child = children.first(where: { $0.host != nil }), let childHost = child.host,
            childHost.hasBrowser(), let childAdapter = child.adapter else { return }
      if screen && !childHost.window().isKeyWindow { childHost.window().makeKeyAndOrderFront(nil); return }
      childAdapter.openCommandURL("http://127.0.0.1:\(port)/keyboard?child", expectedSpace: "default", profile: "Default")
      keyboardRead(original, script: 4)
      browserCheckPhase = 520
    case 520:
      guard keyboardScriptResult == "cleared", let child = children.first, let childHost = child.host,
            let target = childHost.navigationTarget(), let live = target["live"] as? String,
            let item = target["item"] as? String, child.snapshot.selectedId == item,
            let childTab = (childHost.tabs() as? [any ARTabAPI])?.first(where: { $0.liveId == live }),
            childTab.url == "http://127.0.0.1:\(port)/keyboard?child", !childTab.isLoading else { return }
      keyboardScriptResult = nil
      keyboardRead(childTab, script: 4)
      browserCheckPhase = 521
    case 521:
      guard keyboardScriptResult == "cleared", let childHost = children.first?.host else { return }
      guard host.checkShortcutActivation(), childHost.checkShortcutActivation(), childHost.checkKeyboardAccelerator(false) else { return }
      keyboardScriptResult = nil
      browserCheckPhase = 522
    case 522:
      guard let childHost = children.first?.host, let live = childHost.navigationTarget()?["live"] as? String,
            let childTab = (childHost.tabs() as? [any ARTabAPI])?.first(where: { $0.liveId == live }) else { return }
      if let result = keyboardScriptResult {
        keyboardScriptResult = nil
        if result == "probe-command" {
          keyboardRead(original, script: 3)
          browserCheckPhase = 523
          return
        }
      }
      keyboardRead(childTab, script: 3)
    case 523:
      guard let result = keyboardScriptResult, let child = children.first, let childHost = child.host,
            let target = childHost.navigationTarget() else { return }
      keyboardScriptResult = nil
      guard result.isEmpty else { finishBrowserCheck(ok: false, values: ["inactive_window_received_shortcut": true]); return }
      if !screen {
        let suggestion = Suggestion(title: "Settings", subtitle: "", url: nil, key: nil, target: .command(id: "settings"), score: 0)
        openCommandBar(.newTab)
        guard let firstBar = commandPresenter?.controller else { finishBrowserCheck(ok: false, values: ["settings_first_bar": false]); return }
        firstBar.commit(suggestion)
        guard let settings, let window = settings.window, !window.isVisible, settingsOwner === self else {
          finishBrowserCheck(ok: false, values: ["hidden_settings": false]); return
        }
        let defaultWidth = child.container?.resizeHandle.sidebarWidth
        container?.resizeHandle.sidebarWidth = 300
        child.container?.resizeHandle.sidebarWidth = 330
        child.openCommandBar(.newTab)
        guard let secondBar = child.commandPresenter?.controller else { finishBrowserCheck(ok: false, values: ["settings_second_bar": false]); return }
        secondBar.commit(suggestion)
        guard self.settings?.window === window, settingsOwner === child, !window.isVisible, !window.isKeyWindow else {
          finishBrowserCheck(ok: false, values: ["shared_settings": false]); return
        }
        settings.checkResetSidebarWidth()
        guard container?.resizeHandle.sidebarWidth == 300,
              child.container?.resizeHandle.sidebarWidth == defaultWidth else {
          finishBrowserCheck(ok: false, values: ["settings_wrong_window": true]); return
        }
        keyboardResults["hidden_settings"] = true
        keyboardResults["shared_settings"] = true
        keyboardResults["settings_edit_target"] = true
        guard let index = child.snapshot.spaces.firstIndex(where: { $0.id == "named" }) else {
          finishBrowserCheck(ok: false, values: ["settings_named_space_missing": true]); return
        }
        child.sidebar?.showSpace(at: index)
        browserCheckPhase = 524
        return
      }
      keyboardResults["two_window_shortcuts"] = true
      guard holdChildFindForTeardown(childHost) else { finishBrowserCheck(ok: false, values: ["find_child_setup": false]); return }
      childHost.close()
      guard !childHost.navigateURL("http://127.0.0.1:\(port)/keyboard?closed", target: target) else {
        finishBrowserCheck(ok: false, values: ["closed_host_navigated": true]); return
      }
      keyboardResults["closed_host_rejected"] = true
      browserCheckPhase = 53
    case 524:
      guard let child = children.first, let childHost = child.host, child.snapshot.shownSpaceId == "named",
            childHost.profileDirectory() == "Profile 1", settings?.window != nil else { return }
      child.adapter?.openCommandURL("http://127.0.0.1:\(port)/keyboard?settings-child", expectedSpace: "named", profile: "Profile 1")
      browserCheckPhase = 5241
    case 5241:
      guard let child = children.first, let childHost = child.host, child.snapshot.shownSpaceId == "named",
            childHost.profileDirectory() == "Profile 1", let target = childHost.navigationTarget(),
            target["url"] as? String == "http://127.0.0.1:\(port)/keyboard?settings-child",
            let settings, let window = settings.window else { return }
      child.openCommandBar(.newTab)
      guard let bar = child.commandPresenter?.controller else { finishBrowserCheck(ok: false, values: ["settings_profile_bar": false]); return }
      bar.commit(Suggestion(title: "Settings", subtitle: "", url: nil, key: nil, target: .command(id: "settings"), score: 0))
      guard self.settings?.window === window, settingsOwner === child, !window.isVisible else {
        finishBrowserCheck(ok: false, values: ["settings_profile_owner": false]); return
      }
      settings.checkRenameShownSpace("U16 named settings")
      browserCheckPhase = 525
    case 525:
      guard let child = children.first, let childHost = child.host,
            child.snapshot.spaces.first(where: { $0.id == "named" })?.title == "U16 named settings",
            child.snapshot.spaces.first(where: { $0.id == "default" })?.title == "Default",
            let target = childHost.navigationTarget() else { return }
      keyboardResults["settings_space_edit"] = true
      keyboardResults["two_window_shortcuts"] = true
      guard holdChildFindForTeardown(childHost) else { finishBrowserCheck(ok: false, values: ["find_child_setup": false]); return }
      childHost.close()
      guard !childHost.navigateURL("http://127.0.0.1:\(port)/keyboard?closed", target: target) else {
        finishBrowserCheck(ok: false, values: ["closed_host_navigated": true]); return
      }
      keyboardResults["closed_host_rejected"] = true
      browserCheckPhase = 53
    case 53:
      guard children.allSatisfy({ $0.host == nil }), !original.checkHeldFindTargetAlive() else { return }
      let held = original.checkDeliverHeldFindReply()
      guard held["alive"] as? Bool == false, held["delivered"] as? Bool == false,
            container?.findBar.field.stringValue == keyboardFindTeardownText else {
        finishBrowserCheck(ok: false, values: ["find_host_teardown": false]); return
      }
      keyboardResults["find_host_teardown"] = true
      if screen && !host.window().isKeyWindow { host.window().makeKeyAndOrderFront(nil); return }
      guard host.checkShortcutActivation(), host.checkKeyboardAccelerator(false) else { return }
      keyboardResults["two_window_teardown"] = true
      host.checkCloseTabs(forProfile: "Profile 1")
      browserCheckPhase = 54
    default: break
    }
  }

  func holdChildFindForTeardown(_ childHost: any ARWindowHostAPI) -> Bool {
    guard let active = childHost.activeItemId(),
          let tab = (childHost.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == active }) else { return false }
    keyboardFindTeardownText = container?.findBar.field.stringValue ?? ""
    childHost.checkKeyboardCommand("find")
    return tab.checkHoldFindReply("pending-before-host-close")
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

  func promptScreenCapture(_ host: any ARWindowHostAPI, name: String, dialogWindow: NSWindow? = nil) -> [String: Any]? {
    let window = host.window()
    guard let card = promptPageCard,
          let dialog = dialogWindow ?? window.childWindows?.first(where: { $0.isVisible }),
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

  func dialogsScreenTick(_ host: any ARWindowHostAPI) {
    guard !dialogsScreenCapturing, preparePromptFixture(host, name: "permissions"),
          let tabs = host.tabs() as? [any ARTabAPI],
          let tab = dialogsScreenFirstLive.isEmpty ? tabs.first : tabs.first(where: { $0.liveId == dialogsScreenFirstLive }) else { return }
    func clickLibrary() -> Bool {
      guard let sidebar else { return false }
      let frame = sidebar.convert(sidebar.checkLibraryButtonFrame, to: nil)
      let location = NSPoint(x: frame.midX, y: frame.midY)
      let window = host.window()
      guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 0, clickCount: 1, pressure: 0) else { return false }
      NSApp.postEvent(down, atStart: false)
      NSApp.postEvent(up, atStart: false)
      return true
    }
    func capture(_ name: String, dialog: NSWindow? = nil) -> [String: Any]? {
      dialogsScreenCapturing = true
      defer { dialogsScreenCapturing = false }
      return promptScreenCapture(host, name: "dialogs-\(name)", dialogWindow: dialog)
    }
    switch browserCheckPhase {
    case 1:
      guard NSApp.isActive, host.window().isKeyWindow, tab.url.contains("/permissions"), !tab.isLoading else { return }
      dialogsScreenFirstLive = tab.liveId
      tab.checkRequestPermission(2)
      browserCheckPhase = 2
    case 2:
      guard tab.checkPermissionWidgetVisible(), let dialog = tab.checkPermissionBlockButton()["window"] as? NSWindow,
            dialog.isKeyWindow,
            let step = capture("permission", dialog: dialog) else { return }
      FileHandle.standardError.write(Data("ararat-trace: dialogs permission window=\(dialog.windowNumber) class=\(type(of: dialog)) frame=\(NSStringFromRect(dialog.frame)) visible=\(dialog.isVisible) key=\(dialog.isKeyWindow)\n".utf8))
      dialogsScreenSteps["permission"] = step
      let width = (step["dialog_frame"] as? [String: Double])?["width"] ?? 0
      dialogsScreenChecks["permission_position"] = step["inside_card"] as? Bool == true && step["centered"] as? Bool == true && abs(width - 340) <= 8
      promptScreenKey(dialog, code: 36, characters: "\r")
      dialogsScreenTicks = 0
      browserCheckPhase = 3
      FileHandle.standardError.write(Data("ararat-trace: dialogs screen return sent\n".utf8))
    case 3:
      dialogsScreenTicks += 1
      guard dialogsScreenTicks >= 4 else { return }
      dialogsScreenChecks["return_keeps_prompt"] = tab.checkPermissionWidgetVisible() && tab.checkPermissionPending()
      guard clickLibrary() else { return }
      browserCheckPhase = 4
    case 4:
      guard sidebar?.libraryOpen == true else { return }
      dialogsScreenChecks["sidebar_click"] = tab.checkPermissionWidgetVisible()
      guard clickLibrary() else { return }
      browserCheckPhase = 5
    case 5:
      guard sidebar?.libraryOpen == false, let dialog = tab.checkPermissionBlockButton()["window"] as? NSWindow else { return }
      dialog.makeKeyAndOrderFront(nil)
      guard dialog.isKeyWindow else { return }
      promptScreenKey(dialog, code: 53, characters: "\u{1b}")
      browserCheckPhase = 6
      FileHandle.standardError.write(Data("ararat-trace: dialogs screen escape sent\n".utf8))
    case 6:
      guard !tab.checkPermissionPending(), !tab.checkIsDialogActive() else { return }
      if !permissionReadPending {
        permissionReadPending = true
        tab.checkPermissionResults { [weak self] json in
          MainActor.assumeIsolated {
            guard let self else { return }
            self.permissionReadPending = false
            if let data = json.data(using: .utf8), let values = try? JSONDecoder().decode([String: String].self, from: data) { self.permissionResults = values }
          }
        }
      }
      guard permissionResults["midiResult"] == "NotAllowedError", permissionResults["midiState"] == "prompt",
            let port = promptFixturePort else { return }
      dialogsScreenChecks["escape_dismisses"] = true
      host.checkNavigate("http://a-very-long-subdomain-that-exceeds-the-sheet-width-by-itself.example.localhost:\(port)/permissions", disposition: "current")
      browserCheckPhase = 61
    case 61:
      guard tab.url.contains("example.localhost"), !tab.isLoading else { return }
      tab.checkRequestPermission(2)
      browserCheckPhase = 62
    case 62:
      let state = tab.checkPermissionBlockButton()
      guard tab.checkPermissionWidgetVisible(), let dialog = state["window"] as? NSWindow,
            dialog.isKeyWindow, let step = capture("long-origin", dialog: dialog) else { return }
      dialogsScreenChecks["long_origin_wrapped"] = state["origin_wrapped"] as? Bool == true
      dialogsScreenSteps["long_origin"] = step
      promptScreenKey(dialog, code: 53, characters: "\u{1b}")
      browserCheckPhase = 63
    case 63:
      guard !tab.checkPermissionPending(), !tab.checkIsDialogActive(), let port = promptFixturePort else { return }
      host.checkNavigate("http://127.0.0.1:\(port)/dialogs", disposition: "current")
      browserCheckPhase = 7
    case 7:
      guard tab.url.contains("/dialogs"), !tab.isLoading else { return }
      tab.checkRunJavaScriptDialog(0)
      browserCheckPhase = 8
    case 8:
      guard tab.checkIsDialogActive(), tab.checkDialogHostIsOurs() else { return }
      tab.checkRequestPermission(3)
      browserCheckPhase = 9
    case 9:
      guard tab.checkPermissionShownCount() >= 3, !tab.checkPermissionWidgetVisible() else { return }
      dialogsScreenChecks["javascript_before_permission"] = true
      guard let step = capture("javascript") else { return }
      dialogsScreenSteps["javascript"] = step
      guard tab.checkAcceptJavaScriptDialog("") else { return }
      browserCheckPhase = 10
    case 10:
      guard tab.checkPermissionWidgetVisible(),
            let dialog = tab.checkPermissionBlockButton()["window"] as? NSWindow, dialog.isKeyWindow,
            let step = capture("queued-permission", dialog: dialog) else { return }
      dialogsScreenSteps["queued_permission"] = step
      dialogsScreenChecks["permission_after_javascript"] = true
      promptScreenKey(dialog, code: 53, characters: "\u{1b}")
      browserCheckPhase = 11
    case 11:
      guard !tab.checkPermissionPending() else { return }
      if CommandLine.arguments.contains("--ararat-compositor=c2") {
        let names = ["permission_position", "return_keeps_prompt", "sidebar_click", "escape_dismisses", "long_origin_wrapped", "javascript_before_permission", "permission_after_javascript"]
        let values = Dictionary(uniqueKeysWithValues: names.map { ($0, dialogsScreenChecks[$0] == true) })
        let failed = names.filter { values[$0] != true }
        finishBrowserCheck(ok: failed.isEmpty, values: ["conditions": values, "failed_conditions": failed,
          "steps": dialogsScreenSteps, "compositor": "c2", "split_supported": false])
        return
      }
      guard let index = snapshot.spaces.firstIndex(where: { $0.id == "named" }) else { return }
      sidebar?.showSpace(at: index)
      browserCheckPhase = 111
    case 111:
      guard snapshot.shownSpaceId == "named", let adapter else { return }
      adapter.select(id: "close-split-a", url: "about:blank")
      browserCheckPhase = 112
    case 112:
      guard host.activeItemId() == "close-split-a", splitCheckPagesPresented(host),
            let other = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == "close-split-b" }) else { return }
      other.checkActivateSplitPane()
      browserCheckPhase = 113
      FileHandle.standardError.write(Data("ararat-trace: dialogs split activate B requested tabs=\(host.tabs().count)\n".utf8))
    case 113:
      guard host.activeItemId() == "close-split-b", let port = promptFixturePort else { return }
      host.checkNavigate("http://127.0.0.1:\(port)/permissions?split", disposition: "current")
      browserCheckPhase = 114
    case 114:
      guard let tabs = host.tabs() as? [any ARTabAPI],
            let other = tabs.first(where: { $0.itemId == "close-split-b" }),
            other.url.contains("/permissions"), !other.isLoading,
            let first = tabs.first(where: { $0.itemId == "close-split-a" }) else { return }
      first.checkActivateSplitPane()
      browserCheckPhase = 115
      FileHandle.standardError.write(Data("ararat-trace: dialogs split activate A requested tabs=\(tabs.count)\n".utf8))
    case 115:
      guard host.activeItemId() == "close-split-a",
            let other = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == "close-split-b" }) else { return }
      other.checkRequestPermission(3)
      dialogsScreenTicks = 0
      browserCheckPhase = 13
      FileHandle.standardError.write(Data("ararat-trace: dialogs inactive B permission requested active=\(host.activeItemId() ?? "nil") tabs=\(host.tabs().count)\n".utf8))
    case 13:
      guard let other = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == "close-split-b" }),
            host.activeItemId() != other.itemId, other.checkPermissionPending() else { return }
      dialogsScreenTicks += 1
      guard dialogsScreenTicks >= 4 else { return }
      dialogsScreenChecks["split_inactive_hidden"] = !other.checkPermissionWidgetVisible()
      other.checkActivateSplitPane()
      browserCheckPhase = 131
      FileHandle.standardError.write(Data("ararat-trace: dialogs split activate pending B requested tabs=\(host.tabs().count)\n".utf8))
    case 131:
      dialogsScreenTicks += 1
      if dialogsScreenTicks == 5 || dialogsScreenTicks % 20 == 0 {
        let other = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == "close-split-b" })
        FileHandle.standardError.write(Data("ararat-trace: dialogs split pending active=\(host.activeItemId() ?? "nil") tabs=\(host.tabs().count) present=\(other != nil) pending=\(other?.checkPermissionPending() ?? false) visible=\(other?.checkPermissionWidgetVisible() ?? false) shown=\(other?.checkPermissionShownCount() ?? 0)\n".utf8))
      }
      guard let other = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == "close-split-b" }),
            other.checkPermissionWidgetVisible(), let view = other.view,
            let dialog = other.checkPermissionBlockButton()["window"] as? NSWindow,
            let step = capture("split", dialog: dialog) else { return }
      let pane = view.convert(view.bounds, to: nil)
      let actual = host.window().convertFromScreen(dialog.frame)
      dialogsScreenChecks["split_pane_after_activation"] = host.activeItemId() == other.itemId && abs(actual.midX - pane.midX) <= 4 && pane.insetBy(dx: -4, dy: -4).contains(actual)
      dialogsScreenSteps["split"] = step
      dialog.makeKeyAndOrderFront(nil)
      guard dialog.isKeyWindow else { return }
      promptScreenKey(dialog, code: 53, characters: "\u{1b}")
      browserCheckPhase = 132
    case 132:
      guard let other = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == "close-split-b" }),
            !other.checkPermissionPending(), let adapter,
            let row = snapshot.spaces.first(where: { $0.id == "named" })?.today.first,
            let url = row.url else { return }
      dialogsScreenTransferID = row.id
      adapter.select(id: row.id, url: url)
      browserCheckPhase = 133
    case 133:
      guard host.activeItemId() == dialogsScreenTransferID, let port = promptFixturePort else { return }
      host.checkNavigate("http://127.0.0.1:\(port)/permissions?transfer", disposition: "current")
      browserCheckPhase = 134
    case 134:
      guard let plain = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == dialogsScreenTransferID }),
            plain.url.contains("/permissions?transfer"), !plain.isLoading else { return }
      plain.checkRequestPermission(3)
      browserCheckPhase = 135
    case 135:
      guard let plain = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == dialogsScreenTransferID }),
            plain.checkPermissionPending(), plain.checkPermissionWidgetVisible() else { return }
      guard let adapter else { return }
      let child = Runtime(windowID: UUID().uuidString)
      child.root = self
      do { try child.start(session: adapter.session, shownSpace: "named") }
      catch { finishBrowserCheck(ok: false, values: ["error": "transfer child: \(error)"]); return }
      children.append(child)
      child.host?.window().makeKeyAndOrderFront(nil)
      browserCheckPhase = 14
    case 14:
      guard let other = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == dialogsScreenTransferID }),
            let destination = children.last?.host, destination.window().isVisible,
            destination.profileDirectory() == "Profile 1",
            host.checkMoveTab(other, toHost: destination) else { return }
      dialogsScreenTicks = 0
      browserCheckPhase = 15
    case 15:
      guard let child = children.last, let destination = child.host,
            let moved = (destination.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == dialogsScreenTransferID }),
            let childAdapter = child.adapter, let childWorkspace = child.workspace,
            childAdapter.session.queue.sync(execute: { childAdapter.session.store?.liveWindow(item: moved.itemId ?? "") }) == child.windowID else { return }
      browserCheckPhase = 150
      childWorkspace.select(id: dialogsScreenTransferID) { [weak self, weak child] result in
        guard let self, let child else { return }
        guard case .success(let selected) = result, selected.shownSpaceId == "named",
              selected.selectedId == self.dialogsScreenTransferID else {
          self.finishBrowserCheck(ok: false, values: ["error": "transfer destination selection: \(result)"])
          return
        }
        child.show(selected)
        child.adapter?.refresh()
        FileHandle.standardError.write(Data("ararat-trace: dialogs transfer selected destination=\(child.windowID) item=\(selected.selectedId ?? "nil")\n".utf8))
        self.browserCheckPhase = 151
      }
    case 151:
      dialogsScreenTicks += 1
      if dialogsScreenTicks == 1 || dialogsScreenTicks % 20 == 0 {
        let destination = children.last?.host
        let moved = (destination?.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == dialogsScreenTransferID })
        let state = moved?.checkPermissionWidgetState() ?? [:]
        FileHandle.standardError.write(Data("ararat-trace: dialogs transfer wait item=\(dialogsScreenTransferID) selected=\(children.last?.snapshot.selectedId ?? "nil") active=\(destination?.activeItemId() ?? "nil") pending=\(moved?.checkPermissionPending() ?? false) modal=\(moved?.checkIsDialogActive() ?? false) host_ours=\(moved?.checkDialogHostIsOurs() ?? false) window=\(destination?.window().windowNumber ?? -1) window_visible=\(destination?.window().isVisible ?? false) sheet=\(state["window_number"] ?? -1) parent=\(state["parent_window_number"] ?? -1) delegate_visible=\(state["delegate_visible"] ?? false) widget=\(moved?.checkPermissionWidgetVisible() ?? false) dim=\(moved.map { children.last?.adapter?.checkPermissionDim($0.liveId) == true } ?? false)\n".utf8))
      }
      guard let child = children.last, let destination = child.host,
            let moved = (destination.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == dialogsScreenTransferID }),
            child.snapshot.selectedId == moved.itemId, destination.activeItemId() == moved.itemId,
            moved.checkPermissionPending(), moved.checkIsDialogActive(), moved.checkDialogHostIsOurs(),
            moved.checkPermissionWidgetVisible(), child.adapter?.checkPermissionDim(moved.liveId) == true,
            let sheet = moved.checkPermissionBlockButton()["window"] as? NSWindow,
            sheet.parent === destination.window(),
            moved.checkPermissionWidgetState()["delegate_visible"] as? Bool == true else { return }
      dialogsScreenCapturing = true
      let transferImage = promptScreenScreenshot(destination.window(), name: "dialogs-transfer", withoutShadow: true)
      dialogsScreenCapturing = false
      guard let transferImage else { return }
      dialogsScreenChecks["transfer_dim"] = true
      dialogsScreenSteps["transfer"] = ["screenshot": transferImage]
      let names = ["permission_position", "return_keeps_prompt", "sidebar_click", "escape_dismisses", "long_origin_wrapped", "javascript_before_permission", "permission_after_javascript", "split_inactive_hidden", "split_pane_after_activation", "transfer_dim"]
      let values = Dictionary(uniqueKeysWithValues: names.map { ($0, dialogsScreenChecks[$0] == true) })
      let failed = names.filter { values[$0] != true }
      let compositor = CommandLine.arguments.contains("--ararat-compositor=c2") ? "c2" : "c1"
      finishBrowserCheck(ok: failed.isEmpty, values: ["conditions": values, "failed_conditions": failed, "steps": dialogsScreenSteps, "compositor": compositor])
    default: break
    }
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
      // Why not the first visible child: any other child window that happens to be visible first would
      // take the call and the phase would spin; the cancel helper validates the window itself before acting.
      guard capture("webauthn_get"),
            host.window().childWindows?.contains(where: { $0.isVisible && tab.checkCancelScreenDialog($0) }) == true
      else { return }
      browserCheckPhase = 16
    case 16:
      guard promptScreenResults["get"] == "NotAllowedError" else { return }
      promptScreenSteps["webauthn_get"]?["page_result"] = "NotAllowedError"
      tab.checkScreenWebAuthn(true)
      browserCheckPhase = 17
    case 17:
      guard capture("webauthn_create"),
            host.window().childWindows?.contains(where: { $0.isVisible && tab.checkCancelScreenDialog($0) }) == true
      else { return }
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
        } else {
          tab.checkRunJavaScriptDialog(0)
          browserCheckPhase = 17
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
    } else if browserCheckPhase == 17 {
      guard tab.checkIsDialogActive(), let port = promptFixturePort else { return }
      dialogNavigationBefore = Int(tab.navigationCount)
      host.checkNavigate("http://127.0.0.1:\(port)/auth", disposition: "current")
      browserCheckPhase = 18
    } else if browserCheckPhase == 18 {
      guard Int(tab.navigationCount) > dialogNavigationBefore, tab.checkIsDialogActive(), tab.checkDialogHostIsOurs() else { return }
      guard !tab.checkAcceptJavaScriptDialog("") else {
        finishBrowserCheck(ok: false, values: ["same_site_navigation_cleared": false]); return
      }
      dialogNavigationCleared = true
      dialogResults = [:]
      authShown = true
      guard tab.checkCloseModalDialogs() else { return }
      authCancelled = true
      browserCheckPhase = 13
    } else if browserCheckPhase == 13 {
      guard !tab.checkIsDialogActive(), tab.url.contains("/auth"), !tab.isLoading,
            dialogResults["auth"] == "body" else { return }
      let stock = host.checkStockBrowsers()
      finishBrowserCheck(ok: stock == 0 && dialogNavigationCleared, values: ["shown": dialogShown, "answered": dialogAnswered,
        "alert": "done", "confirm_ok": "true", "confirm_cancel": "false", "prompt_text": "Ararat text",
        "prompt_cancel": "null", "auth_shown": authShown, "auth_cancelled": authCancelled,
        "auth_body": true, "card_before": rectFields(dialogCardBefore), "card_after": rectFields(dialogCardAfter),
        "dialog_frame": rectFields(dialogResizedFrame), "inside_card": true, "centered": true,
        "same_site_navigation_cleared": dialogNavigationCleared, "stock_browsers": stock])
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
            "external_scheme_row": protocolShown && protocolCancelled && unchanged && frontUnchanged && noProcess,
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
    func newFocusEvents() -> [Int] {
      let events = report("Profile 1")?["focusEvents"] as? [Int] ?? []
      return Array(events.dropFirst(profileFocusEventCount))
    }
    let focusWaitTicks = 50
    if browserCheckPhase == 4 || browserCheckPhase == 5 { profileFocusPhaseTicks += 1 }
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
        guard let events = report("Profile 1")?["focusEvents"] as? [Int] else { return }
        profileFocusEventCount = events.count
        profileFocusPhaseTicks = 0
        NSApp.hide(nil)
        browserCheckPhase = 4
      }
    } else if screen, browserCheckPhase == 4, NSApp.isHidden, !NSApp.isActive {
      profileFocusNoneObserved = NSApp.keyWindow == nil
      let events = newFocusEvents()
      if events.contains(-1) {
        profileNewFocusNoneEvent = events.filter { $0 == -1 }.count == 1
        profileFocusPhaseTicks = 0
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        host.window().makeKeyAndOrderFront(nil)
        browserCheckPhase = 5
      } else if profileFocusPhaseTicks > focusWaitTicks {
        finishBrowserCheck(ok: false, values: ["profiles": profileCheckStates,
          "focused_hidden_profile": true, "focus_probe": extensionFocusProbe,
          "focus_none": profileFocusNoneObserved, "new_focus_none_event": false,
          "new_focus_events": events, "app_deactivated": true, "focus_wait_ticks": profileFocusPhaseTicks,
          "stock_browsers": host.checkStockBrowsers()])
      }
    } else if screen, browserCheckPhase == 4, profileFocusPhaseTicks > focusWaitTicks {
      finishBrowserCheck(ok: false, values: ["profiles": profileCheckStates,
        "focus_probe": extensionFocusProbe, "focus_none": profileFocusNoneObserved,
        "new_focus_none_event": false, "new_focus_events": newFocusEvents(), "app_deactivated": false,
        "application_active": NSApp.isActive, "application_hidden": NSApp.isHidden,
        "focus_wait_ticks": profileFocusPhaseTicks, "stock_browsers": host.checkStockBrowsers()])
    } else if screen, browserCheckPhase == 5, !NSApp.isHidden, NSApp.isActive {
      let window = host.window()
      if profileFocusPhaseTicks > focusWaitTicks {
        let events = newFocusEvents()
        let target = extensionFocusProbe["targetId"] as? Int
        finishBrowserCheck(ok: false, values: ["profiles": profileCheckStates,
          "focus_probe": extensionFocusProbe, "focus_none": profileFocusNoneObserved,
          "new_focus_none_event": false, "new_focus_events": events,
          "focus_returned": target != nil && events.last == target, "app_deactivated": true,
          "window_key": window.isKeyWindow, "focus_wait_ticks": profileFocusPhaseTicks,
          "stock_browsers": host.checkStockBrowsers()])
        return
      }
      guard window.isKeyWindow else { window.makeKeyAndOrderFront(nil); return }
      let events = newFocusEvents()
      guard let target = extensionFocusProbe["targetId"] as? Int, events.last == target else { return }
      profileNewFocusNoneEvent = events.filter { $0 == -1 }.count == 1
      profileFocusEventsAtReturn = events
      if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.window().windowNumber,
          context: nil, characters: "n", charactersIgnoringModifiers: "N", isARepeat: false, keyCode: 45) {
        NSApp.sendEvent(event)
      }
      browserCheckPhase = 6
    } else if screen, browserCheckPhase == 5, profileFocusPhaseTicks > focusWaitTicks {
      finishBrowserCheck(ok: false, values: ["profiles": profileCheckStates,
        "focus_probe": extensionFocusProbe, "focus_none": profileFocusNoneObserved,
        "new_focus_none_event": false, "new_focus_events": newFocusEvents(), "app_deactivated": true,
        "application_active": NSApp.isActive, "application_hidden": NSApp.isHidden,
        "window_key": host.window().isKeyWindow, "focus_wait_ticks": profileFocusPhaseTicks,
        "stock_browsers": host.checkStockBrowsers()])
    } else if screen, browserCheckPhase == 6,
              let privateChild = children.first(where: { $0.isPrivateWindow && $0.host != nil }),
              let privateHost = privateChild.host, privateHost.isPrivateWindow() {
      // U26f: a normal OTR window is a full private window, not the old page-only popup.
      if CommandLine.arguments.contains("--ararat-page-only-menu-check") {
        privateHost.checkNavigate("data:text/html,<title>Ararat save check</title>save", disposition: "current")
        privateHost.window().makeKeyAndOrderFront(nil)
        browserCheckPhase = 61
        return
      }
      finishBrowserCheck(ok: profileFocusNoneObserved && profileNewFocusNoneEvent && host.checkStockBrowsers() == 0, values: ["profiles": profileCheckStates,
        "focused_hidden_profile": true, "focus_probe": extensionFocusProbe, "focus_none": profileFocusNoneObserved,
        "new_focus_none_event": profileNewFocusNoneEvent, "new_focus_events": newFocusEvents(),
        "focus_events_at_return": profileFocusEventsAtReturn,
        "app_deactivated": true, "menu_incognito": true, "private_window": true, "stock_browsers": host.checkStockBrowsers()])
    } else if screen, browserCheckPhase == 61,
              let privateChild = children.first(where: { $0.isPrivateWindow && $0.host != nil }),
              let privateHost = privateChild.host,
              let tab = (privateHost.tabs() as? [any ARTabAPI])?.first, tab.title == "Ararat save check", !tab.isLoading {
      guard let rows = captureCheckRows() else { return }
      quitBefore = rows
      // Save Page on the full private window: Chrome's own command, no key-window dispatch.
      privateHost.checkSavePage()
      browserCheckPhase = 62
    } else if screen, browserCheckPhase == 62,
              let save = NSApp.windows.compactMap({ $0 as? NSSavePanel }).first(where: { $0.isVisible }) {
      guard pageOnlyRowsUnchanged(quitBefore, captureCheckRows()) else { finishBrowserCheck(ok: false, values: ["page_only_menu_rows": false]); return }
      save.cancel(nil)
      browserCheckPhase = 63
    } else if screen, browserCheckPhase == 63,
              !NSApp.windows.contains(where: { $0 is NSSavePanel && $0.isVisible }) {
      let unchanged = pageOnlyRowsUnchanged(quitBefore, captureCheckRows())
      finishBrowserCheck(ok: unchanged && profileFocusNoneObserved && profileNewFocusNoneEvent && host.checkStockBrowsers() == 0,
        values: ["profiles": profileCheckStates, "focused_hidden_profile": true, "focus_probe": extensionFocusProbe,
          "focus_none": profileFocusNoneObserved, "new_focus_none_event": profileNewFocusNoneEvent,
          "new_focus_events": newFocusEvents(),
          "focus_events_at_return": profileFocusEventsAtReturn,
          "app_deactivated": true, "menu_incognito": true, "private_window": true, "page_only_save": true, "rows_unchanged": unchanged,
          "stock_browsers": host.checkStockBrowsers()])
    }
  }

  func incognitoCheckTick(_ host: any ARWindowHostAPI) {
    if browserCheckPhase == 0,
       let row = snapshot.spaces.first(where: { $0.id == "default" })?.today.first,
       row.url != nil {
      browserCheckSeedID = row.id
      selectCheckSeed(row)
      browserCheckPhase = 1
    } else if browserCheckPhase == 1, let seed = browserCheckSeedID, sliceActive == seed,
              snapshot.selectedId == seed, host.activeItemId() == seed,
              let tab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == seed }),
              !tab.isLoading, tab.navigationCount > 0, tab.url == "about:blank", !tab.title.isEmpty,
              snapshot.spaces.first(where: { $0.id == "default" })?.today.first(where: { $0.id == seed })?.title == tab.title,
              let rows = captureCheckRows(), checkStoredTabMetadata(rows, item: seed, url: tab.url, title: tab.title) {
      browserCheckBefore = snapshot
      quitBefore = rows
      host.checkCreateIncognito()
      browserCheckPhase = 2
    } else if browserCheckPhase == 2, let child = children.first(where: { $0.isPrivateWindow && $0.host != nil }),
              let privateHost = child.host, privateHost.isPrivateWindow(),
              let snap = child.adapter?.session.queue.sync(execute: { child.adapter?.session.store?.snapshot(windowId: child.windowID) }),
              snap.spaces.count == 1, snap.spaces[0].id == "private",
              snap.spaces[0].pinned.isEmpty, snap.spaces[0].favorites.isEmpty,
              snap.spaces[0].today.count == 1, let item = snap.spaces[0].today.first?.id,
              let tabs = privateHost.tabs() as? [any ARTabAPI], tabs.count == 1, let tab = tabs.first,
              tab.itemId == item, !tab.liveId.isEmpty,
              let browsers = privateHost.checkProfileState()["browsers"] as? [[String: Any]], browsers.count == 1,
              browsers[0]["off_the_record"] as? Bool == true,
              let profile = browsers[0]["profile_pointer"] as? String, !profile.isEmpty,
              let browser = browsers[0]["browser_pointer"] as? String, !browser.isEmpty,
              workspaceRowsMatch(quitBefore, captureCheckRows()) {
      incognitoPrivateLive = tab.liveId
      incognitoPrivateProfile = profile
      incognitoPrivateBrowser = browser
      incognitoWindowID = child.windowID
      incognitoWindowItem = item
      incognitoPrivateItem = item
      incognitoWindowLive = tab.liveId
      if CommandLine.arguments.contains("--ararat-incognito-window-check") {
        // A regular window opened from the private one is a regular child of the root session.
        privateHost.checkNewWindow()
        browserCheckPhase = 30
        return
      }
      // A private new tab is a row in the private workspace; the regular window is untouched.
      incognitoTabsBefore = tabs.count
      privateHost.checkNewTab()
      browserCheckPhase = 21
    } else if browserCheckPhase == 21, let child = children.first(where: { $0.isPrivateWindow && $0.host != nil }),
              let snap = child.adapter?.session.queue.sync(execute: { child.adapter?.session.store?.snapshot(windowId: child.windowID) }),
              snap.spaces.first?.today.count == incognitoTabsBefore + 1,
              let added = snap.spaces.first?.today.first(where: { $0.id != incognitoWindowItem })?.id {
      guard snapshot == browserCheckBefore, workspaceRowsMatch(quitBefore, captureCheckRows()) else {
        finishBrowserCheck(ok: false, values: ["private_command_created_workspace_row": true]); return
      }
      // Close the new row through the adapter: no key-window command is involved.
      child.close(added)
      browserCheckPhase = 22
    } else if browserCheckPhase == 22, let child = children.first(where: { $0.isPrivateWindow && $0.host != nil }),
              let snap = child.adapter?.session.queue.sync(execute: { child.adapter?.session.store?.snapshot(windowId: child.windowID) }),
              snap.spaces.first?.today.count == incognitoTabsBefore, snap.archive.isEmpty {
      // Close removed the row and left no archive entry; the private window stays up.
      child.host?.checkCreateIncognito()
      browserCheckPhase = 25
    } else if browserCheckPhase == 25, children.filter({ $0.isPrivateWindow && $0.host != nil }).count == 2,
              PrivateWorkspaces.liveCount == 2 {
      if let extra = children.last(where: { $0.isPrivateWindow && $0.host != nil }) { extra.host?.close() }
      browserCheckPhase = 26
    } else if browserCheckPhase == 26, children.filter({ $0.isPrivateWindow && $0.host != nil }).count == 1,
              PrivateWorkspaces.liveCount == 1 {
      host.checkNavigateOffTheRecord()
      browserCheckPhase = 3
    } else if browserCheckPhase == 3, children.contains(where: { runtime in
      runtime.isPrivateWindow && (runtime.host?.tabs() as? [any ARTabAPI])?.contains(where: { $0.title == "ararat-otr-navigation" }) == true
    }) {
      let stock = host.checkStockBrowsers()
      let after = captureCheckRows()
      let rowsUnchanged = snapshot == browserCheckBefore && workspaceRowsMatch(quitBefore, after)
      finishBrowserCheck(ok: rowsUnchanged && stock == 0, values: ["case": "incognito-private", "off_the_record": true,
        "off_the_record_navigation": true, "native_private_new_tab": true, "private_command_close": true,
        "private_new_incognito_window": true, "location_search_noop": true, "rows_unchanged": rowsUnchanged,
        "rows_before": quitBefore ?? [], "rows_after": after ?? [], "stock_browsers": stock])
    } else if browserCheckPhase == 30, children.count == 2,
              let child = children.first(where: { !$0.isPrivateWindow && $0.host != nil }),
              let childHost = child.host, childHost.hasBrowser(),
              let privateChild = children.first(where: { $0.isPrivateWindow && $0.host != nil }),
              let privateHost = privateChild.host,
              let privateTabs = privateHost.tabs() as? [any ARTabAPI], privateTabs.count == 1,
              let privateTab = privateTabs.first, privateTab.liveId == incognitoPrivateLive,
              let privateBrowsers = privateHost.checkProfileState()["browsers"] as? [[String: Any]], privateBrowsers.count == 1,
              privateBrowsers[0]["off_the_record"] as? Bool == true,
              privateBrowsers[0]["profile_pointer"] as? String == incognitoPrivateProfile,
              privateBrowsers[0]["browser_pointer"] as? String == incognitoPrivateBrowser,
              let browsers = childHost.checkProfileState()["browsers"] as? [[String: Any]], browsers.count == 1,
              browsers[0]["profile"] as? String == "Default", browsers[0]["off_the_record"] as? Bool == false,
              childHost.profileDirectory() == "Default",
              let rootBrowser = (host.checkProfileState()["browsers"] as? [[String: Any]])?.first,
              let rootProfile = rootBrowser["profile_pointer"] as? String, !rootProfile.isEmpty,
              browsers[0]["profile_pointer"] as? String == rootProfile,
              let privateProfile = privateBrowsers[0]["profile_pointer"] as? String, !privateProfile.isEmpty, privateProfile != rootProfile,
              let tabs = childHost.tabs() as? [any ARTabAPI], tabs.count == 1,
              let item = tabs[0].itemId, !item.isEmpty, tabs[0].liveId != incognitoPrivateLive,
              tabs[0].url.hasPrefix("chrome://newtab/"), childHost.activeItemId() == item,
              let adapter,
              adapter.session.queue.sync(execute: { adapter.session.store?.liveTab(item: item) }) == tabs[0].liveId,
              let before = quitBefore, let rows = captureCheckRows(),
              Self.checkIncognitoRegularWindowRows(before: before, during: rows,
                after: rows.filter { $0.count != 3 || $0[0] != "window" || $0[1] != child.windowID },
                window: child.windowID, item: item) {
      incognitoWindowRows = rows
      incognitoWindowID = child.windowID
      incognitoWindowItem = item
      incognitoWindowLive = tabs[0].liveId
      childHost.close()
      browserCheckPhase = 31
    } else if browserCheckPhase == 31, children.count == 1,
              let privateChild = children.first(where: { $0.isPrivateWindow && $0.host != nil }),
              let privateHost = privateChild.host,
              let tabs = privateHost.tabs() as? [any ARTabAPI],
              let browsers = privateHost.checkProfileState()["browsers"] as? [[String: Any]],
              let adapter,
              let mapping = adapter.session.queue.sync(execute: { () -> (live: String?, item: String?)? in
                guard let store = adapter.session.store else { return nil }
                return (store.liveTab(item: incognitoWindowItem), store.itemForLive(liveId: incognitoWindowLive))
              }),
              tabs.count == 1, tabs[0].liveId == incognitoPrivateLive,
              tabs[0].itemId == incognitoPrivateItem,
              browsers.count == 1, browsers[0]["off_the_record"] as? Bool == true,
              browsers[0]["profile_pointer"] as? String == incognitoPrivateProfile,
              browsers[0]["browser_pointer"] as? String == incognitoPrivateBrowser,
              mapping.live == nil, mapping.item == nil,
              let before = quitBefore, let during = incognitoWindowRows, let after = captureCheckRows() {
      let valid = Self.checkIncognitoRegularWindowRows(before: before, during: during, after: after,
                                                       window: incognitoWindowID, item: incognitoWindowItem)
      finishBrowserCheck(ok: valid && host.checkStockBrowsers() == 0,
        values: ["case": "incognito-regular-window", "regular_window_rows": valid,
                 "child_window_id": incognitoWindowID, "child_item_id": incognitoWindowItem,
                 "private_live": incognitoPrivateLive, "child_live": incognitoWindowLive,
                 "child_live_mapping_cleared": true, "private_state_unchanged": true,
                 "rows_before": before, "rows_during": during,
                 "rows_after": after, "stock_browsers": host.checkStockBrowsers()])
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
      if CommandLine.arguments.contains("--ararat-multiple-close-check"), let adapter {
        let child = Runtime(windowID: UUID().uuidString)
        child.root = self
        do { try child.start(session: adapter.session, shownSpace: "default") }
        catch { finishBrowserCheck(ok: false, values: ["multiple_child_setup": "\(error)"]); return }
        children.append(child)
        child.adapter?.openCommandURL("about:blank?unrelated", expectedSpace: "default", profile: "Default")
        adapter.windowHost(host, showProfile: "Default")
        adapter.openCommandURL("about:blank?multiple", expectedSpace: "default", profile: "Default")
        browserCheckPhase = 501
        return
      }
      for tab in tabs { tab.prepareCheckBeforeUnload() }
      browserCheckPhase = 6
    } else if browserCheckPhase == 501, let child = children.first, let childHost = child.host,
              let childItem = child.snapshot.selectedId,
              let childTab = (childHost.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == childItem && !$0.isLoading }),
              let tabs = host.tabs() as? [any ARTabAPI], tabs.count == 3, tabs.allSatisfy({ !$0.isLoading }),
              let first = snapshot.spaces.first(where: { $0.id == "default" })?.today.first(where: { $0.url == "about:blank" }),
              let second = snapshot.spaces.first(where: { $0.id == "default" })?.today.first(where: { $0.url == "about:blank?multiple" }),
              tabs.contains(where: { $0.itemId == first.id }), tabs.contains(where: { $0.itemId == second.id }) {
      multiCloseChildItem = childItem
      multiCloseChildLive = childTab.liveId
      multiCloseChildSpace = child.snapshot.shownSpaceId ?? ""
      multiCloseChildWindowID = child.windowID
      multiCloseDefaultItems = [first.id, second.id]
      for tab in tabs { tab.prepareCheckBeforeUnload() }
      adapter?.windowHost(host, showProfile: "Profile 1")
      browserCheckPhase = 502
    } else if browserCheckPhase == 502, host.profileDirectory() == "Profile 1", snapshot.shownSpaceId == "named",
              let tabs = host.tabs() as? [any ARTabAPI], tabs.count == 3, tabs.allSatisfy({ $0.checkHasBeforeUnload() }),
              let selected = snapshot.selectedId, host.activeItemId() == selected,
              let rootTab = tabs.first(where: { $0.itemId == selected }), let rootPage = rootTab.view,
              let rows = captureCheckRows() {
      splitCloseExpected = ["Profile 1": selected]
      multiCloseRootLive = rootTab.liveId
      multiCloseRootPage = rootPage
      profileCloseBefore = rows
      multiCloseOriginal = rows
      if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--ararat-cross-window-reverse-check=") }),
         let adapter, let childHost = children.first?.host,
         let row = snapshot.spaces.flatMap(\.today).first(where: { $0.id == selected }), let url = row.url {
        let stage = String(argument.dropFirst("--ararat-cross-window-reverse-check=".count))
        guard ["registered", "resolved"].contains(stage),
              adapter.session.queue.sync(execute: { adapter.session.store?.liveTab(item: selected) != nil }) else {
          finishBrowserCheck(ok: false, values: ["cross_window_reverse_setup": false]); return
        }
        let previous = adapter.onTransaction
        adapter.onTransaction = { [weak self] transaction, applied in
          previous?(transaction, applied)
          if case .command(let id) = transaction.cause, id == self?.childRaceCommand {
            self?.childRaceCompleted = true
            FileHandle.standardError.write(Data("ararat-trace: matrix race selection-completed command=\(id) rev=\(transaction.rev) applied=\(applied)\n".utf8))
          }
        }
        adapter.checkSelectionActivated = { [weak self] id in
          if id == self?.childRaceCommand {
            self?.childRaceActivated = true
            FileHandle.standardError.write(Data("ararat-trace: matrix race selection-activated command=\(id)\n".utf8))
          }
        }
        adapter.checkSelectionDispatch = { [weak self, weak adapter] actual, command, resume in
          guard let self, let adapter else { return }
          guard actual == stage else { resume(); return }
          adapter.checkSelectionDispatch = nil
          self.childRaceCommand = command
          childHost.close()
          resume()
        }
        browserCheckPhase = 505
        if let joined = adapter.checkInFlightSelection(item: selected) {
          if let command = joined.command {
            childRaceCommand = command
            childRaceActivated = joined.activated
            if stage == "registered" || joined.resolved {
              adapter.checkSelectionDispatch = nil
              childHost.close()
            }
          }
        } else {
          adapter.select(id: selected, url: url)
        }
        return
      }
      host.configureProfileCloseCheck(1)
      browserCheckPhase = 503
      if let raceArgument = CommandLine.arguments.first(where: { $0 == "--ararat-cross-window-selection-check" || $0.hasPrefix("--ararat-cross-window-selection-check=") }),
         let child = children.first, let childAdapter = child.adapter,
         let row = child.snapshot.spaces.flatMap(\.today).first(where: { $0.id == multiCloseChildItem }), let url = row.url {
        let stageWanted = raceArgument.contains("=") ? String(raceArgument.split(separator: "=", maxSplits: 1).last ?? "") : "registered"
        guard ["registered", "resolved"].contains(stageWanted) else { finishBrowserCheck(ok: false, values: ["cross_window_setup": false]); return }
        let previous = childAdapter.onTransaction
        childAdapter.onTransaction = { [weak self] transaction, applied in
          previous?(transaction, applied)
          if case .command(let id) = transaction.cause, id == self?.childRaceCommand {
            self?.childRaceCompleted = true
            FileHandle.standardError.write(Data("ararat-trace: matrix race selection-completed command=\(id) rev=\(transaction.rev) applied=\(applied)\n".utf8))
          }
        }
        childAdapter.checkSelectionDispatch = { [weak self, weak childAdapter] stage, command, resume in
          guard let self, let childAdapter else { return }
          guard stage == stageWanted else { resume(); return }
          childAdapter.checkSelectionDispatch = nil
          self.childRaceCommand = command
          childAdapter.checkSelectionActivated = { [weak self] id in
            if id == command {
              self?.childRaceActivated = true
              FileHandle.standardError.write(Data("ararat-trace: matrix race selection-activated command=\(id)\n".utf8))
            }
          }
          host.close()
          resume()
        }
        childAdapter.select(id: multiCloseChildItem, url: url)
      } else { host.close() }
    } else if browserCheckPhase == 503 {
      let state = host.checkProfileCloseState()
      guard state["dialogs"] as? Int == 1, state["closing"] as? Bool == false, multipleCloseChildValid(),
            let pages = state["dialog_pages"] as? [[String: Any]], pages.count == 1 else { return }
      if CommandLine.arguments.contains(where: { $0 == "--ararat-cross-window-selection-check" || $0.hasPrefix("--ararat-cross-window-selection-check=") }) {
        guard childRaceActivated, childRaceCompleted, let command = childRaceCommand,
              let childAdapter = children.first?.adapter else { return }
        let wasPending = childAdapter.session.queue.sync { childAdapter.session.store?.liveCancel(commandId: command) }
        guard wasPending == false else { finishBrowserCheck(ok: false, values: ["cross_window_pending": true]); return }
        profileCheckResult["cross_window_selection"] = true
      }
      guard let rows = captureCheckRows(), let original = multiCloseOriginal,
            rows.filter({ !["window", "last_selected"].contains($0.first ?? "") }) == original.filter({ !["window", "last_selected"].contains($0.first ?? "") }),
            multipleClosePagesValid(pages, defaultCount: 1, namedCount: 0),
            snapshot.selectedId == host.activeItemId() else { finishBrowserCheck(ok: false, values: ["multiple_first_cancel": state]); return }
      profileCheckResult["multiple_first_cancel"] = state.merging(["selected_matches_active": true, "child_unchanged": true, "workspace_rows_unchanged": true]) { _, new in new }
      profileCloseBefore = captureCheckRows()
      host.configureProfileCloseCheck(2)
      browserCheckPhase = 504
      host.close()
    } else if browserCheckPhase == 505, children.isEmpty, childRaceActivated, childRaceCompleted,
              let command = childRaceCommand, let adapter,
              snapshot.shownSpaceId == "named", snapshot.selectedId == splitCloseExpected["Profile 1"],
              host.profileDirectory() == "Profile 1", host.activeItemId() == snapshot.selectedId {
      let wasPending = adapter.session.queue.sync { adapter.session.store?.liveCancel(commandId: command) }
      let active = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == snapshot.selectedId })
      let presentation = active.map { host.checkPagePresentation($0.liveId) } ?? [:]
      let attached = presentation["presented"] as? Bool == true
      let expectedRows = profileCloseBefore?.filter { !($0.count >= 2 && $0[0] == "window" && $0[1] == multiCloseChildWindowID) }
      let rowsUnchanged = expectedRows != nil && captureCheckRows() == expectedRows
      let passed = wasPending == false && attached && active?.liveId == multiCloseRootLive && active?.view === multiCloseRootPage &&
        rowsUnchanged && host.checkStockBrowsers() == 0
      if passed { host.configureProfileCloseCheck(0) }
      finishBrowserCheck(ok: passed, values: ["case": "cross-window-reverse", "u16_complete": false,
        "dispatch_boundary": CommandLine.arguments.first(where: { $0.hasPrefix("--ararat-cross-window-reverse-check=") }).map { String($0.split(separator: "=").last ?? "") } ?? "",
        "cross_window_reverse": passed, "rows_unchanged": rowsUnchanged,
        "expected_page_live": multiCloseRootLive, "page_presentation": presentation])
    } else if browserCheckPhase == 504 {
      let state = host.checkProfileCloseState()
      guard state["dialogs"] as? Int == 2, state["closing"] as? Bool == false, multipleCloseChildValid(),
            let pages = state["dialog_pages"] as? [[String: Any]], pages.count == 2 else { return }
      guard let rows = captureCheckRows(), let original = multiCloseOriginal,
            rows.filter({ !["window", "last_selected"].contains($0.first ?? "") }) == original.filter({ !["window", "last_selected"].contains($0.first ?? "") }),
            multipleClosePagesValid(pages, defaultCount: 2, namedCount: 0),
            snapshot.selectedId == host.activeItemId() else { finishBrowserCheck(ok: false, values: ["multiple_second_cancel": state]); return }
      profileCheckResult["multiple_second_cancel"] = state.merging(["selected_matches_active": true, "child_unchanged": true, "workspace_rows_unchanged": true]) { _, new in new }
      profileCloseBefore = captureCheckRows()
      host.configureProfileCloseCheck(0)
      browserCheckPhase = 8
      host.close()
    } else if browserCheckPhase == 6, let tabs = host.tabs() as? [any ARTabAPI], tabs.count == 2,
              tabs.allSatisfy({ $0.checkHasBeforeUnload() }), let rows = captureCheckRows() {
      guard let named = snapshot.selectedId,
            let original = snapshot.spaces.first(where: { $0.id == "default" })?.today.first?.id else { return }
      splitCloseExpected = ["Default": original, "Profile 1": named]
      if CommandLine.arguments.contains("--ararat-split-close-check") {
        guard let adapter else { return }
        do { try adapter.session.queue.sync { _ = try adapter.session.store?.selectItem(windowId: windowID, id: "close-split") } }
        catch { finishBrowserCheck(ok: false, values: ["split_setup_error": "\(error)"]); return }
        adapter.windowHost(host, showProfile: "Default")
        browserCheckPhase = 60
        return
      }
      profileCloseBefore = rows
      browserCheckPhase = 7
      beginCloseRaceCheck(host) { host.configureProfileCloseCheck(2); host.close() }
    } else if browserCheckPhase == 60, host.profileDirectory() == "Default",
              snapshot.shownSpaceId == "default", snapshot.selectedId == splitCloseExpected["Default"],
              host.activeItemId() == snapshot.selectedId,
              let active = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == snapshot.selectedId }),
              let page = active.view, let rows = captureCheckRows() {
      splitCloseBefore = snapshot
      splitPanelBeforeRows = rows
      splitPanelLive = active.liveId
      splitPanelPage = page
      openCommandBar(.newTab)
      guard let bar = commandPresenter?.controller, bar.isOpen else {
        finishBrowserCheck(ok: false, values: ["split_panel_open": false]); return
      }
      bar.update(query: "Profile 1")
      browserCheckPhase = 61
    } else if browserCheckPhase == 61, let bar = commandPresenter?.controller, bar.isOpen {
      guard let index = bar.result.rows.firstIndex(where: { row in
        if case .space(let id) = row.target { return id == "named" }
        return false
      }) else { return }
      bar.moveSelection(by: index - bar.selectedIndex)
      bar.commit(forceNewTab: false)
      browserCheckPhase = 62
    } else if browserCheckPhase == 62, snapshot.shownSpaceId == "named",
              snapshot.selectedId == "close-split-a", host.activeItemId() == snapshot.selectedId,
              splitCheckPagesPresented(host), let rows = captureCheckRows() {
      profileCheckResult["split_panel_selected"] = true
      if CommandLine.arguments.contains(where: { $0.hasPrefix("--ararat-selection-supersede=") }), let adapter {
        adapter.windowHost(host, showProfile: "Default")
        browserCheckPhase = 67
        return
      }
      if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--ararat-committed-switch-race=") }),
         let adapter {
        let kind = String(argument.dropFirst("--ararat-committed-switch-race=".count))
        guard ["space", "tab"].contains(kind), let target = splitCloseExpected["Profile 1"] else {
          finishBrowserCheck(ok: false, values: ["committed_switch_setup": false]); return
        }
        if kind == "space" {
          do {
            try adapter.session.queue.sync {
              guard let store = adapter.session.store else { throw NSError(domain: "Ararat.check", code: 1) }
              _ = try store.showSpaceSelectingTab(windowId: windowID, spaceId: "named", itemId: target)
              _ = try store.showSpaceSelecting(windowId: windowID, spaceId: "default")
            }
          } catch { finishBrowserCheck(ok: false, values: ["committed_switch_setup": "\(error)"]); return }
          adapter.refresh()
        } else {
          adapter.windowHost(host, showProfile: "Default")
        }
        browserCheckPhase = 64
        return
      }
      if CommandLine.arguments.contains("--ararat-empty-close-check"), let adapter {
        do {
          _ = try adapter.session.queue.sync {
            try adapter.session.store?.showSpace(windowId: windowID, spaceId: "default")
            return try adapter.session.store?.createSpace(windowId: windowID, name: "Empty", spaceId: "close-empty")
          }
        } catch { finishBrowserCheck(ok: false, values: ["empty_setup_error": "\(error)"]); return }
        adapter.refresh()
        browserCheckPhase = 63
        return
      }
      splitCloseBefore = snapshot
      profileCloseBefore = rows
      browserCheckPhase = 7
      beginCloseRaceCheck(host) { host.configureProfileCloseCheck(2); host.close() }
    } else if browserCheckPhase == 67, snapshot.shownSpaceId == "default", host.profileDirectory() == "Default",
              let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--ararat-selection-supersede=") }),
              let adapter, let target = splitCloseExpected["Profile 1"], let current = splitCloseExpected["Default"],
              snapshot.selectedId == current, host.activeItemId() == current,
              let active = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == current }),
              let page = active.view, let rows = captureCheckRows(),
              let targetRow = snapshot.spaces.flatMap(\.today).first(where: { $0.id == target }), let targetURL = targetRow.url,
              let currentRow = snapshot.spaces.flatMap(\.today).first(where: { $0.id == current }), let currentURL = currentRow.url {
      let stage = String(argument.dropFirst("--ararat-selection-supersede=".count))
      guard ["registered", "resolved"].contains(stage), adapter.session.queue.sync(execute: { adapter.session.store?.liveTab(item: target) != nil }) else {
        finishBrowserCheck(ok: false, values: ["selection_supersede_setup": false]); return
      }
      splitCloseBefore = snapshot
      splitPanelBeforeRows = rows
      splitPanelLive = active.liveId
      splitPanelPage = page
      splitCloseRaceCommand = nil
      splitCloseRaceSettled = false
      splitCloseRaceFailed = false
      splitCloseRaceActivated = false
      adapter.checkSelectionDispatch = { [weak self, weak adapter] actual, command, resume in
        guard let self, let adapter else { return }
        guard actual == stage else { resume(); return }
        adapter.checkSelectionDispatch = nil
        self.splitCloseRaceCommand = command
        adapter.checkSelectionActivated = { [weak self] id in
          if id == command { self?.splitCloseRaceActivated = true }
        }
        adapter.select(id: current, url: currentURL)
        resume()
      }
      adapter.select(id: target, url: targetURL)
      browserCheckPhase = 66
    } else if browserCheckPhase == 66, selectionRaceSettled(), let before = splitCloseBefore,
              let rows = captureCheckRows() {
      guard !splitCloseRaceFailed, snapshot == before, rows == splitPanelBeforeRows,
            host.profileDirectory() == "Default", host.activeItemId() == before.selectedId,
            let active = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == before.selectedId }),
            active.liveId == splitPanelLive, active.view === splitPanelPage else {
        finishBrowserCheck(ok: false, values: ["selection_supersede_failed": true]); return
      }
      profileCheckResult["selection_supersession"] = true
      profileCloseBefore = rows
      host.configureProfileCloseCheck(2)
      browserCheckPhase = 7
      host.close()
    } else if browserCheckPhase == 63, snapshot.shownSpaceId == "close-empty", snapshot.selectedId == nil,
              host.profileDirectory() == "Default", !host.hasActiveTab(), let rows = captureCheckRows() {
      splitCloseBefore = snapshot
      profileCloseBefore = rows
      host.configureProfileCloseCheck(2)
      browserCheckPhase = 7
      host.close()
    } else if browserCheckPhase == 64, snapshot.shownSpaceId == "default",
              host.profileDirectory() == "Default", let adapter, let workspace,
              let target = splitCloseExpected["Profile 1"] {
      let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--ararat-committed-switch-race=") }) ?? ""
      let kind = String(argument.dropFirst("--ararat-committed-switch-race=".count))
      workspace.checkSpaceSwitchCompletion = { [weak self, weak workspace, weak adapter] actual, resume in
        guard let self, let workspace, let adapter else { return }
        guard actual == kind else { resume(); return }
        workspace.checkSpaceSwitchCompletion = nil
        let committed = adapter.session.queue.sync { adapter.session.store?.snapshot(windowId: self.windowID) }
        guard let committed, committed.shownSpaceId == "named", committed.selectedId == target,
              host.profileDirectory() == "Default", let rows = self.captureCheckRows() else {
          self.finishBrowserCheck(ok: false, values: ["committed_switch_before_close": false]); return
        }
        self.committedSwitchRace = true
        self.splitCloseBefore = committed
        self.profileCloseBefore = rows
        host.configureProfileCloseCheck(2)
        self.browserCheckPhase = 7
        host.close()
        resume()
      }
      browserCheckPhase = 65
      if kind == "space" {
        guard let index = snapshot.spaces.firstIndex(where: { $0.id == "named" }) else { return }
        sidebar?.showSpace(at: index)
      } else {
        openCommandBar(.newTab)
        guard let bar = commandPresenter?.controller else { finishBrowserCheck(ok: false, values: ["committed_tab_panel": false]); return }
        bar.commit(Suggestion(title: "Profile 1 tab", subtitle: "", url: nil, key: nil,
                              target: .tab(id: target, spaceId: "named"), score: 0))
      }
    } else if browserCheckPhase == 7 {
      let closeState = host.checkProfileCloseState()
      guard closeState["dialogs"] as? Int == 2, closeState["closing"] as? Bool == false else { return }
      let after = captureCheckRows()
      guard let after else { return }
      guard profileCloseAfterPrevious == after else { profileCloseAfterPrevious = after; return }
      guard selectionRaceSettled() else { return }
      let rowsKept = after.filter { $0.first != "window" } == profileCloseBefore?.filter { $0.first != "window" }
      let expectedProfile = splitCloseBefore?.spaces.first(where: { $0.id == splitCloseBefore?.shownSpaceId })?.profileName ?? "Default"
      let splitRendered = splitCloseBefore?.selectedId != "close-split-a" || splitCheckPagesPresented(host)
      let reconciled = splitCloseBefore != nil && expectedProfile != "Profile 1" &&
        snapshot.shownSpaceId == "named" && snapshot.selectedId == "close-split-a" &&
        host.profileDirectory() == "Profile 1" && host.activeItemId() == snapshot.selectedId && splitCheckPagesPresented(host) &&
        after.filter { !["window", "last_selected"].contains($0.first ?? "") } ==
          profileCloseBefore?.filter { !["window", "last_selected"].contains($0.first ?? "") } &&
        after.filter { $0.first == "last_selected" && ![splitCloseBefore?.selectedId, "close-split-a", "close-split-b"].contains($0.dropFirst().first) } ==
          profileCloseBefore?.filter { $0.first == "last_selected" && ![splitCloseBefore?.selectedId, "close-split-a", "close-split-b"].contains($0.dropFirst().first) }
      let splitOK = splitCloseBefore == nil || reconciled || (after == profileCloseBefore && snapshot.shownSpaceId == splitCloseBefore?.shownSpaceId &&
        snapshot.selectedId == splitCloseBefore?.selectedId && host.profileDirectory() == expectedProfile &&
        (snapshot.selectedId == nil ? !host.hasActiveTab() : host.activeItemId() == snapshot.selectedId) && splitRendered && splitClosePagesMatch(closeState))
      let valid = closeState["browsers"] as? Int == 2 && closeState["closed"] as? Bool == false && splitOK &&
        splitClosePagesMatch(closeState) && !splitCloseRaceFailed &&
        closeState["close_cancelled"] as? Int == 1 &&
        closeState["beforeunload_profiles"] as? [String] == ["Default", "Profile 1"] && (rowsKept || reconciled)
      profileCloseCancelled = closeState.merging(["rows_unchanged": rowsKept, "host_open": true,
        "split_cancel_restored": splitOK, "profile_reconciled": reconciled,
        "selection_race_settled": splitCloseRaceSettled, "selection_race_activated": splitCloseRaceActivated,
        "selection_race_failed": splitCloseRaceFailed]) { _, new in new }
      profileCheckPassed = profileCheckPassed && valid
      if committedSwitchRace { profileCheckResult["committed_switch_race"] = valid }
      if reconciled { profileCloseBefore = after }
      browserCheckPhase = 8
      beginCloseRaceCheck(host) { host.configureProfileCloseCheck(0); host.close() }
    }
  }

  func beginCloseRaceCheck(_ host: any ARWindowHostAPI, close: @escaping () -> Void) {
    let prefix = "--ararat-selection-race="
    guard let value = CommandLine.arguments.first(where: { $0.hasPrefix(prefix) }) else { close(); return }
    let stage = String(value.dropFirst(prefix.count))
    splitCloseRaceCommand = nil
    splitCloseRaceSettled = false
    splitCloseRaceFailed = false
    splitCloseRaceActivated = false
    guard ["registered", "resolved"].contains(stage), let adapter, let item = splitCloseExpected["Profile 1"] ?? snapshot.selectedId,
          let row = snapshot.spaces.flatMap({ $0.today + $0.pinned + $0.favorites }).first(where: { $0.id == item }),
          let url = row.url, adapter.session.queue.sync(execute: { adapter.session.store?.liveTab(item: item) != nil }) else {
      if quitMode != nil { quitTimedOut = true; finishQuitCheck(exitCode: 1) }
      else { finishBrowserCheck(ok: false, values: ["selection_race_setup": false]) }
      return
    }
    adapter.checkSelectionDispatch = { [weak self, weak adapter] actual, command, resume in
      guard let self, let adapter else { return }
      guard actual == stage else { resume(); return }
      adapter.checkSelectionDispatch = nil
      self.splitCloseRaceCommand = command
      adapter.checkSelectionActivated = { [weak self] id in
        if id == command { self?.splitCloseRaceActivated = true }
      }
      close()
      resume()
    }
    adapter.select(id: item, url: url)
  }

  func selectionRaceSettled() -> Bool {
    guard CommandLine.arguments.contains(where: { $0.hasPrefix("--ararat-selection-race=") || $0.hasPrefix("--ararat-selection-supersede=") }) else { return true }
    if splitCloseRaceSettled { return true }
    guard let command = splitCloseRaceCommand, let adapter else { return false }
    let wasPending = adapter.session.queue.sync { adapter.session.store?.liveCancel(commandId: command) }
    guard let wasPending else { return false }
    splitCloseRaceFailed = wasPending || splitCloseRaceActivated
    splitCloseRaceSettled = true
    return splitCloseRaceSettled
  }

  func splitClosePagesMatch(_ state: [String: Any]) -> Bool {
    guard let pages = state["dialog_pages"] as? [[String: Any]], pages.count == 2 else { return false }
    return pages.allSatisfy { page in
      guard let profile = page["profile"] as? String else { return false }
      return page["item"] as? String == splitCloseExpected[profile] &&
        page["active"] as? Bool == true && page["presented"] as? Bool == true
    } && Set(pages.compactMap { $0["profile"] as? String }) == Set(splitCloseExpected.keys)
  }

  func multipleCloseChildValid() -> Bool {
    guard let child = children.first, let host = child.host,
          child.snapshot.shownSpaceId == multiCloseChildSpace, child.snapshot.selectedId == multiCloseChildItem,
          host.activeItemId() == multiCloseChildItem,
          let tab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == multiCloseChildItem }) else { return false }
    return tab.liveId == multiCloseChildLive && host.checkPagePresentation(tab.liveId)["presented"] as? Bool == true &&
      !host.isClosing() && !host.isClosingAll()
  }

  static func multipleQuitSetupItems(snapshot: WorkspaceSnapshot, expected: [String: String],
                                      rootTabs: [(item: String?, live: String, loading: Bool)],
                                      childItem: String, childLive: String, mappings: [String: String],
                                      reverse: [String: String], profiles: [String: String]) -> [String]? {
    guard let first = expected["Default"], !first.isEmpty, let named = expected["Profile 1"], !named.isEmpty,
          let defaultSpace = snapshot.spaces.first(where: { $0.id == "default" && $0.profileName == "Default" }),
          let namedSpace = snapshot.spaces.first(where: { $0.id == "named" && $0.profileName == "Profile 1" }),
          defaultSpace.today.contains(where: { $0.id == first && $0.url != nil }),
          namedSpace.today.contains(where: { $0.id == named && $0.url != nil }),
          let second = defaultSpace.today.first(where: { $0.url == "about:blank?multiple" })?.id,
          defaultSpace.today.contains(where: { $0.id == childItem && $0.url == "about:blank?unrelated" }),
          !second.isEmpty, !childItem.isEmpty, Set([first, second, named, childItem]).count == 4, !childLive.isEmpty,
          rootTabs.count == 3, rootTabs.allSatisfy({ !$0.loading && !$0.live.isEmpty && $0.item != nil }),
          Set(rootTabs.compactMap(\.item)) == Set([first, second, named]),
          Set(rootTabs.map(\.live)).count == 3, !rootTabs.contains(where: { $0.live == childLive }) else { return nil }
    for tab in rootTabs {
      guard let item = tab.item, mappings[item] == tab.live, reverse[tab.live] == item,
            profiles[item] == (item == named ? "Profile 1" : "Default") else { return nil }
    }
    guard mappings[childItem] == childLive, reverse[childLive] == childItem, profiles[childItem] == "Default" else { return nil }
    return [first, second]
  }

  func multipleClosePagesValid(_ pages: [[String: Any]], defaultCount: Int, namedCount: Int) -> Bool {
    let defaults = pages.filter { $0["profile"] as? String == "Default" }
    let named = pages.filter { $0["profile"] as? String == "Profile 1" }
    return defaults.count == defaultCount && named.count == namedCount && defaults.count + named.count == pages.count &&
      Set(defaults.compactMap { $0["item"] as? String }).count == defaultCount &&
      defaults.allSatisfy { page in
        guard let item = page["item"] as? String else { return false }
        return multiCloseDefaultItems.contains(item) && page["active"] as? Bool == true && page["presented"] as? Bool == true
      } && named.allSatisfy { page in
        page["item"] as? String == splitCloseExpected["Profile 1"] &&
          page["active"] as? Bool == true && page["presented"] as? Bool == true
      }
  }

  func multipleClosePagesValidInAnyOrder(_ pages: [[String: Any]]) -> Bool {
    let defaults = pages.filter { $0["profile"] as? String == "Default" }.count
    let named = pages.filter { $0["profile"] as? String == "Profile 1" }.count
    return defaults <= 2 && named <= 1 && multipleClosePagesValid(pages, defaultCount: defaults, namedCount: named)
  }

  func extensionScreenTick(_ host: any ARWindowHostAPI) {
    let id = "kmgaadhbnkendcanjninlfmfgehagggl"
    if browserCheckPhase == 0, let row = sliceRows.first, let url = row.url {
      browserCheckSeedID = row.id
      browserCheckPhase = 1
      adapter?.select(id: row.id, url: url)
      return
    }
    guard let tab = (host.tabs() as? [any ARTabAPI])?.first, !tab.isLoading,
          tab.navigationCount > 0, let sidebar else { return }
    if browserCheckPhase == 1, host.window().isKeyWindow,
       snapshot.selectedId == browserCheckSeedID, host.activeItemId() == browserCheckSeedID,
       extensionItems.contains(where: { $0.id == id }) {
      guard ["done", "unchanged"].contains(adapter?.setExtensionPinned(id, pinned: true) ?? "") else { return }
      browserCheckPhase = 2
    } else if browserCheckPhase == 2, sidebar.checkInFieldActionIDs.contains(id),
              let button = sidebar.checkActionButton(id) {
      devtoolsResults["action_anchor"] = rectFields(button.anchorInWindow)
      sidebar.checkPerformExtensionAction(id)
      browserCheckPhase = 3
    } else if browserCheckPhase == 3 {
      let state = host.checkExtensionActionPopup()
      if browserCheckAttempts % 50 == 0 {
        let item = extensionItems.first { $0.id == id }
        FileHandle.standardError.write(Data("ararat-trace: screen-extensions waiting=action-popup id=\(id) pinned=\(item?.pinned ?? false) anchor=\(String(describing: lastExtensionAnchor)) state=\(state)\n".utf8))
      }
      guard state["shown"] as? Bool == true else { return }
      devtoolsResults["action_popup"] = true
      host.checkDismissExtensionActionPopup()
      tab.checkExtensionPopupWindow(false)
      browserCheckPhase = 61
    } else if browserCheckPhase == 61, let popup = popups.first?.host, popup.checkIsExtensionAppPopup(),
              let rows = captureCheckRows() {
      quitBefore = rows
      popup.checkNavigate("data:text/html,<title>Ararat save check</title>save", disposition: "current")
      popup.window().makeKeyAndOrderFront(nil)
      browserCheckPhase = 62
    } else if browserCheckPhase == 62, let popup = popups.first?.host, popup.window().isKeyWindow,
              let page = (popup.tabs() as? [any ARTabAPI])?.first, page.title == "Ararat save check", !page.isLoading {
      guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: popup.window().windowNumber,
          context: nil, characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1) else { return }
      NSApp.sendEvent(event)
      browserCheckPhase = 63
    } else if browserCheckPhase == 63, let popup = popups.first?.host, popup.checkPageOnlySaveCount() == 1,
              let save = NSApp.windows.compactMap({ $0 as? NSSavePanel }).first(where: { $0.isVisible }) {
      guard pageOnlyRowsUnchanged(quitBefore, captureCheckRows()) else { finishBrowserCheck(ok: false, values: ["page_only_menu_rows": false]); return }
      save.cancel(nil)
      browserCheckPhase = 64
    } else if browserCheckPhase == 64, let popup = popups.first?.host,
              !NSApp.windows.contains(where: { $0 is NSSavePanel && $0.isVisible }) {
      let unchanged = pageOnlyRowsUnchanged(quitBefore, captureCheckRows())
      devtoolsResults["page_only_save"] = true
      devtoolsResults["app_popup"] = popup.checkIsExtensionAppPopup()
      devtoolsResults["rows_unchanged"] = unchanged
      finishBrowserCheck(ok: unchanged && popup.checkIsExtensionAppPopup() && popup.checkPageOnlySaveCount() == 1 && host.checkStockBrowsers() == 0,
                         values: devtoolsResults)
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
      popup.checkKeyboardCommand("window")
      browserCheckPhase = 20
    } else if browserCheckPhase == 20, let child = children.first(where: { $0.host != nil }),
              let childHost = child.host, childHost.hasBrowser() {
      childHost.close()
      browserCheckPhase = 21
    } else if browserCheckPhase == 21, children.allSatisfy({ $0.host == nil }), let popup = popups.first?.host {
      popup.checkKeyboardCommand("incognito")
      browserCheckPhase = 22
    } else if browserCheckPhase == 22, popups.count == 2, let privateHost = popups.last?.host,
              (privateHost.checkProfileState()["browsers"] as? [[String: Any]])?.first?["off_the_record"] as? Bool == true {
      privateHost.checkKeyboardCommand("close")
      browserCheckPhase = 23
    } else if browserCheckPhase == 23, popups.count == 1 {
      browserCheckBefore = snapshot
      browserCheckPhase = 3
      tab.checkExtensionPopupWindow(true)
    } else if browserCheckPhase == 3, popups.isEmpty,
              let data = tab.title.data(using: .utf8),
              let report = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let result = report["popupResult"] as? [String: Any], result["removed"] as? Bool == true {
      browserCheckPhase = 4
      tab.checkExtensionPopupWindow(false)
    } else if browserCheckPhase == 4, let popup = popups.first?.host, popup.checkIsExtensionAppPopup() {
      popup.checkKeyboardCommand("close")
      browserCheckPhase = 5
    } else if browserCheckPhase == 5, popups.isEmpty {
      let before = browserCheckBefore?.spaces.flatMap { $0.today + $0.pinned + $0.favorites }.map(\.id)
      let after = snapshot.spaces.flatMap { $0.today + $0.pinned + $0.favorites }.map(\.id)
      let stock = host.checkStockBrowsers()
      let unchanged = before == after
      finishBrowserCheck(ok: unchanged && stock == 0 && hiddenPopupSafe(),
        values: ["app_popup": true, "windows_type": "popup", "popup_removed": true, "command_close": true,
                 "native_new_window": true, "native_new_incognito_window": true,
                 "rows_unchanged": unchanged, "stock_browsers": stock])
    }
  }

  func hiddenPopupSafe() -> Bool {
    let front = checkFrontApplication()
    return popupWindowsHidden && !NSApp.windows.contains { $0.isVisible || $0.isKeyWindow } &&
      !(popupFrontBefore ?? "").isEmpty && front == popupFrontBefore && popupFrontChange == nil
  }

  func checkFrontApplication() -> String? {
    if browserCheckMode == "keyboard" {
      return NSWorkspace.shared.frontmostApplication.map { String($0.processIdentifier) }
    }
    return commandOutput("/usr/bin/lsappinfo", ["front"])
  }

  func resetFullscreenProbe() {
    fullscreenProbeGeneration += 1
    fullscreenElement = nil
    fullscreenProbePending = false
  }

  func probeFullscreen(_ tab: any ARTabAPI) {
    guard !fullscreenProbePending else { return }
    fullscreenProbePending = true
    let generation = fullscreenProbeGeneration
    tab.checkFullscreenElement { [weak self] value in
      MainActor.assumeIsolated {
        guard let self, self.fullscreenProbeGeneration == generation else { return }
        self.fullscreenElement = value
        self.fullscreenProbePending = false
      }
    }
  }

  func fullscreenCheckTick(_ host: any ARWindowHostAPI, screen: Bool) {
    let tabs = host.tabs() as? [any ARTabAPI] ?? []
    let state = host.checkFullscreenState()
    let windowFull = state["window"] as? Bool == true
    let tabFull = state["tab"] as? Bool == true
    let cardFull = promptPageCard?.frame == container?.bounds
    if screen { fullscreenScreenTick(host, tabs: tabs, state: state); return }
    switch browserCheckPhase {
    case 0:
      guard let row = sliceRows.first, let url = row.url else { return }
      browserCheckSeedID = row.id
      adapter?.select(id: row.id, url: url)
      browserCheckPhase = 1
    case 1:
      guard sliceActive == browserCheckSeedID, let tab = tabs.first,
            !tab.isLoading, tab.navigationCount > 0 else { return }
      fullscreenTab = tab
      fullscreenCardBefore = promptPageCard?.frame ?? .zero
      host.checkNavigate("data:text/html,<title>Fullscreen other</title>", disposition: "background")
      browserCheckPhase = 2
    case 2:
      guard tabs.count >= 2, let original = fullscreenTab,
            let other = tabs.first(where: { $0.liveId != original.liveId }), !other.isLoading,
            !original.isLoading, host.activeItemId() == original.itemId else { return }
      fullscreenOtherTab = other
      if fullscreenRound == 0, let view = original.view, let window = view.window {
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        if let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
          eventNumber: 0, clickCount: 0, pressure: 0) {
          fullscreenResults["mouse_sent"] = original.sendCheckMouseMoved(event)
        }
      }
      resetFullscreenProbe()
      original.checkFullscreenRequest(true)
      browserCheckPhase = 3
    case 3:
      guard let tab = fullscreenTab else { return }
      probeFullscreen(tab)
      guard tabFull, windowFull, fullscreenElement == true, cardFull,
            state["bubble_created"] as? Bool == true, state["bubble_visible"] as? Bool == false,
            container?.pageFullscreen == true else { return }
      fullscreenResults["entry_\(fullscreenRound)"] = true
      resetFullscreenProbe()
      switch fullscreenRound {
      case 0: host.checkFullscreenAction(0)
      case 1: tab.checkFullscreenRequest(false)
      case 2:
        fullscreenNavigation = tab.navigationCount
        host.checkNavigate("data:text/html,<title>Fullscreen navigated</title>", disposition: "current")
      case 3: host.checkFullscreenAction(2)
      case 4: host.checkFullscreenAction(3)
      default: host.checkFullscreenAction(4)
      }
      browserCheckPhase = 4
    case 4:
      guard !tabFull, !windowFull, container?.pageFullscreen == false,
            fullscreenCardBefore != .zero, promptPageCard?.frame == fullscreenCardBefore else { return }
      if fullscreenRound == 4 {
        guard let other = fullscreenOtherTab, let item = other.itemId, host.activeItemId() == item else { return }
      }
      if fullscreenRound == 5, let tab = fullscreenTab {
        guard !tabs.contains(where: { $0.liveId == tab.liveId }) else { return }
      }
      if fullscreenRound != 5, let tab = fullscreenTab {
        guard !tab.isLoading else { return }
        if fullscreenRound == 2, tab.navigationCount <= fullscreenNavigation { return }
        probeFullscreen(tab)
        guard fullscreenElement == false else { return }
      }
      let names = ["escape", "document_exit", "navigation", "native_exit", "tab_switch", "tab_close"]
      fullscreenResults[names[fullscreenRound]] = true
      if fullscreenRound == 4 {
        host.checkFullscreenAction(3)
      }
      fullscreenRound += 1
      if fullscreenRound == names.count {
        fullscreenTab = fullscreenOtherTab
        host.checkFullscreenAction(1)
        browserCheckPhase = 5
      } else {
        browserCheckPhase = 2
      }
    case 5:
      guard windowFull, state["browser"] as? Bool == true, let tab = fullscreenTab else { return }
      resetFullscreenProbe()
      tab.checkFullscreenRequest(true)
      browserCheckPhase = 6
    case 6:
      guard let tab = fullscreenTab else { return }
      probeFullscreen(tab)
      guard tabFull, fullscreenElement == true, cardFull else { return }
      resetFullscreenProbe()
      host.checkFullscreenAction(0)
      browserCheckPhase = 7
    case 7:
      guard let tab = fullscreenTab else { return }
      probeFullscreen(tab)
      guard !tabFull, windowFull, state["browser"] as? Bool == true,
            fullscreenElement == false, container?.pageFullscreen == false else { return }
      fullscreenResults["return_to_browser"] = true
      host.checkFullscreenAction(5)
      browserCheckPhase = 8
    case 8:
      guard host.hasBrowser(forProfile: "Fullscreen Check"), host.hasBrowser() else { return }
      let completionWithoutBrowser = state["completion_without_browser"] as? Bool == true
      fullscreenResults["completion_without_browser"] = completionWithoutBrowser
      fullscreenResults["shown_profile"] = host.profileDirectory()
      fullscreenResults["fullscreen_check_has_browser"] = true
      let count = dlsym(Launcher.handle, "AraratExclusiveInputCount").map {
        unsafeBitCast($0, to: (@convention(c) () -> UInt).self)()
      } ?? 0
      fullscreenResults["exclusive_input_seen"] = count > 0
      fullscreenResults["stock_browsers"] = host.checkStockBrowsers()
      let hidden = popupWindowsHidden && !NSApp.windows.contains { $0.isVisible || $0.isKeyWindow }
      let front = commandOutput("/usr/bin/lsappinfo", ["front"])
      let frontUnchanged = !(popupFrontBefore ?? "").isEmpty && front == popupFrontBefore && popupFrontChange == nil && !fullscreenActivated
      fullscreenResults["windows_hidden"] = hidden
      fullscreenResults["front_unchanged"] = frontUnchanged
      fullscreenResults["front_change"] = popupFrontChange ?? [:]
      fullscreenResults["app_activated"] = fullscreenActivated
      finishBrowserCheck(ok: completionWithoutBrowser && count > 0 && fullscreenResults["mouse_sent"] as? Bool == true && host.checkStockBrowsers() == 0 && hidden && frontUnchanged, values: fullscreenResults)
    default: break
    }
  }

  func organizeConditionNames(screen: Bool) -> [String] {
    ["seed", "today_to_pinned", "pin_hint", "folder_open_nested_insert", "pinned_to_favorites", "dock_no_switch", "folder_drag_refused", "escape_cancel", "first_favorite_drop", "folder_hover_opens", "hover_drop"] + (screen ? ["drop_line_image"] : [])
  }

  func organizeCheckTick(_ host: any ARWindowHostAPI, screen: Bool) {
    guard let sidebar, let session = adapter?.session else { return }
    let current = session.queue.sync { session.store?.snapshot(windowId: windowID) }
    guard let current, let space = current.spaces.first(where: { $0.id == "organize-work" }),
          let other = current.spaces.first(where: { $0.id == "organize-other" }) else { return }
    func row(_ name: String) -> Row? {
      current.spaces.flatMap { $0.pinned + $0.today + $0.favorites }.first { $0.url == "about:blank?organize-\(name)" }
    }
    func begin(_ name: String, _ destination: String) -> Bool {
      guard sidebar.organizeCheckIdle, let id = row(name)?.id else { return false }
      return sidebar.organizeCheckBegin(id: id, destination: destination)
    }
    switch browserCheckPhase {
    case 0:
      guard space.favorites.count == 2, space.today.count == 1, space.pinned.contains(where: { $0.id == "organize-inner" }) else { return }
      organizeConditions["seed"] = true
      guard begin("today", "organize-outer") else { return }
      organizeConditions["drop_line_image"] = !screen || sidebar.organizeCheckDropLine
      if screen, sidebar.organizeCheckDropLine { organizeImage = promptScreenScreenshot(host.window(), name: "organize-drop", withoutShadow: true) }
      if screen { organizeConditions["drop_line_image"] = organizeImage != nil }
      browserCheckPhase = 1
    case 1:
      guard sidebar.organizeCheckEnd() else { return }
      browserCheckPhase = 2
    case 2:
      guard let today = row("today"), today.parentId == space.pinnedId, sidebar.organizeCheckIdle else { return }
      organizeConditions["today_to_pinned"] = true
      organizeConditions["pin_hint"] = sidebar.organizeCheckHint(id: today.id)
      guard begin("folder", "organize-inner") else { return }
      guard sidebar.organizeCheckEnd() else { return }
      browserCheckPhase = 3
    case 3:
      guard row("folder")?.parentId == "organize-inner", space.pinned.first(where: { $0.id == "organize-inner" })?.collapsed == false,
            sidebar.organizeCheckIdle else { return }
      organizeConditions["folder_open_nested_insert"] = true
      guard begin("favorite", "favorites"), sidebar.organizeCheckEnd() else { return }
      browserCheckPhase = 4
    case 4:
      guard let favorite = row("favorite"), favorite.parentId == space.favoritesId, sidebar.organizeCheckIdle else { return }
      organizeConditions["pinned_to_favorites"] = true
      guard begin("dock", "dock"), sidebar.organizeCheckEnd() else { return }
      browserCheckPhase = 5
    case 5:
      guard row("dock")?.parentId == other.pinnedId, sidebar.organizeCheckIdle else { return }
      organizeConditions["dock_no_switch"] = current.shownSpaceId == space.id && sidebar.spaceShown == current.spaces.firstIndex(where: { $0.id == space.id })
      FileHandle.standardError.write(Data("ararat-trace: organize phase 5 dock-no-switch shown=\(current.shownSpaceId ?? "nil") sidebar_index=\(sidebar.spaceShown) expected_index=\(current.spaces.firstIndex(where: { $0.id == space.id }) ?? -1) target_parent=\(row("dock")?.parentId ?? "nil")\n".utf8))
      guard sidebar.organizeCheckBegin(id: "organize-outer", destination: "today") else { return }
      organizeConditions["folder_drag_refused"] = !sidebar.organizeCheckDragging
      guard sidebar.organizeCheckEnd() else { return }
      browserCheckPhase = 6
    case 6:
      organizeConditions["folder_drag_refused"] = organizeConditions["folder_drag_refused"] == true && space.pinned.contains { $0.id == "organize-outer" && $0.parentId == space.pinnedId }
      guard sidebar.organizeCheckIdle, begin("cancel", "organize-inner") else { return }
      organizeCancelStarted = sidebar.organizeCheckDragging
      guard sidebar.organizeCheckEnd(cancel: true) else { return }
      browserCheckPhase = 7
    case 7:
      guard sidebar.organizeCheckIdle else { return }
      guard sidebar.organizeCheckEnd() else { return }
      browserCheckPhase = 8
    case 8:
      guard sidebar.organizeCheckIdle else { return }
      organizeConditions["escape_cancel"] = organizeCancelStarted && row("cancel")?.parentId == space.pinnedId
      // Why not Other: it shares Work's profile and therefore its existing favourites container.
      if current.shownSpaceId != "organize-first" {
        switchWorkspaceSpace("organize-first")
        browserCheckPhase = 81
        return
      }
      browserCheckPhase = 81
    case 81:
      guard current.shownSpaceId == "organize-first", sidebar.organizeCheckIdle,
            let first = current.spaces.first(where: { $0.id == "organize-first" }) else { return }
      guard begin("first", "favorites") else { return }
      let point = sidebar.dragCheckPoint
      let drop = sidebar.resolveDropForCheck(position: point, draggedID: row("first")?.id ?? "")
      // No container yet: the resolver answers `.favorites(nil, index)`, the first-favourite path.
      // The result is kept aside; the condition is scored only after the drop lands (phase 82), so
      // a stall here leaves it unset rather than true.
      organizeFirstFavoriteTarget = drop?.kind == "favorites" && drop?.container == nil && first.favoritesId == nil
      FileHandle.standardError.write(Data("ararat-trace: organize phase 81 first-favorite point=\(point) target=\(drop?.kind ?? "nil") container=\(drop?.container ?? "nil") before=\(first.favoritesId ?? "nil") actual=\(sidebar.dragStateForCheck.drop) dragging=\(sidebar.organizeCheckDragging) shown=\(sidebar.spaceShown)\n".utf8))
      if screen, let image = promptScreenScreenshot(host.window(), name: "organize-first-favorite", withoutShadow: true) {
        organizeImage = image
      }
      guard sidebar.organizeCheckEnd() else { return }
      browserCheckPhase = 82
    case 82:
      guard sidebar.organizeCheckIdle,
            let first = current.spaces.first(where: { $0.id == "organize-first" }) else { return }
      let landed = first.favorites.contains { $0.url == "about:blank?organize-first" }
      organizeConditions["first_favorite_drop"] = organizeFirstFavoriteTarget && landed && first.favoritesId != nil
      FileHandle.standardError.write(Data("ararat-trace: organize phase 82 first-favorite target=\(organizeFirstFavoriteTarget) landed=\(landed) container=\(first.favoritesId ?? "nil") parent=\(row("first")?.parentId ?? "nil")\n".utf8))
      switchWorkspaceSpace("organize-work")
      browserCheckPhase = 83
    case 83:
      guard current.shownSpaceId == "organize-work", sidebar.organizeCheckIdle else { return }
      // Close the inner folder again for the hover-hold.
      session.queue.sync { _ = try? session.store?.setFolderCollapsed(windowId: windowID, id: "organize-inner", collapsed: true) }
      let fresh = session.queue.sync { session.store?.snapshot(windowId: windowID) }
      if let core = fresh { sidebar.update(snapshot: core) }
      browserCheckPhase = 84
    case 84:
      guard space.pinned.first(where: { $0.id == "organize-inner" })?.collapsed == true, sidebar.organizeCheckIdle else { return }
      organizeHoverStarted = ProcessInfo.processInfo.systemUptime
      guard begin("today", "organize-inner") else { return }
      browserCheckPhase = 85
    case 85:
      // The drag timer's own folderHoverDelay opens the folder while the drag is still held.
      let innerOpen = space.pinned.first(where: { $0.id == "organize-inner" })?.collapsed == false
      let target = sidebar.resolveDropForCheck(position: sidebar.dragCheckPoint, draggedID: row("today")?.id ?? "")
      if innerOpen && (target?.kind == "folder" || target?.kind == "insert") && target?.container == "organize-inner" {
        FileHandle.standardError.write(Data("ararat-trace: organize phase 85 hover opened target=\(target?.kind ?? "nil") container=\(target?.container ?? "nil") actual=\(sidebar.dragStateForCheck.drop)\n".utf8))
        organizeConditions["folder_hover_opens"] = true
        if screen { organizeImage = promptScreenScreenshot(host.window(), name: "organize-hover-open", withoutShadow: true) ?? organizeImage }
        guard sidebar.organizeCheckEnd() else { return }
        browserCheckPhase = 86
        return
      }
      // A held drag that never opens is a named failure, not a stall: 3 s is the VM's budget.
      if ProcessInfo.processInfo.systemUptime - organizeHoverStarted > 3 {
        FileHandle.standardError.write(Data("ararat-trace: organize phase 85 hover timeout open=\(innerOpen) target=\(target?.kind ?? "nil") container=\(target?.container ?? "nil") actual=\(sidebar.dragStateForCheck.drop) dragging=\(sidebar.organizeCheckDragging) shown=\(sidebar.spaceShown)\n".utf8))
        organizeConditions["folder_hover_opens"] = false
        _ = sidebar.organizeCheckEnd()
        browserCheckPhase = 87
        return
      }
      return
    case 86:
      guard sidebar.organizeCheckIdle else { return }
      organizeConditions["hover_drop"] = row("today")?.parentId == "organize-inner"
      let failed = organizeConditionNames(screen: screen).filter { organizeConditions[$0] != true }
      var values: [String: Any] = ["conditions": organizeConditions, "failed_conditions": failed]
      if let organizeImage { values["image"] = organizeImage }
      finishBrowserCheck(ok: failed.isEmpty, values: values)
    case 87:
      let failed = organizeConditionNames(screen: screen).filter { organizeConditions[$0] != true }
      var values: [String: Any] = ["conditions": organizeConditions, "failed_conditions": failed,
                                  "hover_wait": ProcessInfo.processInfo.systemUptime - organizeHoverStarted]
      if let organizeImage { values["image"] = organizeImage }
      finishBrowserCheck(ok: false, values: values)
    default: break
    }
  }

  func fullscreenScreenTick(_ host: any ARWindowHostAPI, tabs: [any ARTabAPI], state: [String: Any]) {
    let window = host.window()
    let full = state["window"] as? Bool == true
    let page = state["tab"] as? Bool == true
    func sendKey(_ text: String, code: UInt16, flags: NSEvent.ModifierFlags = []) {
      for type in [NSEvent.EventType.keyDown, .keyUp] {
        if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
          characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code) { NSApp.sendEvent(event) }
      }
    }
    func fullscreenMenu(_ menu: NSMenu?) -> (NSMenu, Int)? {
      guard let menu else { return nil }
      for (index, item) in menu.items.enumerated() {
        if item.action == #selector(NSWindow.toggleFullScreen(_:)), !item.isHidden { return (menu, index) }
        if let found = fullscreenMenu(item.submenu) { return found }
      }
      return nil
    }
    switch browserCheckPhase {
    case 0:
      guard let row = sliceRows.first, let url = row.url else { return }
      browserCheckSeedID = row.id
      adapter?.select(id: row.id, url: url)
      browserCheckPhase = 1
    case 1:
      guard sliceActive == browserCheckSeedID, let tab = tabs.first, !tab.isLoading, tab.navigationCount > 0 else { return }
      guard NSApp.isActive, window.isKeyWindow else { return }
      tab.focusCheckPage()
      guard state["view_focused"] as? Bool == true else { return }
      fullscreenTab = tab
      fullscreenEnteredNotification = false
      resetFullscreenProbe()
      tab.checkFullscreenRequest(true)
      browserCheckPhase = 2
    case 2:
      guard let tab = fullscreenTab else { return }
      probeFullscreen(tab)
      guard full, page, fullscreenElement == true, fullscreenEnteredNotification,
            window.styleMask.contains(.fullScreen), container?.pageFullscreen == true,
            promptPageCard?.frame == container?.bounds,
            let image = promptScreenScreenshot(window, name: "fullscreen-page", withoutShadow: true) else { return }
      fullscreenResults["page_screenshot"] = image
      fullscreenResults["native_space_entry"] = true
      tab.focusCheckPage()
      resetFullscreenProbe()
      fullscreenExitGate.arm()
      recordFullscreenFocus("before_escape", window: window)
      sendKey("\u{1b}", code: 53)
      browserCheckPhase = 3
    case 3:
      guard fullscreenExitGate.ready(transitioning: state["transitioning"] as? Bool),
            NSApp.isActive, window.isKeyWindow,
            !full, !page, !window.styleMask.contains(.fullScreen), let tab = fullscreenTab else { return }
      probeFullscreen(tab)
      guard fullscreenElement == false, let (menu, index) = fullscreenMenu(NSApp.mainMenu) else { return }
      fullscreenResults["escape"] = true
      fullscreenEnteredNotification = false
      let item = menu.items[index]
      let target = NSApp.target(forAction: #selector(NSWindow.toggleFullScreen(_:)), to: item.target, from: item) as AnyObject?
      fullscreenMenuDispatch = ["enabled": item.isEnabled, "target_class": target.map { String(describing: type(of: $0)) } ?? "none", "target_is_window": target === window]
      recordFullscreenFocus("before_menu", window: window)
      menu.performActionForItem(at: index)
      recordFullscreenFocus("after_menu", window: window)
      browserCheckPhase = 4
    case 4:
      if !fullscreenPhase4Observed {
        fullscreenPhase4Observed = true
        recordFullscreenFocus("first_phase4_tick", window: window)
      }
      guard full, !page, fullscreenEnteredNotification, window.styleMask.contains(.fullScreen),
            let container, container.sidebarState == "hidden", container.sidebarLightsHidden,
            container.appKitLightsVisible,
            let image = promptScreenScreenshot(window, name: "fullscreen-browser", withoutShadow: true) else { return }
      fullscreenResults["browser_screenshot"] = image
      fullscreenResults["menu_toggle"] = true
      fullscreenResults["appkit_lights"] = true
      guard let screen = NSScreen.screens.first else { return }
      let edge = NSPoint(x: window.frame.minX + 2, y: window.frame.midY)
      guard CGWarpMouseCursorPosition(CGPoint(x: edge.x, y: screen.frame.maxY - edge.y)) == .success,
            let event = NSEvent.mouseEvent(with: .mouseMoved, location: window.convertPoint(fromScreen: edge),
              modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
              context: nil, eventNumber: 0, clickCount: 0, pressure: 0) else { return }
      NSApp.sendEvent(event)
      browserCheckPhase = 8
    case 8:
      guard full, !page, let container, container.sidebarState == "floating", !container.sidebarAnimating,
            NSApp.isActive, window.isKeyWindow, let tab = fullscreenTab,
            let edgeImage = promptScreenScreenshot(window, name: "fullscreen-edge", withoutShadow: true) else { return }
      fullscreenResults["edge_reveal"] = true
      fullscreenResults["edge_screenshot"] = edgeImage
      tab.focusCheckPage()
      browserCheckPhase = 9
    case 9:
      guard full, !page, NSApp.isActive, window.isKeyWindow, let tab = fullscreenTab,
            let item = tab.itemId, host.activeItemId() == item else { return }
      guard state["view_focused"] as? Bool == true else { tab.focusCheckPage(); return }
      sendKey("f", code: 3, flags: [.control, .command])
      browserCheckPhase = 5
    case 5:
      guard !full, !page, !window.styleMask.contains(.fullScreen), let tab = fullscreenTab else { return }
      guard NSApp.isActive, window.isKeyWindow else { return }
      tab.focusCheckPage()
      guard state["view_focused"] as? Bool == true else { return }
      fullscreenResults["focused_control_command_f"] = true
      fullscreenEnteredNotification = false
      resetFullscreenProbe()
      tab.checkFullscreenRequest(true)
      browserCheckPhase = 6
    case 6:
      guard full, page, fullscreenEnteredNotification,
            let button = window.standardWindowButton(.zoomButton) else { return }
      button.performClick(nil)
      browserCheckPhase = 7
    case 7:
      guard !full, !page, !window.styleMask.contains(.fullScreen), let tab = fullscreenTab else { return }
      probeFullscreen(tab)
      guard fullscreenElement == false, container?.pageFullscreen == false else { return }
      fullscreenResults["green_button_exit"] = true
      fullscreenResults["stock_browsers"] = host.checkStockBrowsers()
      finishBrowserCheck(ok: host.checkStockBrowsers() == 0, values: fullscreenResults)
    default: break
    }
  }

  func finishBrowserCheck(ok: Bool, values: [String: Any]) {
    let cleanupSucceeded = historyPurgeCheck?.cleanup() ?? true
    let ok = ok && cleanupSucceeded && (host?.checkDialogIntegrity() ?? true)

    if promptScreenSeeded, let tab = (host?.tabs() as? [any ARTabAPI])?.first {
      _ = tab.checkScreenAddress(false)
      promptScreenSeeded = false
    }
    if let protocolLaunchObserver { NSWorkspace.shared.notificationCenter.removeObserver(protocolLaunchObserver) }
    protocolLaunchObserver = nil
    promptFixture?.stop()
    promptFixture = nil
    siteFixture?.stop()
    siteFixture = nil
    browserCheckTimer?.invalidate()
    browserCheckTimer = nil
    dockCheck?.stop()
    if let fullscreenObserver { NotificationCenter.default.removeObserver(fullscreenObserver) }
    fullscreenObserver = nil
    if let fullscreenActivationObserver { NotificationCenter.default.removeObserver(fullscreenActivationObserver) }
    fullscreenActivationObserver = nil
    for observer in fullscreenFocusObservers { NotificationCenter.default.removeObserver(observer) }
    fullscreenFocusObservers.removeAll()
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
    result["check"] = browserCheckMode == "relaunch-verify" ? (CommandLine.arguments.first(where: { $0.hasPrefix("--ararat-relaunch-mode=") }).map { String($0.dropFirst("--ararat-relaunch-mode=".count)) } ?? "relaunch") : (browserCheckMode == "screen-links" ? "links" : (browserCheckMode == "screen-profiles" ? "profiles" : (browserCheckMode == "screen-prompts" ? "prompts" : (browserCheckMode == "screen-devtools" ? "devtools" : (browserCheckMode ?? "unknown")))))
    if browserCheckMode == "screen-links" { result["screen"] = "links" }
    if browserCheckMode == "screen-profiles" { result["screen"] = "profiles" }
    if browserCheckMode == "screen-prompts" { result["screen"] = "prompts" }
    if browserCheckMode == "screen-dialogs" { result["check"] = "dialogs"; result["screen"] = "dialogs" }
    if browserCheckMode == "screen-devtools" { result["screen"] = "devtools" }
    if browserCheckMode == "screen-extensions" { result["check"] = "extensions"; result["screen"] = "extensions" }
    if browserCheckMode == "screen-fullscreen" {
      result["check"] = "fullscreen"; result["screen"] = "fullscreen"
      result["focus_trace"] = fullscreenFocusTrace
      result["focus_trace_dropped"] = fullscreenFocusTraceDropped
      result["menu_dispatch"] = fullscreenMenuDispatch
    }
    if browserCheckMode == "screen-keyboard" { result["check"] = "keyboard"; result["screen"] = "keyboard" }
    if browserCheckMode == "screen-organize" { result["check"] = "organize"; result["screen"] = "organize" }
    if browserCheckMode == "screen-look" { result["check"] = "look"; result["screen"] = "look" }
    if browserCheckMode == "screen-dock" { result["check"] = "dock"; result["screen"] = "dock" }
    if browserCheckMode == "dock" || browserCheckMode == "screen-dock" {
      let check = DockScreenCheck.conditionResults(dockCheck?.conditions ?? [:], screen: browserCheckMode == "screen-dock")
      result["conditions"] = check.values
      result["failed_conditions"] = check.failed
    }
    if browserCheckMode == "screen-commandbar" { result["check"] = "commandbar"; result["screen"] = "commandbar" }
    if let mode = sidebarCheckMode(browserCheckMode ?? ""), let check = sidebarCheck {
      let names = SidebarCheck.conditionNames(mode: mode, screen: browserCheckMode?.hasPrefix("screen-") == true)
      result["check"] = mode.rawValue
      if browserCheckMode?.hasPrefix("screen-") == true { result["screen"] = mode.rawValue }
      result["conditions"] = Dictionary(uniqueKeysWithValues: names.map { ($0, check.conditions[$0] == true) })
      result["failed_conditions"] = names.filter { check.conditions[$0] != true }
      result["images"] = check.images
    }
    if let mode = SettingsScreenCheck.Mode.mode(browserCheckMode ?? ""), let check = settingsCheck {
      let names = SettingsScreenCheck.conditionNames(mode)
      result["check"] = mode.rawValue
      result["screen"] = mode.rawValue
      result["pane"] = mode.paneID
      result["conditions"] = Dictionary(uniqueKeysWithValues: names.map { ($0, check.conditions[$0] == true) })
      result["failed_conditions"] = names.filter { check.conditions[$0] != true }
      result["images"] = check.images
    }
    if browserCheckMode == "screen-errorpages" { result["check"] = "errorpages"; result["screen"] = "errorpages" }
    if browserCheckMode == "screen-downloads" { result["check"] = "downloads"; result["screen"] = "downloads" }
    if browserCheckMode == "screen-toasts" { result["check"] = "toasts"; result["screen"] = "toasts" }
    if browserCheckMode == "screen-private-window" { result["check"] = "private-window"; result["screen"] = "private-window" }
    if browserCheckMode == "screen-split-focus" { result["check"] = "split-focus"; result["screen"] = "split-focus" }
    if browserCheckMode == "screen-split-commands" { result["check"] = "split-commands"; result["screen"] = "split-commands" }
    if browserCheckMode == "screen-header" { result["check"] = "header"; result["screen"] = "header" }
    if browserCheckMode == "urlfield" || browserCheckMode == "screen-urlfield" {
      let names = URLFieldCheckState.conditionNames(screen: browserCheckMode == "screen-urlfield")
      result["check"] = "urlfield"
      if browserCheckMode == "screen-urlfield" { result["screen"] = "urlfield" }
      result["conditions"] = Dictionary(uniqueKeysWithValues: names.map { ($0, (urlFieldCheck?.conditions[$0] == true)) })
      result["failed_conditions"] = names.filter { urlFieldCheck?.conditions[$0] != true }
    }
    if browserCheckMode == "site-controls" || browserCheckMode == "screen-site-controls" {
      let names = SiteControlsCheck.conditionNames(screen: browserCheckMode == "screen-site-controls")
      result["check"] = "site-controls"
      if browserCheckMode == "screen-site-controls" { result["screen"] = "site-controls" }
      result["conditions"] = Dictionary(uniqueKeysWithValues: names.map { ($0, (siteControlsCheck?.conditions[$0] == true)) })
      result["failed_conditions"] = names.filter { siteControlsCheck?.conditions[$0] != true }
    }
    if browserCheckMode == "ext-actions" || browserCheckMode == "screen-ext-actions" {
      let names = ExtensionActionsCheck.conditionNames(screen: browserCheckMode == "screen-ext-actions")
      result["check"] = "ext-actions"
      if browserCheckMode == "screen-ext-actions" { result["screen"] = "ext-actions" }
      result["conditions"] = Dictionary(uniqueKeysWithValues: names.map { ($0, extensionActionsCheck?.conditions[$0] == true) })
      result["failed_conditions"] = names.filter { extensionActionsCheck?.conditions[$0] != true }
    }
    if browserCheckMode == "window-drag" || browserCheckMode == "screen-window-drag" {
      let names = WindowDragCheckState.conditionNames(screen: browserCheckMode == "screen-window-drag")
      result["check"] = "window-drag"
      if browserCheckMode == "screen-window-drag" { result["screen"] = "window-drag" }
      result["conditions"] = Dictionary(uniqueKeysWithValues: names.map { ($0, windowDragCheck?.conditions[$0] == true) })
      result["failed_conditions"] = names.filter { windowDragCheck?.conditions[$0] != true }
      result["images"] = windowDragCheck?.images ?? [:]
      result["details"] = windowDragCheck?.details ?? [:]
    }
    if browserCheckMode == "create-space" || browserCheckMode == "screen-create-space" {
      let names = CreateSpaceCheckState.conditionNames(screen: browserCheckMode == "screen-create-space")
      result["check"] = "create-space"
      if browserCheckMode == "screen-create-space" { result["screen"] = "create-space" }
      result["conditions"] = Dictionary(uniqueKeysWithValues: names.map { ($0, createSpaceCheck?.conditions[$0] == true) })
      result["failed_conditions"] = names.filter { createSpaceCheck?.conditions[$0] != true }
      result["images"] = createSpaceCheck?.images ?? [:]
      result["details"] = createSpaceCheck?.details ?? [:]
    }
    if ["onboarding", "screen-onboarding"].contains(browserCheckMode ?? "") {
      let isScreen = browserCheckMode?.hasPrefix("screen-") == true
      let names = OnboardingCheckState.conditionNames(screen: isScreen)
      result["check"] = "onboarding"
      if isScreen { result["screen"] = "onboarding" }
      result.merge(onboardingCheckDiagnostics(screen: isScreen)) { _, new in new }
      result["conditions"] = Dictionary(uniqueKeysWithValues: names.map { ($0, onboardingCheck?.values[$0] == true) })
      result["failed_conditions"] = names.filter { onboardingCheck?.values[$0] != true }
    }
    if browserCheckMode == "little-window" || browserCheckMode == "screen-little-window" {
      let names = LittleWindowCheckState.conditionNames(screen: browserCheckMode == "screen-little-window")
      result["check"] = "little-window"
      if browserCheckMode == "screen-little-window" { result["screen"] = "little-window" }
      result["conditions"] = Dictionary(uniqueKeysWithValues: names.map { ($0, littleWindowCheck?.conditions[$0] == true) })
      result["failed_conditions"] = names.filter { littleWindowCheck?.conditions[$0] != true }
      result.merge(littleWindowCheckDiagnostics(screen: browserCheckMode == "screen-little-window")) { _, new in new }
    }
    if browserCheckMode == "commandbar" || browserCheckMode == "screen-commandbar" {
      result["conditions"] = Dictionary(uniqueKeysWithValues: commandBarConditionNames.map { ($0, commandBarConditions[$0] == true) })
      result["failed_conditions"] = commandBarConditionNames.filter { commandBarConditions[$0] != true }
    }
    if browserCheckMode == "look" || browserCheckMode == "screen-look" {
      lookCheck?.stopWatchingMenu()
      let check = LookScreenCheck.conditionResults(lookCheck?.conditions ?? [:], screen: browserCheckMode == "screen-look")
      result["conditions"] = check.values
      result["failed_conditions"] = check.failed
    }
    if browserCheckMode == "organize" || browserCheckMode == "screen-organize" {
      let names = organizeConditionNames(screen: browserCheckMode == "screen-organize")
      result["conditions"] = Dictionary(uniqueKeysWithValues: names.map { ($0, organizeConditions[$0] == true) })
      result["failed_conditions"] = names.filter { organizeConditions[$0] != true }
    }
    if browserCheckMode == "incognito" {
      result.merge(incognitoResultIdentity(check: "incognito", arguments: CommandLine.arguments)) { _, new in new }
    }
    if result["case"] == nil {
      if CommandLine.arguments.contains("--ararat-space-matrix-check") { result["case"] = "space-command-matrix" }
      else if CommandLine.arguments.contains(where: { $0.hasPrefix("--ararat-cross-window-reverse-check=") }) { result["case"] = "cross-window-reverse" }
      else if browserCheckMode == "keyboard" || browserCheckMode == "screen-keyboard" { result["case"] = "keyboard-main" }
    }
    if result["case"] as? String == "keyboard-main" {
      result["observed_direction"] = (host?.checkPagePresentation("")["rtl"] as? Bool).map { $0 ? "rtl" : "ltr" } as Any? ?? NSNull()
    }
    result["check_flags"] = coverageFlags()
    result["compositor"] = CommandLine.arguments.contains("--ararat-compositor=c2") ? "c2" : "c1"
    if CommandLine.arguments.contains("--ararat-split-close-check"), browserCheckMode == "profiles",
       !CommandLine.arguments.contains(where: { $0.hasPrefix("--ararat-selection-") || $0.hasPrefix("--ararat-committed-switch-race=") }) {
      result["case"] = CommandLine.arguments.contains("--ararat-empty-close-check") ? "close-empty" : "close-split"
    }
    result["requested_direction"] = CommandLine.arguments.contains("--force-ui-direction=rtl") ? "rtl" : "default"
    result["selection_confirm_race"] = splitCloseConfirmRaceOK
    result["ok"] = ok
    result["exit"] = ok ? 0 : 1
    if result["stock_browsers"] == nil { result["stock_browsers"] = host?.checkStockBrowsers() ?? browserCheckStock }
    result["phase"] = browserCheckPhase
    result["attempts"] = browserCheckAttempts
    result["style_mask"] = host?.window().styleMask.rawValue ?? browserCheckStyleMask
    let traceTeardown = browserCheckMode == "profiles" && CommandLine.arguments.contains {
      $0.hasPrefix("--ararat-cross-window-reverse-check=")
    }
    if traceTeardown {
      let deadline = TeardownDeadline()
      Launcher.teardownDeadline = deadline
      deadline.start(seconds: 30)
    }
    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
       let line = String(data: data, encoding: .utf8) {
      print(line); fflush(stdout)
      if traceTeardown { FileHandle.standardError.write(Data("ararat-teardown: result emitted\n".utf8)) }
    } else if traceTeardown {
      Launcher.teardownFailure = true
      FileHandle.standardError.write(Data("ararat-teardown: result serialization failed\n".utf8))
    }
    if let symbol = dlsym(Launcher.handle, "AraratFinishSliceCheck") {
      if traceTeardown { FileHandle.standardError.write(Data("ararat-teardown: finish symbol found; calling\n".utf8)) }
      unsafeBitCast(symbol, to: (@convention(c) (Bool) -> Void).self)(ok)
      if traceTeardown { FileHandle.standardError.write(Data("ararat-teardown: finish call returned\n".utf8)) }
    } else if traceTeardown {
      Launcher.teardownFailure = true
      FileHandle.standardError.write(Data("ararat-teardown: finish symbol missing\n".utf8))
    }
  }

  func coverageFlags() -> [String] {
    checkCoverageFlags(CommandLine.arguments)
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
    let sameProfileEmpty = CommandLine.arguments.contains("--ararat-same-profile-empty-quit-check")
    let quitPromptProfile = sameProfileEmpty ? "Default" : "Profile 1"
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
        if sameProfileEmpty {
          guard let id = snapshot.spaces.first(where: { $0.id == "default" })?.today.first?.id,
                let defaultTab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == id }) else { return }
          defaultTab.prepareCheckBeforeUnload()
        } else { tab.prepareCheckBeforeUnload() }
        quitPhase = 12
        return
      }
      if quitPhase == 12, let row = snapshot.spaces.first(where: { $0.id == "named" })?.today.first {
        guard let defaultID = snapshot.spaces.first(where: { $0.id == "default" })?.today.first?.id else { return }
        let promptID = sameProfileEmpty ? defaultID : row.id
        guard (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == promptID })?.checkHasBeforeUnload() == true else { return }
        splitCloseExpected = ["Default": defaultID, "Profile 1": row.id]
        if CommandLine.arguments.contains("--ararat-multiple-quit-check"), let adapter {
          let child = Runtime(windowID: UUID().uuidString)
          child.root = self
          do { try child.start(session: adapter.session, shownSpace: "default") }
          catch { quitTimedOut = true; finishQuitCheck(exitCode: 1); return }
          children.append(child)
          child.adapter?.openCommandURL("about:blank?unrelated", expectedSpace: "default", profile: "Default")
          adapter.windowHost(host, showProfile: "Default")
          adapter.openCommandURL("about:blank?multiple", expectedSpace: "default", profile: "Default")
          quitPhase = 16
          return
        }
        if CommandLine.arguments.contains("--ararat-split-close-check") {
          guard let adapter else { return }
          do { try adapter.session.queue.sync { _ = try adapter.session.store?.selectItem(windowId: windowID, id: "close-split") } }
          catch { quitTimedOut = true; finishQuitCheck(exitCode: 1); return }
        }
        adapter?.windowHost(host, showProfile: "Default")
        quitBefore = nil
        quitPhase = 13
        return
      }
      if quitPhase == 16, children.count == 1, let child = children.first, let childHost = child.host,
         child.windowID != windowID, childHost.profileDirectory() == "Default", host.profileDirectory() == "Default",
         child.snapshot.shownSpaceId == "default",
         let childItem = child.snapshot.selectedId,
         let childTab = (childHost.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == childItem && !$0.isLoading }),
         childHost.activeItemId() == childItem, let tabs = host.tabs() as? [any ARTabAPI], let adapter,
         let evidence = adapter.session.queue.sync(execute: { () -> (mapping: [String: String], reverse: [String: String], profiles: [String: String])? in
           guard let store = adapter.session.store else { return nil }
           var mappings: [String: String] = [:], reverse: [String: String] = [:], profiles: [String: String] = [:]
           for item in tabs.compactMap(\.itemId) + [childItem] {
             if let live = store.liveTab(item: item) {
               mappings[item] = live
               reverse[live] = store.itemForLive(liveId: live)
             }
             if let profile = store.itemProfile(itemId: item) {
               switch profile { case .default: profiles[item] = "Default"; case .named(let name): profiles[item] = name }
             }
           }
           return (mappings, reverse, profiles)
         }),
         let items = Self.multipleQuitSetupItems(snapshot: snapshot, expected: splitCloseExpected,
           rootTabs: tabs.map { (item: $0.itemId, live: $0.liveId, loading: $0.isLoading) },
           childItem: childItem, childLive: childTab.liveId, mappings: evidence.mapping,
           reverse: evidence.reverse, profiles: evidence.profiles) {
        multiCloseChildItem = childItem
        multiCloseChildLive = childTab.liveId
        multiCloseChildSpace = child.snapshot.shownSpaceId ?? ""
        multiCloseChildWindowID = child.windowID
        multiCloseDefaultItems = Set(items)
        for tab in tabs { tab.prepareCheckBeforeUnload() }
        quitPhase = 17
        return
      }
      if quitPhase == 17, let tabs = host.tabs() as? [any ARTabAPI], tabs.count == 3,
         tabs.allSatisfy({ $0.checkHasBeforeUnload() }), multipleCloseChildValid(), let rows = captureCheckRows() {
        guard quitBefore == rows else { quitBefore = rows; return }
        quitOriginal = rows
        host.configureProfileCloseCheck(1)
        quitPhase = 18
        NSApp.terminate(nil)
        return
      }
      if quitPhase == 18 || quitPhase == 19 {
        let state = host.checkProfileCloseState()
        let expectedCount = quitPhase == 18 ? 1 : 2
        guard state["dialogs"] as? Int == expectedCount, !host.checkTryingToQuit(),
              multipleCloseChildValid(), let pages = state["dialog_pages"] as? [[String: Any]],
              pages.count == expectedCount, let rows = captureCheckRows() else { return }
        guard quitCancelPrevious == rows else { quitCancelPrevious = rows; return }
        guard let original = quitOriginal,
              rows.filter({ !["window", "last_selected"].contains($0.first ?? "") }) == original.filter({ !["window", "last_selected"].contains($0.first ?? "") }),
              multipleClosePagesValidInAnyOrder(pages), snapshot.selectedId == host.activeItemId() else {
          quitTimedOut = true; finishQuitCheck(exitCode: 1); return
        }
        if quitPhase == 18 {
          multiQuitFirst = state.merging(["trying_to_quit": false, "selected_matches_active": true, "child_unchanged": true, "workspace_rows_unchanged": true]) { _, new in new }
          quitCancelPrevious = nil
          quitBefore = rows
          host.configureProfileCloseCheck(2)
          quitPhase = 19
        } else {
          multiQuitSecond = state.merging(["trying_to_quit": false, "selected_matches_active": true, "child_unchanged": true, "workspace_rows_unchanged": true]) { _, new in new }
          quitCancelPrevious = nil
          quitBefore = rows
          host.configureProfileCloseCheck(0)
          quitPhase = 20
        }
        NSApp.terminate(nil)
        return
      }
      if quitPhase == 13, host.profileDirectory() == "Default",
         let row = snapshot.spaces.first(where: { $0.id == "default" })?.today.first,
         snapshot.selectedId == row.id, let rows = captureCheckRows() {
        guard quitBefore == rows else { quitBefore = rows; return }
        if (CommandLine.arguments.contains("--ararat-empty-close-check") || sameProfileEmpty), let adapter {
          do {
            _ = try adapter.session.queue.sync {
              try adapter.session.store?.createSpace(windowId: windowID, name: "Empty", spaceId: "close-empty")
            }
          } catch { quitTimedOut = true; finishQuitCheck(exitCode: 1); return }
          adapter.refresh()
          quitBefore = nil
          quitPhase = 14
          return
        }
        quitOriginal = rows
        if CommandLine.arguments.contains("--ararat-split-close-check") { splitCloseBefore = snapshot }
        quitStyleMask = host.window().styleMask.rawValue
        if CommandLine.arguments.contains("--ararat-quit-suggestion-check") {
          openCommandBar(.newTab)
          guard let bar = commandPresenter?.controller, bar.isOpen else { quitTimedOut = true; finishQuitCheck(exitCode: 1); return }
          bar.update(query: "Quit")
          quitPhase = 15
          return
        }
        quitPhase = 3
        beginCloseRaceCheck(host) { host.expectCheckDialogs(1); NSApp.terminate(nil) }
        return
      }
      if quitPhase == 15, let bar = commandPresenter?.controller, bar.isOpen {
        guard let index = bar.result.rows.firstIndex(where: { row in
          if case .command(let id) = row.target { return id == "quit" }
          return false
        }) else { return }
        bar.moveSelection(by: index - bar.selectedIndex)
        quitPhase = 3
        host.expectCheckDialogs(1)
        bar.commit(forceNewTab: false)
        return
      }
      if quitPhase == 14, snapshot.shownSpaceId == "close-empty", snapshot.selectedId == nil,
         host.profileDirectory() == "Default", !host.hasActiveTab(), let rows = captureCheckRows() {
        guard quitBefore == rows else { quitBefore = rows; return }
        quitOriginal = rows
        splitCloseBefore = snapshot
        quitStyleMask = host.window().styleMask.rawValue
        quitPhase = 3
        host.expectCheckDialogs(1)
        NSApp.terminate(nil)
        return
      }
    }
    if quitPhase == 0, host != nil, !sliceRows.isEmpty {
      quitPhase = 1
      let row = sliceRows[0]
      if row.url != nil { selectCheckSeed(row) }
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
      if mode == "close" { host.expectCheckDialogs(1) }
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
      let splitCheck = CommandLine.arguments.contains("--ararat-split-close-check") && !sameProfileEmpty
      guard seen >= 1, !host.checkTryingToQuit(), (splitCheck ? host.tabs().count >= expectedBrowsers : host.tabs().count == expectedBrowsers),
            let symbol = dlsym(Launcher.handle, "AraratBrowserCount") else { return }
      let closing = host.checkClosingEvents().map(\.boolValue)
      guard closing.last == false else { return }
      let browsers = unsafeBitCast(symbol, to: (@convention(c) () -> UInt).self)()
      guard browsers == UInt(expectedBrowsers) else { return }
      guard let rows = captureCheckRows() else { return }
      guard selectionRaceSettled() else { return }
      let activeItem = host.activeItemId()
      let selectedMatches = snapshot.selectedId == nil
        ? !host.hasActiveTab() && checkWindowSelection(rows, windowID: windowID) == nil
        : activeItem != nil && snapshot.selectedId == activeItem && checkWindowSelection(rows, windowID: windowID) == activeItem
      if mode == "quit-cancel" {
        guard selectedMatches else { quitCancelPrevious = nil; return }
        guard quitCancelPrevious == rows else { quitCancelPrevious = rows; return }
      }
      let cancelDiff = checkRecordDiff(quitBefore, rows)
      let duringDiff = checkRecordDiff(quitBefore, quitDuringProfileSwitch)
      let outgoingItem = checkWindowSelection(quitBefore, windowID: windowID)
      let allowedWindowFields: Set<String> = ["shown_space", "space_history", "changed_at", "selected", "history"]
      let allowedSelections = Set([outgoingItem, activeItem].compactMap { $0 } +
        (splitCheck ? ["close-split-a", "close-split-b"] + Array(splitCloseExpected.values) : []))
      let windowRecordsChanged = cancelDiff.filter { $0["kind"] as? String == "window" }.count
      let onlyWindowSpaceChanged = (outgoingItem != nil || splitCheck) && activeItem != nil && windowRecordsChanged == 1 &&
        cancelDiff.contains { ($0["fields"] as? [String] ?? []).contains("shown_space") } && cancelDiff.allSatisfy { entry in
        if entry["kind"] as? String == "window" && entry["id"] as? String == windowID {
          return Set(entry["fields"] as? [String] ?? []).isSubset(of: allowedWindowFields)
        }
        guard entry["kind"] as? String == "last_selected", let id = entry["id"] as? String,
              allowedSelections.contains(id) else { return false }
        return rows.contains { $0.count == 3 && $0[0] == "last_selected" && $0[1] == id }
      }
      let quitPromptPage = (host.checkProfileCloseState()["dialog_pages"] as? [[String: Any]])?.contains(where: { page in
        page["profile"] as? String == quitPromptProfile && page["item"] as? String == splitCloseExpected[quitPromptProfile] &&
          page["active"] as? Bool == true && page["presented"] as? Bool == true
      }) == true
      let splitRendered = splitCheck && snapshot.shownSpaceId == "named" && snapshot.selectedId == "close-split-a" && splitCheckPagesPresented(host)
      let splitCancel = splitCloseBefore != nil && !splitCloseRaceFailed && selectedMatches && quitPromptPage &&
        (splitCheck ? onlyWindowSpaceChanged && host.profileDirectory() == "Profile 1" && splitRendered :
          rows == quitBefore && snapshot.shownSpaceId == splitCloseBefore?.shownSpaceId &&
            snapshot.selectedId == splitCloseBefore?.selectedId && host.profileDirectory() == "Default")
      quitFirst = ["trying_to_quit": host.checkTryingToQuit(), "browsers": browsers,
                   "host_alive": true, "tabs": host.tabs().count,
                   "rows_unchanged": mode == "quit-cancel" ? (splitCloseBefore == nil ? onlyWindowSpaceChanged && selectedMatches : splitCancel) : rows == quitBefore,
                   "hidden_profile_shown": mode == "quit-cancel" && host.profileDirectory() == "Profile 1",
                   "rows_unchanged_during_switch": mode == "quit-cancel" && (sameProfileEmpty ? rows == quitBefore : quitDuringProfileSwitch != nil && duringDiff.isEmpty),
                   "window_written_after_cancel": mode == "quit-cancel" && onlyWindowSpaceChanged,
                   "split_cancel_restored": splitCancel,
                   "prompt_page": quitPromptPage,
                   "selection_race_settled": splitCloseRaceSettled, "selection_race_activated": splitCloseRaceActivated,
                   "selection_race_failed": splitCloseRaceFailed,
                   "outgoing_item": outgoingItem ?? "", "active_item": activeItem ?? "",
                   "window_records_changed": windowRecordsChanged, "selected_matches_active": selectedMatches,
                   "during_diff": duringDiff, "cancel_diff": cancelDiff]
      if mode == "quit-cancel" { quitBefore = rows }
      quitEvents = host.checkClosingEvents()
      quitPhase = 4
      if mode == "close" { host.expectCheckDialogs(2); container?.sidebarCloseButton?.performClick(nil) }
      else if mode == "screen-quit" { sendQuitKey(host) }
      else { beginCloseRaceCheck(host) { host.expectCheckDialogs(2); NSApp.terminate(nil) } }
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
    let quitPromptProfile = CommandLine.arguments.contains("--ararat-same-profile-empty-quit-check") ? "Default" : "Profile 1"
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
    // The engine notifies closing=true twice per quit attempt: chrome::AttemptExit() reaches
    // AttemptExitInternal(), which notifies before platform_part()->AttemptExit() ends in
    // -[AppController tryToTerminateApplication] and notifies again. So one attempt reads
    // [true, true], its beforeunload cancel adds [false] (UnloadController::CancelWindowClose),
    // and the retry adds another [true, true]. The raw shape is asserted rather than a collapse of
    // it, so a doubled close or a doubled cancel cannot pass; closingTransitions is reported only.
    let closingAfterOffset = Array(events.dropFirst(screenClosingOffset))
    var closingTransitions: [Bool] = []
    for value in closingAfterOffset where closingTransitions.last != value { closingTransitions.append(value) }
    // Why the named conditions: "ok" alone cannot say which predicate of a quit mode failed.
    // Every mode reports the same terms it asserts on, and failed_conditions names them.
    var conditions: [String: Bool] = [:]
    switch mode {
    case "quit":
      conditions = ["rows_unchanged": unchanged, "closing_events": events == [true]]
    case "devtools":
      let front = commandOutput("/usr/bin/lsappinfo", ["front"])
      let frontUnchanged = devtoolsFrontBefore != nil && front != nil && front == devtoolsFrontBefore
      devtoolsResults["front_unchanged"] = frontUnchanged
      devtoolsResults["hidden"] = true
      conditions = ["rows_unchanged": unchanged, "closing_events": events == [true],
        "front_unchanged": frontUnchanged,
        "devtools_results": ["initial_docked", "background_hidden", "tab_restored", "undocked_host", "redocked",
          "closed_full_page", "inspected_tab_closed", "inspect_docked", "open_at_quit"].allSatisfy { devtoolsResults[$0] as? Bool == true }]
    case "quit-cancel":
      if CommandLine.arguments.contains("--ararat-multiple-quit-check") {
        let rootKept = after?.contains(where: { $0.count >= 2 && $0[0] == "window" && $0[1] == windowID }) == true
        let childKept = after?.contains(where: { $0.count >= 2 && $0[0] == "window" && $0[1] == multiCloseChildWindowID }) == true
        conditions = ["rows_unchanged": unchanged, "root_window_kept": rootKept, "child_window_kept": childKept,
          "first_cancel": !multiQuitFirst.isEmpty, "second_cancel": !multiQuitSecond.isEmpty,
          "dialog_seen": dialogSeen == 3, "closing_events": events == [true, false, true, false, true],
          "dialog_pages": multipleClosePagesValid(quitDialogPages, defaultCount: 2, namedCount: 1)]
      } else {
        let pagesValid = quitDialogPages.count == 2 && quitDialogPages.allSatisfy { page in
          page["profile"] as? String == quitPromptProfile && page["item"] as? String == splitCloseExpected[quitPromptProfile] &&
            page["active"] as? Bool == true && page["presented"] as? Bool == true
        }
        conditions = ["rows_unchanged": unchanged, "first_passed": firstPassed,
          "selection_race": splitCloseConfirmRaceOK, "dialog_seen": dialogSeen == 2,
          "closing_events": events == [true, false, true],
          "prompt_page": quitFirst["prompt_page"] as? Bool == true, "dialog_pages": pagesValid,
          "rows_unchanged_during_switch": quitFirst["rows_unchanged_during_switch"] as? Bool == true,
          "cancel_restored": splitCloseBefore == nil
            ? quitFirst["hidden_profile_shown"] as? Bool == true && quitFirst["window_written_after_cancel"] as? Bool == true
            : quitFirst["split_cancel_restored"] as? Bool == true]
      }
    case "close":
      conditions = ["first_passed": firstPassed, "rows_unchanged_after_close": closedRowsUnchanged,
        "window_removed": windowRemoved, "reopened": quitReopened, "dock_empty": quitDockEmpty,
        "dialog_seen": dialogSeen == 2]
    case "screen-quit":
      // Why the raw shape and not the collapsed one: a collapse would also accept two attempts before
      // the Stay or a cancel notified twice. closingTransitions stays in the result as a diagnostic.
      conditions = ["rows_unchanged": unchanged, "first_passed": firstPassed, "dialog_seen": dialogSeen == 2,
        "closing_after_offset": closingAfterOffset == [true, true, false, true, true],
        "sidebar_lights": screenSidebarLights, "appkit_lights_hidden": screenAppKitLightsHidden]
    default:
      conditions = ["known_mode": false]
    }
    // Every input of ok is named here, so a false ok always has at least one entry in
    // failed_conditions; modePassed keeps the mode's own terms for the devtools result.
    let modePassed = conditions.values.allSatisfy { $0 }
    conditions["engine_exit_zero"] = exitCode == 0
    conditions["not_timed_out"] = !quitTimedOut
    conditions["will_shut_down"] = quitWillShutDown
    conditions["stock_browsers_zero"] = quitStock == 0
    conditions["dialog_integrity"] = host?.checkDialogIntegrity() ?? true
    let ok = conditions.values.allSatisfy { $0 }
    var result: [String: Any] = ["check": mode == "screen-quit" ? "quit" : mode,
      "closing": quitEvents, "will_shut_down": quitWillShutDown,
      "stock_browsers": quitStock, "rows_before": quitBefore ?? [], "rows_after": after ?? [],
      "rows_unchanged": unchanged, "dialog_seen": dialogSeen, "exit": ok ? 0 : 1, "ok": ok,
      "timeout": quitTimedOut, "phase": quitPhase, "attempts": quitAttempts, "style_mask": quitStyleMask]
    result["check_flags"] = coverageFlags()
    result["compositor"] = CommandLine.arguments.contains("--ararat-compositor=c2") ? "c2" : "c1"
    result["conditions"] = conditions
    result["failed_conditions"] = conditions.filter { $0.value == false }.keys.sorted()
    if mode == "screen-quit" {
      result["closing_offset"] = screenClosingOffset
      result["closing_after_offset"] = closingAfterOffset
      result["closing_transitions"] = closingTransitions
    }
    if mode == "quit-cancel", CommandLine.arguments.contains("--ararat-split-close-check"),
       !CommandLine.arguments.contains(where: { $0.hasPrefix("--ararat-selection-race=") }) {
      result["case"] = CommandLine.arguments.contains("--ararat-same-profile-empty-quit-check") ? "quit-empty-same-profile" :
        (CommandLine.arguments.contains("--ararat-empty-close-check") ? "quit-empty-other-profile" : "quit-split")
    }
    result["requested_direction"] = CommandLine.arguments.contains("--force-ui-direction=rtl") ? "rtl" : "default"
    result["selection_confirm_race"] = splitCloseConfirmRaceOK
    if quitTimedOut { result["selection_diagnostics"] = checkSelectionDiagnostics(item: sliceRows.first?.id) }
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
    if mode == "quit-cancel" {
      result["expected_dialog_items"] = splitCloseExpected
      result["dialog_pages"] = quitDialogPages
      result["rows_before_first_quit"] = quitOriginal ?? []
      result["quit_suggestion"] = CommandLine.arguments.contains("--ararat-quit-suggestion-check")
      if CommandLine.arguments.contains("--ararat-multiple-quit-check") {
        result["expected_default_items"] = Array(multiCloseDefaultItems).sorted()
        result["root_window_id"] = windowID
        result["child_window_id"] = multiCloseChildWindowID
        result["multiple_first_cancel"] = multiQuitFirst
        result["multiple_second_cancel"] = multiQuitSecond
        result["multiple_final_pages"] = quitDialogPages
        if quitTimedOut && quitPhase == 16 {
          var diagnostic: [String: Any] = ["children": children.count, "root_window": windowID,
            "expected": splitCloseExpected, "root_ui": Self.matrixSnapshotDiagnostics(snapshot)]
          if let host {
            diagnostic["root_native"] = ["profile": host.profileDirectory(), "active": host.activeItemId() ?? "",
              "tabs": (host.tabs() as? [any ARTabAPI] ?? []).map {
                ["item": $0.itemId ?? "", "live": $0.liveId, "loading": $0.isLoading, "url": $0.url] as [String: Any]
              }]
          }
          if let child = children.first {
            diagnostic["child_window"] = child.windowID
            diagnostic["child_ui"] = Self.matrixSnapshotDiagnostics(child.snapshot)
            if let childHost = child.host {
              diagnostic["child_native"] = ["profile": childHost.profileDirectory(), "active": childHost.activeItemId() ?? "",
                "tabs": (childHost.tabs() as? [any ARTabAPI] ?? []).map {
                  ["item": $0.itemId ?? "", "live": $0.liveId, "loading": $0.isLoading, "url": $0.url] as [String: Any]
                }]
            }
            if let childAdapter = child.adapter { diagnostic["child_selection"] = childAdapter.checkSelectionState() }
          }
          if let adapter {
            diagnostic["root_selection"] = adapter.checkSelectionState()
            diagnostic["store"] = adapter.session.queue.sync {
              guard let store = adapter.session.store else { return [:] as [String: Any] }
              let current = store.snapshot(windowId: windowID)
              let items = current.spaces.flatMap { $0.today + $0.pinned + $0.favorites }.map(\.id)
              var mappings: [String: String] = [:], reverse: [String: String] = [:], profiles: [String: String] = [:]
              for item in Set(items).sorted() {
                if let live = store.liveTab(item: item) { mappings[item] = live; reverse[live] = store.itemForLive(liveId: live) }
                if let profile = store.itemProfile(itemId: item) {
                  switch profile { case .default: profiles[item] = "Default"; case .named(let name): profiles[item] = name }
                }
              }
              let childStore = children.first.map { Self.matrixSnapshotDiagnostics(store.snapshot(windowId: $0.windowID)) } ?? [:]
              return ["snapshot": Self.matrixSnapshotDiagnostics(current), "child_snapshot": childStore,
                      "mappings": mappings, "reverse": reverse, "profiles": profiles] as [String: Any]
            }
          }
          result["multiple_setup_diagnostics"] = diagnostic
        }
      }
    }
    if mode == "close" {
      result["rows_after_close"] = quitClosedRows ?? []
      result["rows_unchanged_after_close"] = closedRowsUnchanged
      result["window_removed_after_close"] = windowRemoved
      result["reopened"] = quitReopened
      result["dock_empty"] = quitDockEmpty
    }
    // Why the gate: the result must not wait for Chromium's teardown. The
    // engine can exceed its shutdown deadline after the loop has returned
    // (chrome/browser/shutdown_watchdog_mac.cc) and kill the process before the
    // line reaches stdout. will_shut_down already has every value the check
    // asserts on, so it emits first; a later call only prints when the verdict
    // it can now compute differs (a nonzero engine exit code, say).
    if !quitResultPrinted || quitResultOK != ok {
      if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
         let line = String(data: data, encoding: .utf8) { print(line); fflush(stdout) }
      quitResultPrinted = true
      quitResultOK = ok
    }
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
    commandPresenter?.close(restoreFocus: false)
    siteOverlay?.removeFromSuperview()
    siteOverlay = nil
    if promptScreenSeeded, let tab = (host?.tabs() as? [any ARTabAPI])?.first {
      _ = tab.checkScreenAddress(false)
      promptScreenSeeded = false
    }
    if let protocolLaunchObserver { NSWorkspace.shared.notificationCenter.removeObserver(protocolLaunchObserver) }
    protocolLaunchObserver = nil
    promptFixture?.stop()
    promptFixture = nil
    siteFixture?.stop()
    siteFixture = nil
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
    if quitMode != nil { finishQuitCheck(exitCode: 0) }
  }
}

var callbacks = AraratCallbacks(
  started: { _ in
    MainActor.assumeIsolated {
      let value = Runtime()
      do {
        try value.start()
        Launcher.runtime = value
        LittleWindowGlobalShortcut.install(value)
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
  create_host: { _, popup, offTheRecord, profilePointer, profile, x, y, width, height in
    guard let profile else { return nil }
    let profileName = String(cString: profile)
    let pointer = profilePointer.map { UInt(bitPattern: $0) }
    let address = MainActor.assumeIsolated {
      if Launcher.runtime == nil && CommandLine.arguments.contains(where: { $0.hasPrefix("--ararat-check=") || $0 == "--ararat-screen=links" }) {
        FileHandle.standardError.write(Data("ararat-trace: browser-factory fallback=no-runtime\n".utf8))
      }
      return Launcher.runtime?.createHost(popup: popup, offTheRecord: offTheRecord, profilePointer: pointer, profile: profileName, bounds: NSRect(x: Int(x), y: Int(y), width: Int(width), height: Int(height))).map { UInt(bitPattern: $0) } ?? 0
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
  let watchdogSeconds = ["keyboard", "errorpages", "downloads", "toasts", "private-window", "screen-private-window", "private-isolation", "private-downloads", "private-durability-seed", "private-durability-verify", "split-focus", "split-commands", "urlfield", "screen-urlfield", "header", "site-controls", "ext-actions"].contains(name) ? 120 : 60
  let timer = DispatchSource.makeTimerSource(queue: .global())
  timer.schedule(deadline: .now() + .seconds(watchdogSeconds))
  timer.setEventHandler {
    var result: [String: Any] = ["check": name, "ok": false, "timeout": "watchdog", "exit": 1,
      "phase": -1, "attempts": 0, "style_mask": 0, "phase_is_placeholder": true,
      "attempts_are_placeholder": true, "watchdog_seconds": watchdogSeconds]
    if name == "toasts" { result["failed_conditions"] = ["watchdog"]; result["wait"] = "main thread did not finish the toasts check" }
    if name == "split-focus" { result["failed_conditions"] = ["watchdog"]; result["wait"] = "main thread did not finish the split-focus check" }
    if name == "split-commands" { result["failed_conditions"] = ["watchdog"]; result["wait"] = "main thread did not finish the split-commands check" }
    if name == "downloads" { result["failed_conditions"] = ["watchdog"]; result["wait"] = "main thread did not finish the downloads check" }
    if name == "header" { result["failed_conditions"] = ["watchdog"]; result["wait"] = "main thread did not finish the header check" }
    if name == "urlfield" { result["failed_conditions"] = ["watchdog"]; result["wait"] = "main thread did not finish the urlfield check" }
    if name == "site-controls" { result["failed_conditions"] = ["watchdog"]; result["wait"] = "main thread did not finish the site-controls check" }
    if name == "ext-actions" { result["failed_conditions"] = ["watchdog"]; result["wait"] = "main thread did not finish the ext-actions check" }
    if name == "private-window" { result["failed_conditions"] = ["watchdog"]; result["wait"] = "main thread did not finish the private-window check" }
    if !screen { result.merge(incognitoResultIdentity(check: name, arguments: CommandLine.arguments)) { _, new in new } }
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
    if runtime.browserCheckMode == "incognito" {
      var failure: [String: Any] = ["check": "incognito", "ok": false, "error": "engine exited before check completed", "exit": 1]
      failure.merge(incognitoResultIdentity(check: "incognito", arguments: CommandLine.arguments)) { _, new in new }
      if let data = try? JSONSerialization.data(withJSONObject: failure, options: [.sortedKeys]),
         let line = String(data: data, encoding: .utf8) { print(line); fflush(stdout) }
      return false
    }
    if runtime.browserCheckMode == "devtools" && runtime.quitMode == nil {
      let failure: [String: Any] = ["check": "devtools", "ok": false, "error": "engine exited before quit", "exit": 1, "phase": runtime.browserCheckPhase]
      if let data = try? JSONSerialization.data(withJSONObject: failure), let line = String(data: data, encoding: .utf8) { print(line); fflush(stdout) }
      return false
    }
    return runtime.finishQuitCheck(exitCode: result)
  }
  if let argument = CommandLine.arguments.first(where: {
    ["--ararat-check=quit", "--ararat-check=quit-cancel", "--ararat-check=close", "--ararat-check=newtab", "--ararat-check=popup", "--ararat-check=menu", "--ararat-check=empty", "--ararat-check=deferred", "--ararat-check=profiles", "--ararat-check=ext-windows", "--ararat-check=ext-popup", "--ararat-check=ext-windows-popup", "--ararat-check=incognito", "--ararat-check=permissions", "--ararat-check=dialogs", "--ararat-check=protocol", "--ararat-check=autofill", "--ararat-check=devtools", "--ararat-screen=quit", "--ararat-screen=links", "--ararat-screen=profiles", "--ararat-screen=prompts", "--ararat-screen=dialogs", "--ararat-screen=devtools", "--ararat-screen=extensions", "--ararat-check=site-controls", "--ararat-screen=site-controls", "--ararat-check=ext-actions", "--ararat-screen=ext-actions"].contains($0)
  }) {
    Launcher.startupWatchdog?.cancel()
    let screen = argument.hasPrefix("--ararat-screen=")
    let name = String(argument.dropFirst(screen ? 16 : 15))
    var failure: [String: Any] = ["check": name, "ok": false, "error": "startup", "exit": 1]
    if !screen { failure.merge(incognitoResultIdentity(check: name, arguments: CommandLine.arguments)) { _, new in new } }
    if screen { failure["screen"] = name }
    if let data = try? JSONSerialization.data(withJSONObject: failure), let line = String(data: data, encoding: .utf8) {
      print(line)
      fflush(stdout)
    }
    return false
  }
  return true
}
let teardownPassed = Launcher.teardownDeadline?.finish() ?? true
if Launcher.teardownDeadline != nil {
  FileHandle.standardError.write(Data("ararat-teardown: engine returned; deadline_passed=\(teardownPassed)\n".utf8))
}
exit(result == 0 && (!checksPassed || !teardownPassed || Launcher.teardownFailure) ? 1 : result)
