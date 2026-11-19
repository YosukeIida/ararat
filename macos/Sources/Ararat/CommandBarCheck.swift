import AppKit
import AraratEngineAPI
import AraratKit
import AraratUI

extension Runtime {
  var commandBarConditionNames: [String] {
    ["search_first", "search_return", "settings_second", "history", "private_history", "open_url_first", "return_opens_url", "recent_space", "force_reload", "switch_previous", "switch_cancel", "url_click"]
  }

  func commandBarCheckResult(screen: Bool) -> [String: Any] {
    var conditions = Dictionary(uniqueKeysWithValues: commandBarConditionNames.map { ($0, commandBarConditions[$0] == true) })
    if screen {
      conditions["capture"] = ["search", "settings", "open-url", "recent", "edit-url", "tab-switcher"]
        .allSatisfy { commandBarImages[$0] != nil }
    }
    return ["conditions": conditions, "failed_conditions": conditions.keys.sorted().filter { conditions[$0] != true },
            "images": commandBarImages]
  }

  func commandBarCheckDiagnostics() -> [String: Any] {
    let bar = commandPresenter?.controller
    let keyWindow = NSApp.keyWindow
    return ["phase": browserCheckPhase,
            "bar_open": bar?.isOpen ?? false,
            "bar_mode": bar.map { String(describing: $0.mode) } as Any? ?? NSNull(),
            "bar_query": bar?.query as Any? ?? NSNull(),
            "bar_rows": bar?.result.rows.map { ["target": String(describing: $0.target), "url": $0.url as Any? ?? NSNull()] } ?? [],
            "bar_selected_index": bar?.selectedIndex as Any? ?? NSNull(),
            "key_window": keyWindow?.windowNumber as Any? ?? NSNull(),
            "host_window": host?.window().windowNumber as Any? ?? NSNull(),
            "host_key": host?.window().isKeyWindow ?? false,
            "app_active": NSApp.isActive,
            "first_responder": keyWindow?.firstResponder.map { String(describing: type(of: $0)) } as Any? ?? NSNull(),
            "switcher_open": tabSwitcher?.isOpen ?? false,
            "switcher_rows": tabSwitcher?.rows.count ?? 0,
            "switcher_selected_index": tabSwitcher?.selectedIndex as Any? ?? NSNull(),
            "active_item": host?.activeItemId() as Any? ?? NSNull(),
            "selected_item": snapshot.selectedId as Any? ?? NSNull(),
            "fixture_error": promptFixtureError as Any? ?? NSNull()]
  }

