import AppKit
import AraratEngineAPI
import AraratKit
import AraratUI

@MainActor
final class SplitFocusCheck {
  static let names = ["single_no_ring", "seed", "ring_a", "gap", "divider_edges", "url_a", "copy_a", "click_b", "ring_b", "url_b", "copy_b", "next_wrap", "previous_wrap", "divider_drag_frozen", "divider_drag", "single_after_split"]
  var conditions: [String: Bool] = [:]
  var images: [String: String] = [:]
  var capturing = false
  var waitName = ""
  var waitCount = 0
  var initialWidth: CGFloat = 0
  var dragEnd = NSPoint.zero
  let pasteboard = NSPasteboard(name: NSPasteboard.Name("ararat-split-focus-\(UUID().uuidString)"))
  var presses: [[String: String]] = []
  func mark(_ name: String, _ value: Bool = true) {
    conditions[name] = value
    FileHandle.standardError.write(Data("ararat-trace: split-focus \(name)=\(value)\n".utf8))
  }
  func wait(_ name: String, _ details: String) {
    if name != waitName || waitCount % 20 == 0 { FileHandle.standardError.write(Data("ararat-trace: split-focus wait=\(name) \(details)\n".utf8)) }
    if name != waitName { waitCount = 0; waitName = name }
    waitCount += 1
  }
  func diagnostics(screen: Bool) -> [String: Any] {
    let required = Self.names + (screen ? ["capture_a", "capture_b", "capture_frozen", "capture_release"] : [])
    return ["conditions": Dictionary(uniqueKeysWithValues: required.map { ($0, conditions[$0] == true) }),
            "failed_conditions": required.filter { conditions[$0] != true }, "wait": waitName, "images": images, "presses": presses]
  }
}

