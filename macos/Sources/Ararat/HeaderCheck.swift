import AppKit
import AraratEngineAPI
import AraratKit
import AraratUI

@MainActor
final class HeaderCheck {
  static let names = ["seed", "widths", "menu", "tooltip_caps", "pressed", "initial_state", "loading_stop", "stopped", "back", "forward", "find", "zoom", "clear", "force_reload", "internal_schemes", "button_toggle", "button_reload_stop", "menu_find", "menu_zoom", "clear_via_menu"]
  var capturing = false
  var id = ""
  var live = ""
  var navigation: UInt = 0
  var conditions: [String: Bool] = [:]
  var images: [String: String] = [:]
  var details: [String: Any] = [:]
  var lastWait = ""
  /// p4checks: the sidebar state before the header's toggle button, and what it pressed through.
  var sidebarBefore = ""
  func diagnostics(screen: Bool) -> [String: Any] {
    let names = Self.names + (screen ? ["capture"] : [])
    return ["conditions": conditions, "failed_conditions": names.filter { conditions[$0] != true }, "images": images, "details": details, "item": id, "live": live, "wait": lastWait, "unverified": ["Print preview and cancellation", "Force Reload network cache bypass", "Clear Cache and Cookies data isolation"]]
  }
}

extension Runtime {
  func headerCheckTick(_ host: any ARWindowHostAPI, screen: Bool) {
    if headerCheck == nil { headerCheck = HeaderCheck() }
    guard let check = headerCheck, !check.capturing, let container, let sidebar else { return }
    let header = container.header
    func wait(_ name: String) {
      if check.lastWait != name || browserCheckAttempts % 30 == 0 {
        check.lastWait = name
        FileHandle.standardError.write(Data("ararat-trace: header wait=\(name) selected=\(snapshot.selectedId ?? "nil") active=\(host.activeItemId() ?? "nil") id=\(check.id) live=\(check.live)\n".utf8))
      }
    }
    func finish() {
      let result = check.diagnostics(screen: screen)
      finishBrowserCheck(ok: (result["failed_conditions"] as? [String])?.isEmpty == true, values: result)
    }
    switch browserCheckPhase {
    case 0:
      guard let row = snapshot.spaces.first(where: { $0.id == snapshot.shownSpaceId })?.today.first, row.url != nil, promptFixturePort != nil else { wait("seed"); return }
      check.id = row.id
      selectCheckSeed(row)
      browserCheckPhase = 1
    case 1:
      guard snapshot.selectedId == check.id, host.activeItemId() == check.id,
            let tab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == check.id }), !tab.isLoading, tab.navigationCount > 0,
            !screen || (host.window().isVisible && host.window().isKeyWindow) else { wait("active seed tab and key window"); return }
      check.live = tab.liveId
      check.conditions["seed"] = true
      let initialMenu = header.makeMenu().items.filter { !$0.isSeparatorItem }
      check.conditions["initial_state"] = !tab.canGoBack && header.checkEnabled["back"] == false && header.checkEnabled["forward"] == false && !initialMenu[3].isEnabled && !initialMenu[4].isEnabled
      let widths: [(CGFloat, [String])] = [(240, ["toggle_sidebar", "back", "forward", "reload", "menu"]), (232, ["toggle_sidebar", "back", "forward", "reload", "menu"]), (231, ["back", "forward", "reload", "menu"]), (200, ["back", "forward", "reload", "menu"]), (199, ["back", "forward", "menu"]), (164, ["back", "forward", "menu"])]
      var widthsOK = true
      var capturesOK = true
      for (width, expected) in widths {
        container.resizeHandle.sidebarWidth = width
        container.layoutSubtreeIfNeeded()
        widthsOK = widthsOK && header.checkControls == expected
        if screen {
          check.capturing = true
          let image = promptScreenScreenshot(host.window(), name: "header-\(Int(width))", withoutShadow: true)
          check.capturing = false
          capturesOK = capturesOK && image != nil
          if let image { check.images["width_\(Int(width))"] = image }
        }
      }
      check.conditions["widths"] = widthsOK
      if screen { check.conditions["capture"] = capturesOK }
      container.resizeHandle.sidebarWidth = 240
      container.layoutSubtreeIfNeeded()
      check.conditions["menu"] = header.makeMenu().items.filter { !$0.isSeparatorItem }.map(\.title) == ["Reload", "Force Reload", "Find in Page…", "Clear Cache", "Clear Cookies", "Toggle Sidebar", "Zoom In", "Zoom Out", "Print…", "Settings…"]
      var capsOK = true
      check.details["tooltips_shown"] = header.tooltipsShown
      check.details["loading"] = header.loading
      for (command, label, caps) in [("toggle_sidebar", "Toggle Sidebar", ["⌘", "S"]), ("back", "Go Back", ["⌘", "["]), ("forward", "Go Forward", ["⌘", "]"]), ("reload", "Reload", ["⌘", "R"])] {
        let tip = header.checkTooltip(command, keep: screen)
        check.details["tooltip_\(command)"] = ["text": tip.0 ?? "nil", "caps": tip.1] as [String: Any]
        capsOK = capsOK && tip.0 == label && tip.1 == caps
        if screen {
          check.capturing = true
          let image = promptScreenScreenshot(host.window(), name: "header-tooltip-\(command)", withoutShadow: true)
          check.capturing = false
          capturesOK = capturesOK && image != nil
          if let image { check.images["tooltip_\(command)"] = image }
          header.checkDismissTooltip()
        }
      }
      check.conditions["tooltip_caps"] = capsOK
      if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: host.window().windowNumber, context: nil, characters: "r", charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15) {
        _ = header.checkTooltip("reload", keep: true)
        container.checkShortcutKeys([], event: event)
        let commandCap = header.checkPressedCaps == ["⌘"]
        if screen {
          check.capturing = true
          let image = promptScreenScreenshot(host.window(), name: "header-command", withoutShadow: true)
          check.capturing = false
          capturesOK = capturesOK && image != nil
          if let image { check.images["command"] = image }
        }
        container.checkShortcutKeys(["R"], event: event)
        let direct = header.checkPressed("reload") && header.checkPressedCaps == ["⌘", "R"]
        if screen {
          check.capturing = true
          let image = promptScreenScreenshot(host.window(), name: "header-command-r", withoutShadow: true)
          check.capturing = false
          capturesOK = capturesOK && image != nil
          if let image { check.images["command_r"] = image }
        }
        header.checkDismissTooltip()
        container.resizeHandle.sidebarWidth = 199; container.layoutSubtreeIfNeeded()
        container.checkShortcutKeys(["R"], event: event)
        let menuPressed = header.checkPressed("menu")
        if screen {
          check.capturing = true
          let image = promptScreenScreenshot(host.window(), name: "header-command-r-narrow", withoutShadow: true)
          check.capturing = false
          capturesOK = capturesOK && image != nil
          if let image { check.images["command_r_narrow"] = image }
        }
        container.checkShortcutKeys(["W"], event: event)
        let closePressed = sidebar.checkClosePressed(id: check.id)
        check.details["pressed"] = ["command_cap": commandCap, "direct": direct, "menu": menuPressed, "close": closePressed]
        check.conditions["pressed"] = commandCap && direct && menuPressed && closePressed
        if screen {
          check.capturing = true
          let image = promptScreenScreenshot(host.window(), name: "header-command-w", withoutShadow: true)
          check.capturing = false
          capturesOK = capturesOK && image != nil
          if let image { check.images["command_w"] = image }
        }
        container.checkShortcutKeys([], event: event)
      }
      if screen { check.conditions["capture"] = capturesOK }
      container.resizeHandle.sidebarWidth = 240; container.layoutSubtreeIfNeeded()
      check.navigation = tab.navigationCount
      guard let port = promptFixturePort else { wait("fixture port"); return }
      host.checkNavigate("http://127.0.0.1:\(port)/pending", disposition: "current")
      browserCheckPhase = 2
    case 2:
      guard snapshot.selectedId == check.id, host.activeItemId() == check.id,
            let tab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == check.id && $0.liveId == check.live }),
            tab.navigationCount > check.navigation, tab.url.hasSuffix("/pending"), header.loading else { wait("pending loading"); return }
      check.conditions["loading_stop"] = header.checkReloadLabel == "Stop"
      if screen {
        check.capturing = true
        let image = promptScreenScreenshot(host.window(), name: "header-loading", withoutShadow: true)
        check.capturing = false
        check.conditions["capture"] = check.conditions["capture"] == true && image != nil
        if let image { check.images["loading"] = image }
      }
      _ = host.runCommand("stop")
      browserCheckPhase = 3
    case 3:
      guard snapshot.selectedId == check.id, host.activeItemId() == check.id, !header.loading else { wait("stop loading"); return }
      check.conditions["stopped"] = header.checkReloadLabel == "Reload"
      if screen {
        check.capturing = true
        let image = promptScreenScreenshot(host.window(), name: "header-stopped", withoutShadow: true)
        check.capturing = false
        check.conditions["capture"] = check.conditions["capture"] == true && image != nil
        if let image { check.images["stopped"] = image }
      }
      check.conditions["back"] = header.checkEnabled["back"] == true && host.runCommand("back")
      browserCheckPhase = 4
    case 4:
      guard snapshot.selectedId == check.id, host.activeItemId() == check.id, header.checkEnabled["forward"] == true else { wait("back navigation"); return }
      check.conditions["forward"] = host.runCommand("forward")
      browserCheckPhase = 5
    case 5:
      guard snapshot.selectedId == check.id, host.activeItemId() == check.id,
            let tab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == check.id && $0.liveId == check.live }), tab.url.hasSuffix("/pending") else { wait("forward navigation"); return }
      _ = host.runCommand("stop")
      browserCheckPhase = 6
    case 6:
      guard snapshot.selectedId == check.id, host.activeItemId() == check.id, !header.loading else { wait("forward stop"); return }
      // p4checks: the … menu's own Find in Page… item, the path the menu runs.
      guard header.checkPerformMenuItem("Find in Page…") else { check.conditions["find"] = false; finish(); return }
      browserCheckPhase = 7
    case 7:
      guard !container.findBar.isHidden,
            let tab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == check.id && $0.liveId == check.live }) else { wait("find bar"); return }
      check.conditions["find"] = true
      check.conditions["menu_find"] = true
      host.findAction("close", text: "", selection: NSRange(location: 0, length: 0), liveId: check.live, profile: host.profileDirectory())
      // p4checks: Zoom In and Zoom Out are the … menu's own items.
      let zoom = host.checkZoomLevel()
      let zoomIn = header.checkPerformMenuItem("Zoom In") && host.checkZoomLevel() > zoom
      let zoomOut = header.checkPerformMenuItem("Zoom Out") && abs(host.checkZoomLevel() - zoom) < 0.001
      check.conditions["zoom"] = zoomIn && zoomOut
      check.conditions["menu_zoom"] = zoomIn && zoomOut
      let menu = header.makeMenu().items.filter { !$0.isSeparatorItem }
      let domain = host.currentSiteDomain()
      let enabled = domain == "127.0.0.1" && menu[3].isEnabled && menu[4].isEnabled && menu[4].toolTip == "Clears cookies for 127.0.0.1"
      // B3: the header's two site commands go through the menu item, the path the app header
      // really uses (onHeaderCommand → performWorkspaceCommand), not host.runCommand.
      let cache = header.checkPerformMenuItem("Clear Cache")
      let cookies = header.checkPerformMenuItem("Clear Cookies")
      check.conditions["clear"] = enabled && cache && cookies
      check.conditions["clear_via_menu"] = enabled && cache && cookies
      check.navigation = tab.navigationCount
      check.conditions["force_reload"] = header.checkPerformMenuItem("Force Reload")
      browserCheckPhase = 8
    case 8:
      let results = host.checkSiteClearResults()
      guard let cache = results["clear_cache_site"] as? NSNumber, let cookies = results["clear_cookies_site"] as? NSNumber,
            let tab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == check.id && $0.liveId == check.live }), tab.navigationCount > check.navigation else { wait("clear completion and force reload"); return }
      check.conditions["clear"] = check.conditions["clear"] == true && cache.uint64Value == 0 && cookies.uint64Value == 0
      _ = host.runCommand("stop")
      check.navigation = tab.navigationCount
      host.checkNavigate("chrome://version", disposition: "current")
      browserCheckPhase = 9
    case 9:
      guard snapshot.selectedId == check.id, host.activeItemId() == check.id,
            let tab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == check.id && $0.liveId == check.live }),
            tab.navigationCount > check.navigation, tab.url.hasPrefix("chrome://version") else { wait("chrome version"); return }
      let menu = header.makeMenu().items.filter { !$0.isSeparatorItem }
      check.conditions["internal_schemes"] = host.currentSiteDomain() == nil && !menu[3].isEnabled && !menu[4].isEnabled
      check.navigation = tab.navigationCount
      host.checkNavigate("about:blank", disposition: "current")
      browserCheckPhase = 10
    case 10:
      guard snapshot.selectedId == check.id, host.activeItemId() == check.id,
            let tab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == check.id && $0.liveId == check.live }),
            tab.navigationCount > check.navigation, tab.url == "about:blank" else { wait("about blank"); return }
      let menu = header.makeMenu().items.filter { !$0.isSeparatorItem }
      check.conditions["internal_schemes"] = check.conditions["internal_schemes"] == true && host.currentSiteDomain() == nil && !menu[3].isEnabled && !menu[4].isEnabled
      // p4checks: the header's own buttons. The fixture's /pending never finishes, so the reload
      // button is Stop while it loads and Reload once it is stopped.
      guard let port = promptFixturePort else { wait("fixture port"); return }
      host.checkNavigate("http://127.0.0.1:\(port)/pending", disposition: "current")
      browserCheckPhase = 11
    case 11:
      guard let tab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == check.id && $0.liveId == check.live }),
            tab.url.hasSuffix("/pending"), header.loading else { wait("pending for the reload button"); return }
      check.navigation = tab.navigationCount
      FileHandle.standardError.write(Data("ararat-trace: header press the reload button while loading\n".utf8))
      guard header.checkPress("reload") else { check.conditions["button_reload_stop"] = false; finish(); return }
      browserCheckPhase = 12
    case 12:
      guard !header.loading, let tab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == check.id && $0.liveId == check.live }) else { wait("the reload button stopped the page"); return }
      check.conditions["button_reload_stop"] = header.checkReloadLabel == "Reload"
      check.navigation = tab.navigationCount
      FileHandle.standardError.write(Data("ararat-trace: header press the reload button again\n".utf8))
      guard header.checkPress("reload") else { check.conditions["button_reload_stop"] = false; finish(); return }
      browserCheckPhase = 13
    case 13:
      guard let tab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == check.id && $0.liveId == check.live }),
            header.loading, tab.navigationCount > check.navigation else { wait("reload from the button"); return }
      guard header.checkPress("reload") else { check.conditions["button_reload_stop"] = false; finish(); return }
      browserCheckPhase = 14
    case 14:
      guard !header.loading else { wait("second stop from the button"); return }
      check.sidebarBefore = container.sidebarState
      FileHandle.standardError.write(Data("ararat-trace: header press toggle_sidebar \(check.sidebarBefore)\n".utf8))
      guard header.checkPress("toggle_sidebar") else { check.conditions["button_toggle"] = false; finish(); return }
      browserCheckPhase = 15
    case 15:
      guard container.sidebarState != check.sidebarBefore else { wait("the toggle_sidebar button"); return }
      FileHandle.standardError.write(Data("ararat-trace: header press toggle_sidebar again \(container.sidebarState)\n".utf8))
      guard header.checkPress("toggle_sidebar") else { check.conditions["button_toggle"] = false; finish(); return }
      browserCheckPhase = 16
    case 16:
      guard container.sidebarState == check.sidebarBefore else { wait("the toggled-back sidebar"); return }
      check.conditions["button_toggle"] = true
      if screen {
        check.capturing = true
        let image = promptScreenScreenshot(host.window(), name: "header-buttons", withoutShadow: true)
        check.capturing = false
        check.conditions["capture"] = check.conditions["capture"] == true && image != nil
        if let image { check.images["buttons"] = image }
      }
      finish()
    default: finish()
    }
  }
}