  func commandBarCheckTick(_ host: any ARWindowHostAPI, screen: Bool) {
    guard !commandBarCapturing, let port = promptFixturePort, let adapter, let workspace else { return }
    let url = "http://127.0.0.1:\(port)/keyboard"
    func capture(_ name: String, _ window: NSWindow?) {
      guard screen, let window, window.isVisible else { return }
      commandBarCapturing = true
      defer { commandBarCapturing = false }
      window.contentView?.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      commandBarImages[name] = promptScreenScreenshot(window, name: "commandbar-\(name)", withoutShadow: true)
    }
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
    func key(_ code: UInt16, chars: String, flags: NSEvent.ModifierFlags = [], type: NSEvent.EventType = .keyDown, post: Bool = false) {
      guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: (NSApp.keyWindow ?? host.window()).windowNumber,
        context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { return }
      if post { NSApp.postEvent(event, atStart: false) } else { NSApp.sendEvent(event) }
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
      trace("open history query")
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
      capture("search", presenter.panel)
      trace("return runs search")
      if screen { key(36, chars: "\r") } else { presenter.controller.commit(forceNewTab: false) }
      step(51, "return runs search")
    case 51:
      guard let id = snapshot.selectedId, id != commandBarInitialID,
            host.activeItemId() == id, snapshot.spaces.flatMap(\.today).contains(where: { $0.id == id && $0.url?.contains("google.com/search") == true }) else { return }
      commandBarSearchID = id
      commandBarConditions["search_return"] = true
      trace("open settings query")
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
      capture("settings", presenter.panel)
      guard setQuery(url, presenter) else { return }
      step(7, "enter fixture URL")
    case 7:
      guard let presenter = commandPresenter, let row = presenter.controller.result.rows.first else { return }
      if case .openUrl = row.target { commandBarConditions["open_url_first"] = true } else { return }
      capture("open-url", presenter.panel)
      trace("return opens URL")
      if screen { key(36, chars: "\r") } else { presenter.controller.commit(forceNewTab: false) }
      step(8, "return opens URL")
    case 8:
      guard let id = snapshot.selectedId, id != commandBarInitialID, id != commandBarSearchID, host.activeItemId() == id,
            let tab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == id }), tab.url == url, !tab.isLoading else { return }
      commandBarFixtureID = id
      commandBarConditions["return_opens_url"] = true
      trace("open recent tabs")
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
      capture("recent", presenter.panel)
      presenter.close()
      commandBarReloadCount = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == commandBarFixtureID })?.navigationCount ?? 0
      trace("force reload")
      performWorkspaceCommand("force_reload")
      step(10, "force reload")
    case 10:
      guard let tab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == commandBarFixtureID }), tab.navigationCount > commandBarReloadCount, !tab.isLoading else { return }
      commandBarConditions["force_reload"] = true
      trace("control tab")
      if screen {
        // A posted ⌃Tab must reach the window's menu pass; name what it would find when the
        // switcher never appears (first responder, the binding's item, the key window).
        let responder = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "-"
        let item = NSApp.mainMenu?.items.flatMap { ($0.submenu?.items ?? []) + [$0] }
          .first { $0.identifier?.rawValue == "cycle_tabs_next" }
        FileHandle.standardError.write(Data("ararat-trace: commandbar control-tab key=\(NSApp.keyWindow?.windowNumber ?? -1) host=\(host.window().windowNumber) host_key=\(host.window().isKeyWindow) app_active=\(NSApp.isActive) responder=\(responder) menu_item=\(item != nil) menu_key=\(item?.keyEquivalent ?? "-") menu_mods=\(item?.keyEquivalentModifierMask.rawValue ?? 0)\n".utf8))
      }
      if screen { key(48, chars: "\t", flags: .control, post: true) } else { cycleTabs(backwards: false, holdForCheck: true) }
      step(11, "control tab")
    case 11:
      guard let switcher = tabSwitcher, !switcher.rows.isEmpty else { return }
      capture("tab-switcher", switcher.visibleWindow)
      if screen { key(59, chars: "", type: .flagsChanged, post: true) } else { switcher.commit() }
      step(12, "release control")
    case 12:
      guard host.activeItemId() == commandBarSearchID else { return }
      commandBarConditions["switch_previous"] = true
      if screen { key(48, chars: "\t", flags: .control, post: true) } else { cycleTabs(backwards: false, holdForCheck: true) }
      step(13, "open switcher for escape")
    case 13:
      guard let switcher = tabSwitcher, !switcher.rows.isEmpty else { return }
      if screen { key(53, chars: "\u{1b}", post: true) } else { switcher.cancel() }
      step(131, "send escape")
    case 131:
      guard tabSwitcher == nil else { return }
      commandBarConditions["switch_cancel"] = host.activeItemId() == commandBarSearchID
      guard let sidebar else { return }
      trace("click URL field")
      if screen {
        let p = NSPoint(x: sidebar.urlFieldCheckFrame.midX, y: sidebar.urlFieldCheckFrame.midY)
        func mouse(_ type: NSEvent.EventType) -> NSEvent? {
          NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: host.window().windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        }
        if let down = mouse(.leftMouseDown), let up = mouse(.leftMouseUp) {
          NSApp.postEvent(up, atStart: false)
          NSApp.sendEvent(down)
        }
      } else { sidebar.clickURLForCheck() }
      step(14, "click URL field")
    case 14:
      guard let presenter = commandPresenter else { return }
      commandBarConditions["url_click"] = presenter.controller.mode == .editURL
      capture("edit-url", presenter.panel)
      presenter.close()
      let result = commandBarCheckResult(screen: screen)
      finishBrowserCheck(ok: (result["failed_conditions"] as? [String])?.isEmpty == true, values: result)
    default: break
    }
  }
}
