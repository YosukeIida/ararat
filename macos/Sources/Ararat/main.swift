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

@MainActor
final class Runtime {
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

  func start() throws {
    let arguments = CommandLine.arguments
    let checkName = arguments.first(where: { $0.hasPrefix("--ararat-check=") }).map { String($0.dropFirst(15)) }
    let screenName = arguments.first(where: { $0.hasPrefix("--ararat-screen=") }).map { String($0.dropFirst(16)) }
    if let checkName, !["slice", "quit", "quit-cancel", "close"].contains(checkName) { return }
    quitMode = screenName.map { "screen-\($0)" } ?? (["quit", "quit-cancel", "close"].contains(checkName ?? "") ? checkName : nil)
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
    let card = NSView()
    let check = arguments.contains("--ararat-check=slice") || quitMode != nil
    let singleCheck = quitMode != nil && quitMode != "quit"
    let adapter = try EngineAdapter(path: path, windowID: "window-1", card: card, seedCheck: check && !singleCheck, seedSingleCheck: singleCheck)
    let workspace = WorkspaceAdapter(windowID: "window-1", session: adapter.session)
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: nil, selectedId: nil, spaces: []))
    let container = SidebarContainerView(sidebar: sidebar, page: card)
    typealias Factory = @convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> UnsafeMutableRawPointer?
    let factory = unsafeBitCast(createSymbol, to: Factory.self)
    let windowID = "window-1" as NSString
    guard let pointer = factory(Unmanaged.passUnretained(container).toOpaque(), Unmanaged.passUnretained(windowID).toOpaque()),
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
      sidebar?.update(snapshot: snapshot)
      container?.selectionChanged()
      if check {
        let rows = snapshot.spaces.flatMap { $0.today + $0.pinned + $0.favorites }
        self?.sliceRows = ["One", "Two", "Three"].compactMap { name in
          rows.first { $0.url == "data:text/html,<title>Ararat \(name)</title>" }
        }
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
    if quitMode != nil {
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
    } else {
      host.window().makeKeyAndOrderFront(nil)
    }
  }

  func observeClose(_ host: any ARWindowHostAPI) {
    if let windowCloseObserver { NotificationCenter.default.removeObserver(windowCloseObserver) }
    windowCloseObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: host.window(), queue: .main
    ) { [weak weakHost = host as AnyObject, weak self] _ in
      MainActor.assumeIsolated {
        if let host = weakHost as? any ARWindowHostAPI { self?.captureCheckState(host) }
      }
      DispatchQueue.main.async { [weak self] in self?.host = nil }
    }
  }

  func captureCheckState(_ host: any ARWindowHostAPI) {
    guard quitMode != nil else { return }
    quitEvents = host.checkClosingEvents()
    quitDialogCount = host.checkDialogCount()
    quitStock = host.checkStockBrowsers()
  }

  func reopen() -> Bool {
    if quitMode == "close" { FileHandle.standardError.write(Data("ararat-trace: reopen-callback host=\(host != nil) selected=\(snapshot.selectedId != nil)\n".utf8)) }
    if let host {
      if quitMode == nil || quitMode == "screen-quit" { host.window().makeKeyAndOrderFront(nil) }
      return false
    }
    guard let container, let adapter,
          let symbol = dlsym(Launcher.handle, "AraratWindowHostCreate") else { return false }
    typealias Factory = @convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> UnsafeMutableRawPointer?
    let windowID = "window-1" as NSString
    guard let pointer = unsafeBitCast(symbol, to: Factory.self)(
      Unmanaged.passUnretained(container).toOpaque(), Unmanaged.passUnretained(windowID).toOpaque()),
      let host = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? any ARWindowHostAPI else { return false }
    self.host = host
    observeClose(host)
    adapter.attach(host)
    if quitMode == nil || quitMode == "screen-quit" { host.window().makeKeyAndOrderFront(nil) }
    if let id = snapshot.selectedId,
       let row = snapshot.spaces.flatMap({ $0.today + $0.pinned + $0.favorites }).first(where: { $0.id == id }),
       let url = row.url {
      adapter.select(id: id, url: url)
      if quitMode == "close" { FileHandle.standardError.write(Data("ararat-trace: reopen-select\n".utf8)) }
    }
    return false
  }

  func show(_ snapshot: WorkspaceSnapshot) {
    self.snapshot = snapshot
    sidebar?.update(snapshot: snapshot)
    container?.selectionChanged()
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
      guard seen >= 1, !host.checkTryingToQuit(), host.tabs().count == 1,
            let symbol = dlsym(Launcher.handle, "AraratBrowserCount") else { return }
      let closing = host.checkClosingEvents().map(\.boolValue)
      guard closing.last == false else { return }
      let browsers = unsafeBitCast(symbol, to: (@convention(c) () -> UInt).self)()
      guard browsers == 1 else { return }
      let rows = captureCheckRows()
      quitFirst = ["trying_to_quit": host.checkTryingToQuit(), "browsers": browsers,
                   "host_alive": true, "tabs": host.tabs().count,
                   "rows_unchanged": rows != nil && rows == quitBefore]
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
    let unchanged = quitBefore != nil && after != nil && quitBefore == after
    let dialogSeen = mode == "screen-quit" ? screenDialogs : Int(quitDialogCount)
    let firstPassed = (quitFirst["rows_unchanged"] as? Bool) == true &&
      (quitFirst["trying_to_quit"] as? Bool) == false && (quitFirst["browsers"] as? UInt) == 1
    let events = quitEvents.map(\.boolValue)
    let modePassed: Bool
    switch mode {
    case "quit": modePassed = unchanged && events == [true]
    case "quit-cancel": modePassed = unchanged && firstPassed && dialogSeen == 2 && events == [true, false, true]
    case "close": modePassed = firstPassed && quitBefore != nil && quitBefore == quitClosedRows && quitReopened && quitDockEmpty && dialogSeen == 2
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
    if mode == "close" {
      result["rows_after_close"] = quitClosedRows ?? []
      result["rows_unchanged_after_close"] = quitBefore != nil && quitBefore == quitClosedRows
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
        if value.quitMode == nil {
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
  if let runtime = Launcher.runtime { return runtime.finishQuitCheck(exitCode: result) }
  if let argument = CommandLine.arguments.first(where: {
    ["--ararat-check=quit", "--ararat-check=quit-cancel", "--ararat-check=close", "--ararat-screen=quit"].contains($0)
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
