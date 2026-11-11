import AppKit
import AraratEngineAPI
import AraratKit
import AraratUI

extension Runtime {
  var commandBarConditionNames: [String] {
    ["search_first", "search_return", "settings_second", "history", "private_history", "open_url_first", "return_opens_url", "recent_space", "force_reload", "switch_previous", "switch_cancel", "url_click"]
  }

  func commandBarCheckTick(_ host: any ARWindowHostAPI, screen: Bool) {
    guard let port = promptFixturePort, let adapter, let workspace else { return }
    let url = "http://127.0.0.1:\(port)/keyboard"
    func trace(_ name: String) { FileHandle.standardError.write(Data("ararat-trace: commandbar begin \(name)\n".utf8)) }
    func step(_ next: Int, _ name: String) {
      FileHandle.standardError.write(Data("ararat-trace: commandbar \(name)\n".utf8))
      browserCheckPhase = next
    }
    func setQuery(_ text: String, _ presenter: CommandBarPresenter) -> Bool {
      if screen {
        guard let editor = presenter.view.field.currentEditor() as? NSTextView else { return false }
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
      } else { presenter.controller.update(query: text) }
      return true
    }
    func key(_ code: UInt16, chars: String, flags: NSEvent.ModifierFlags = [], type: NSEvent.EventType = .keyDown) {
      guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: (NSApp.keyWindow ?? host.window()).windowNumber,
        context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { return }
      NSApp.sendEvent(event)
    }
    switch browserCheckPhase {
    case 0:
      guard let row = sliceRows.first, let initialURL = row.url else { return }
      commandBarInitialID = row.id
      trace("select seed")
      adapter.select(id: row.id, url: initialURL)
      step(1, "select seed")
    case 1:
      guard host.activeItemId() == commandBarInitialID, let tab = (host.tabs() as? [any ARTabAPI])?.first, !tab.isLoading else { return }
      trace("navigate fixture")
      host.checkNavigate(url, disposition: "current")
      step(2, "navigate fixture")
    case 2:
      guard let tab = (host.tabs() as? [any ARTabAPI])?.first, tab.url == url, !tab.isLoading else { return }
      trace("leave fixture")
      host.checkNavigate("about:blank", disposition: "current")
      step(3, "leave fixture")
    case 3:
      guard let tab = (host.tabs() as? [any ARTabAPI])?.first, tab.url == "about:blank", !tab.isLoading,
            snapshot.spaces.flatMap(\.today).contains(where: { $0.id == commandBarInitialID && $0.url == "about:blank" }) else { return }
      openCommandBar(.newTab)
      step(4, "open history query")
    case 4:
      guard let presenter = commandPresenter, presenter.controller.isOpen else { return }
      guard setQuery("keyboard", presenter) else { return }
      step(5, "query history")
    case 5:
      guard let presenter = commandPresenter else { return }
      let rows = presenter.controller.result.rows
      guard let first = rows.first else { return }
      guard rows.contains(where: { if case .history = $0.target { return $0.url == url }; return false }) else { return }
      if case .search = first.target { commandBarConditions["search_first"] = true }
      commandBarConditions["history"] = true
      if screen { key(36, chars: "\r") } else { presenter.controller.commit(forceNewTab: false) }
      step(51, "return runs search")
    case 51:
      guard let id = snapshot.selectedId, id != commandBarInitialID,
            host.activeItemId() == id, snapshot.spaces.flatMap(\.today).contains(where: { $0.id == id && $0.url?.contains("google.com/search") == true }) else { return }
      commandBarSearchID = id
      commandBarConditions["search_return"] = true
      openCommandBar(.newTab)
      step(52, "open settings query")
    case 52:
      guard let presenter = commandPresenter, presenter.controller.isOpen else { return }
      guard setQuery("set", presenter) else { return }
      workspace.commandBarSession(privateWindow: true) { [weak self] result in
        guard let self, let session = try? result.get() else { return }
        self.commandBarPrivateResult = session.query(text: "keyboard", history: [HistoryEntry(title: "keyboard", url: url, lastVisit: 1)])
      }
      step(6, "query settings and private session")
    case 6:
      guard let presenter = commandPresenter, let privateResult = commandBarPrivateResult else { return }
      let rows = presenter.controller.result.rows
      guard rows.count >= 2 else { return }
      if case .command(let id) = rows[1].target { commandBarConditions["settings_second"] = id == "settings" }
      commandBarConditions["private_history"] = privateResult.privateWindow && !privateResult.rows.contains { if case .history = $0.target { return true }; return false }
      guard setQuery(url, presenter) else { return }
      step(7, "enter fixture URL")
    case 7:
      guard let presenter = commandPresenter, let row = presenter.controller.result.rows.first else { return }
      if case .openUrl = row.target { commandBarConditions["open_url_first"] = true } else { return }
      if screen { key(36, chars: "\r") } else { presenter.controller.commit(forceNewTab: false) }
      step(8, "return opens URL")
    case 8:
      guard let id = snapshot.selectedId, id != commandBarInitialID, id != commandBarSearchID, host.activeItemId() == id,
            let tab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == id }), tab.url == url, !tab.isLoading else { return }
      commandBarFixtureID = id
      commandBarConditions["return_opens_url"] = true
      openCommandBar(.newTab)
      step(9, "open recent tabs")
    case 9:
      guard let presenter = commandPresenter, let first = presenter.controller.result.rows.first else { return }
      let rows = presenter.controller.result.rows
      guard case .tab = first.target else { return }
      commandBarConditions["recent_space"] = rows.count <= 5 && rows.allSatisfy { row in
        if case .tab(let id, let space) = row.target { return id != commandBarFixtureID && space == snapshot.shownSpaceId }
        return false
      }
      presenter.close()
      commandBarReloadCount = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == commandBarFixtureID })?.navigationCount ?? 0
      trace("force reload")
      performWorkspaceCommand("force_reload")
      step(10, "force reload")
    case 10:
      guard let tab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == commandBarFixtureID }), tab.navigationCount > commandBarReloadCount, !tab.isLoading else { return }
      commandBarConditions["force_reload"] = true
      if screen { key(48, chars: "\t", flags: .control) } else { cycleTabs(backwards: false, holdForCheck: true) }
      step(11, "control tab")
    case 11:
      guard let switcher = tabSwitcher, !switcher.rows.isEmpty else { return }
      if screen { key(59, chars: "", type: .flagsChanged) } else { switcher.commit() }
      step(12, "release control")
    case 12:
      guard host.activeItemId() == commandBarSearchID else { return }
      commandBarConditions["switch_previous"] = true
      if screen { key(48, chars: "\t", flags: .control) } else { cycleTabs(backwards: false, holdForCheck: true) }
      step(13, "open switcher for escape")
    case 13:
      guard let switcher = tabSwitcher, !switcher.rows.isEmpty else { return }
      if screen { key(53, chars: "\u{1b}") } else { switcher.cancel() }
      guard !switcher.isOpen else { return }
      commandBarConditions["switch_cancel"] = host.activeItemId() == commandBarSearchID
      guard let sidebar else { return }
      trace("click URL field")
      if screen {
        let p = NSPoint(x: sidebar.urlFieldCheckFrame.midX, y: sidebar.urlFieldCheckFrame.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
          if let event = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: host.window().windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { host.window().sendEvent(event) }
        }
      } else { sidebar.clickURLForCheck() }
      step(14, "click URL field")
    case 14:
      guard let presenter = commandPresenter else { return }
      commandBarConditions["url_click"] = presenter.controller.mode == .editURL
      presenter.close()
      let failed = commandBarConditionNames.filter { commandBarConditions[$0] != true }
      finishBrowserCheck(ok: failed.isEmpty, values: ["conditions": commandBarConditions, "failed_conditions": failed])
    default: break
    }
  }
}