extension Runtime {
  func splitFocusCheckTick(_ host: any ARWindowHostAPI, screen: Bool) {
    if splitFocusCheck == nil { splitFocusCheck = SplitFocusCheck() }
    guard let check = splitFocusCheck, !check.capturing, let adapter, let sidebar, let workspace, let container else { return }
    let window = host.window()
    let tabs = (host.tabs() as? [any ARTabAPI]) ?? []
    let state = adapter.checkSplitFocus()
    func wait(_ name: String) { check.wait(name, "phase=\(browserCheckPhase) selected=\(snapshot.selectedId ?? "nil") active=\(host.activeItemId() ?? "nil") dispatches=\(splitFocusDispatches) tabs=\(tabs.map { $0.itemId ?? "nil" })") }
    func fail(_ message: String) { var result = check.diagnostics(screen: screen); result["error"] = message; finishBrowserCheck(ok: false, values: result) }
    func select(_ id: String, next: Int) {
      browserCheckPhase = 100
      workspace.select(id: id) { result in
        guard case .success = result else { fail("select \(id)"); return }
        self.showAndSelect(result)
        self.browserCheckPhase = next
      }
    }
    func key(_ right: Bool) {
      check.presses.append(["action": right ? "next" : "previous", "selected": snapshot.selectedId ?? "nil", "active": host.activeItemId() ?? "nil"])
      let character = String(UnicodeScalar(right ? 0xf703 : 0xf702)!)
      guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option, .function, .numericPad], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: right ? 124 : 123) else { return }
      NSApp.postEvent(event, atStart: false)
    }
    func mouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent? {
      NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
    }
    func postClick(_ point: NSPoint) -> Bool {
      check.presses.append(["action": "pane_click", "selected": snapshot.selectedId ?? "nil", "active": host.activeItemId() ?? "nil"])
      guard let down = mouse(.leftMouseDown, point), let up = mouse(.leftMouseUp, point) else { return false }
      NSApp.postEvent(down, atStart: false); NSApp.postEvent(up, atStart: false); return true
    }
    func ring(_ id: String) -> Bool { state.ring == state.panes[id] && state.ringWidth == 2 && state.ringPassesHits && state.ringAbovePage }
    func capture(_ name: String) {
      guard screen else { return }
      check.capturing = true; defer { check.capturing = false }
      if let path = promptScreenScreenshot(window, name: "split-focus-\(name)", withoutShadow: true) { check.images[name] = path; check.mark("capture_\(name)") }
    }
    switch browserCheckPhase {
    case 0:
      guard window.isKeyWindow, window.isVisible, host.hasBrowser(), promptFixturePort != nil,
            let row = snapshot.spaces.first(where: { $0.id == snapshot.shownSpaceId })?.today.first, row.url != nil else { wait("single seed"); return }
      sidebar.pasteboard = check.pasteboard
      browserCheckSeedID = row.id; selectCheckSeed(row); browserCheckPhase = 1
    case 1:
      guard let id = browserCheckSeedID, snapshot.selectedId == id, host.activeItemId() == id,
            tabs.contains(where: { $0.itemId == id && !$0.isLoading }) else { wait("single active"); return }
      check.mark("single_no_ring", state.ring == nil)
      select("close-split-a", next: 2)
    case 2:
      guard snapshot.selectedId == "close-split-a", host.activeItemId() == "close-split-a",
            ["close-split-a", "close-split-b"].allSatisfy({ id in tabs.contains { $0.itemId == id && !$0.isLoading } }),
            state.panes.count == 2, let port = promptFixturePort else { wait("split pages a"); return }
      check.mark("seed"); check.mark("ring_a", ring("close-split-a"))
      capture("a")
      check.mark("gap", state.dividers.count == 1 && abs(state.dividers[0].width - 10) < 0.01)
      check.mark("divider_edges", state.dividerEdgesHit)
      host.checkNavigate("http://127.0.0.1:\(port)/search", disposition: "current")
      browserCheckPhase = 3
    case 3:
      guard let tab = tabs.first(where: { $0.itemId == "close-split-a" }), tab.url.hasPrefix("http://127.0.0.1:"), !tab.isLoading else { wait("navigate a"); return }
      select("close-split-b", next: 4)
    case 4:
      guard snapshot.selectedId == "close-split-b", host.activeItemId() == "close-split-b", let port = promptFixturePort else { wait("select b"); return }
      host.checkNavigate("http://localhost:\(port)/search", disposition: "current"); browserCheckPhase = 5
    case 5:
      guard let tab = tabs.first(where: { $0.itemId == "close-split-b" }), tab.url.hasPrefix("http://localhost:"), !tab.isLoading else { wait("navigate b"); return }
      select("close-split-a", next: 6)
    case 6:
      guard snapshot.selectedId == "close-split-a", host.activeItemId() == "close-split-a", let pane = state.panes["close-split-b"] else { wait("restore a"); return }
      check.mark("url_a", sidebar.urlHostForCheck == "127.0.0.1")
      sidebar.checkClickCopyLink()
      check.mark("copy_a", check.pasteboard.string(forType: .string) == tabs.first(where: { $0.itemId == "close-split-a" })?.url && container.checkToastState.visible)
      guard postClick(NSPoint(x: pane.midX, y: pane.midY)) else { fail("click event"); return }
      browserCheckPhase = 7
    case 7:
      guard snapshot.selectedId == "close-split-b", host.activeItemId() == "close-split-b" else { wait("click b"); return }
      check.mark("click_b"); check.mark("ring_b", ring("close-split-b"))
      check.mark("url_b", sidebar.urlHostForCheck == "localhost")
      sidebar.checkClickCopyLink()
      check.mark("copy_b", check.pasteboard.string(forType: .string) == tabs.first(where: { $0.itemId == "close-split-b" })?.url && container.checkToastState.visible)
      capture("b")
      guard let page = tabs.first(where: { $0.itemId == "close-split-b" })?.view,
            let responder = window.firstResponder as? NSView, responder === page || responder.isDescendant(of: page) else { wait("page first responder"); return }
      key(true); browserCheckPhase = 8
    case 8:
      guard snapshot.selectedId == "close-split-a", host.activeItemId() == "close-split-a" else {
        wait("next wraps")
        if check.waitCount >= 30 { check.mark("next_wrap", false); select("close-split-a", next: 81) }
        return
      }
      check.mark("next_wrap", ring("close-split-a") && splitFocusDispatches["focus_next_pane"] == 1); key(false); browserCheckPhase = 9
    case 81:
      guard snapshot.selectedId == "close-split-a", host.activeItemId() == "close-split-a" else { wait("restore a after next"); return }
      key(false); browserCheckPhase = 9
    case 9:
      guard snapshot.selectedId == "close-split-b", host.activeItemId() == "close-split-b", let divider = state.dividers.first,
            let pane = state.panes["close-split-a"] else {
        wait("previous wraps")
        if check.waitCount >= 30 { check.mark("previous_wrap", false); select("close-split-b", next: 91) }
        return
      }
      check.mark("previous_wrap", ring("close-split-b") && splitFocusDispatches["focus_previous_pane"] == 1); check.initialWidth = pane.width
      beginDividerDrag(divider)
    case 91:
      guard snapshot.selectedId == "close-split-b", host.activeItemId() == "close-split-b", let divider = state.dividers.first,
            let pane = state.panes["close-split-a"] else { wait("restore b for divider"); return }
      check.initialWidth = pane.width
      beginDividerDrag(divider)
    case 10:
      guard let width = state.panes["close-split-a"]?.width, abs(width - check.initialWidth) > 1 else { wait("divider drag"); return }
      check.mark("divider_drag_frozen", state.frozen && ring("close-split-b"))
      capture("frozen")
      guard let up = mouse(.leftMouseUp, check.dragEnd) else { fail("divider release"); return }
      NSApp.postEvent(up, atStart: false); browserCheckPhase = 11
    case 11:
      guard !state.frozen, let width = state.panes["close-split-a"]?.width, abs(width - check.initialWidth) > 1,
            adapter.checkSplitFactors().contains(where: { abs($0 - 0.5) > 0.001 }) else { wait("divider release and saved factors"); return }
      check.mark("divider_drag", ring("close-split-b"))
      capture("release")
      guard let id = browserCheckSeedID else { fail("single seed missing"); return }
      select(id, next: 12)
    case 12:
      guard let id = browserCheckSeedID, snapshot.selectedId == id, host.activeItemId() == id else { wait("single after split"); return }
      check.mark("single_after_split", state.ring == nil)
      let result = check.diagnostics(screen: screen)
      finishBrowserCheck(ok: (result["failed_conditions"] as? [String] ?? ["invalid"]).isEmpty, values: result)
    default: break
    }
    func beginDividerDrag(_ divider: NSRect) {
      check.presses.append(["action": "divider_drag", "selected": snapshot.selectedId ?? "nil", "active": host.activeItemId() ?? "nil"])
      let start = NSPoint(x: divider.midX, y: divider.midY), end = NSPoint(x: divider.midX + 30, y: divider.midY)
      guard let down = mouse(.leftMouseDown, start), let drag = mouse(.leftMouseDragged, end) else { fail("divider events"); return }
      check.dragEnd = end
      NSApp.postEvent(down, atStart: false); NSApp.postEvent(drag, atStart: false); browserCheckPhase = 10
    }
  }
}
