import AppKit
import AraratEngineAPI
import AraratKit
import AraratUI

@MainActor
final class RelaunchWindowsCheck {
  private weak var runtime: Runtime?
  private var seeded = false
  private var finished = false
  init(runtime: Runtime) { self.runtime = runtime }

  func tick(seeding: Bool) {
    guard !finished, let runtime, let session = runtime.adapter?.session else { return }
    do {
      if seeding && !seeded {
        seeded = true
        let ids = [runtime.windowID, UUID().uuidString, UUID().uuidString]
        let kept: [KeptWindow] = try session.queue.sync {
          guard let store = session.store else { throw NSError(domain: "relaunch-windows.store", code: 1) }
          for (index, id) in ids.enumerated() {
            _ = try store.createSpace(windowId: id, name: "Restore \(index)", spaceId: "restore-\(index)")
            let first = try store.createTab(windowId: id, url: "data:text/html,<title>Restore \(index) A</title>")
            if index == 2, let left = first.selectedId {
              let second = try store.createTab(windowId: id, url: "data:text/html,<title>Restore \(index) B</title>")
              if let right = second.selectedId { _ = try store.makeSplit(windowId: id, draggedId: right, targetId: left, side: .right) }
            }
          }
          return store.keptWindows()
        }
        for id in ids.dropFirst() {
          let child = Runtime(windowID: id)
          child.root = runtime
          try child.start(session: session, restoringWindow: kept.first { $0.id == id })
          runtime.children.append(child)
        }
        runtime.adapter?.restoreSelection()
        for (index, window) in ([runtime] + runtime.children).enumerated() {
          let frame = WindowPlacement.clamped(NSRect(x: 70 + index * 45, y: 100 + index * 35, width: 900 + index * 30, height: 650),
                                              screens: NSScreen.screens.map(\.visibleFrame), main: NSScreen.main?.visibleFrame)
          window.host?.window().setFrame(frame, display: false)
          window.container?.resizeHandle.sidebarWidth = CGFloat(220 + index * 30)
          if index == 1 { window.performWorkspaceCommand("toggle_sidebar") }
        }
      }
      let windows = [runtime] + runtime.children
      guard windows.count == 3, session.restoringWindows.isEmpty else { return }
      let records = session.queue.sync { session.store?.keptWindows() ?? [] }
      guard records.count == 3 else { return }
      var states: [[String: Any]] = []
      for (index, window) in windows.enumerated() {
        guard let host = window.host, let adapter = window.adapter, let container = window.container,
              let record = records.first(where: { $0.id == window.windowID }), let frame = record.presentation.frame,
              let width = record.presentation.sidebarWidth else { return }
        let snapshot = session.queue.sync { session.store?.snapshot(windowId: window.windowID) }
        guard let selected = snapshot?.selectedId, let space = snapshot?.shownSpaceId,
              let tab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == selected }),
              !tab.isLoading, tab.navigationCount > 0, host.activeItemId() == selected else { return }
        let split = adapter.checkSplitLayout()
        if space == "restore-2" && (!split.split || split.panes != 2 || host.tabs().count != 2) { return }
        let actual = host.window().frame
        let presentation = container.savedPresentation
        if seeding {
          guard width == Double(220 + index * 30), record.presentation.sidebarHidden == (index == 1) else { return }
        }
        guard presentation.sidebarWidth == width, presentation.sidebarHidden == record.presentation.sidebarHidden,
              actual == NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height) else { return }
        states.append(["id": window.windowID, "space": space, "selected": selected,
                       "frame": [frame.x, frame.y, frame.width, frame.height], "width": width,
                       "hidden": presentation.sidebarHidden,
                       "panes": split.panes])
      }
      states.sort { ($0["id"] as! String) < ($1["id"] as! String) }
      if seeding {
        try session.queue.sync { try session.store?.flush() }
        let ready: [String: Any] = ["ready": true, "windows": states]
        let data = try JSONSerialization.data(withJSONObject: ready, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self)); fflush(stdout)
        finished = true
        runtime.finishBrowserCheck(ok: true, values: [:])
      } else {
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--ararat-relaunch-expected=") }),
              let data = Data(base64Encoded: String(argument.dropFirst("--ararat-relaunch-expected=".count))),
              let expected = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let expectedStates = expected["windows"] as? [[String: Any]] else {
          throw NSError(domain: "relaunch-windows.expected", code: 1)
        }
        finished = true
        runtime.finishBrowserCheck(ok: NSArray(array: states).isEqual(to: expectedStates),
                                   values: ["windows": states, "expected_windows": expectedStates, "all_workspaces_ready": true])
      }
    } catch {
      finished = true
      runtime.finishBrowserCheck(ok: false, values: ["error": String(describing: error)])
    }
  }
}
