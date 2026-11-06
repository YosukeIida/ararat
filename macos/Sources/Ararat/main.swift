// Why not NSApplicationMain or @main: Chrome's BrowserCrApplication must be
// the first NSApplication; AppKit objects are created only from started.

import Darwin
import Foundation
import AppKit
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
  @MainActor static var runtime: Runtime?
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

  func start() throws {
    let arguments = CommandLine.arguments
    if arguments.contains(where: { $0.hasPrefix("--ararat-check=") && $0 != "--ararat-check=slice" }) { return }
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
    let card = NSView()
    let check = arguments.contains("--ararat-check=slice")
    let adapter = try EngineAdapter(path: path, windowID: "window-1", card: card, seedCheck: check)
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
    if check {
      sliceTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.sliceTick(card: card) }
      }
    } else {
      host.window().makeKeyAndOrderFront(nil)
    }
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

  func report(_ error: Error) {
    FileHandle.standardError.write(Data("workspace: \(error)\n".utf8))
  }

  func sliceTick(card: NSView) {
    guard let host else { return }
    sliceAttempts += 1
    guard sliceAttempts < 300 else { finishSlice(ok: false); return }
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
    } else if slicePhase == 4, let symbol = dlsym(Launcher.handle, "AraratBrowserCount") {
      let count = unsafeBitCast(symbol, to: (@convention(c) () -> UInt).self)()
      sliceBrowsers = count
      if count == 0 {
        finishSlice(ok: sliceResult)
      }
    }
  }

  func finishSlice(ok: Bool) {
    sliceTimer?.invalidate()
    sliceTimer = nil
    print("{\"check\":\"slice\",\"ok\":\(ok),\"title_matches\":\(sliceTitleMatches),\"reselect_no_reload\":\(sliceNoReload),\"tabs\":\(sliceTabCount),\"active_in_card\":\(sliceInCard),\"mouse_sent\":\(sliceMouseSent),\"exclusive_input_seen\":\(sliceExclusiveInputSeen),\"transactions\":{\"count\":\(sliceTransactions),\"last_rev\":\(sliceLastRev)},\"browsers\":\(sliceBrowsers)}")
    fflush(stdout)
    guard let symbol = dlsym(Launcher.handle, "AraratFinishSliceCheck") else { return }
    unsafeBitCast(symbol, to: (@convention(c) (Bool) -> Void).self)(ok)
  }

  func shutdown() {
    sliceTimer?.invalidate()
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
      } catch {
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
        } else if CommandLine.arguments.contains("--ararat-check=slice") {
          value.finishSlice(ok: false)
        } else if let symbol = dlsym(Launcher.handle, "AraratQuit") {
          unsafeBitCast(symbol, to: (@convention(c) () -> Void).self)()
        }
      }
    }
  },
  will_shut_down: { _ in
    MainActor.assumeIsolated { Launcher.runtime?.shutdown(); Launcher.runtime = nil }
  },
  ctx: nil
)
typealias AraratMain = @convention(c) (
  Int32,
  UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
  UnsafeRawPointer?
) -> Int32
let araratMain = unsafeBitCast(symbol, to: AraratMain.self)
let result = withUnsafePointer(to: &callbacks) {
  araratMain(CommandLine.argc, CommandLine.unsafeArgv, UnsafeRawPointer($0))
}
exit(result)
