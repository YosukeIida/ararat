import AppKit
import AraratEngineAPI
import AraratKit

extension Runtime {
  var errorPageConditionNames: [String] {
    ["offline", "offline_retry", "dns", "dns_retry", "certificate_code_not_overlaid", "today_reload", "today_archive", "pin_reload", "pin_close", "private_offline", "download_close", "no_stock_browsers"]
  }

  func errorPagesCheckTick(_ host: any ARWindowHostAPI, screen: Bool) {
    guard !errorPageCapturing else { return }
    guard let adapter, let workspace, let port = promptFixturePort else { return }
    func trace(_ name: String) { FileHandle.standardError.write(Data("ararat-trace: errorpages \(name)\n".utf8)) }
    func capture(_ name: String) -> Bool {
      guard screen else { return true }
      if errorPageImages[name] != nil { return true }
      trace("capture \(name)")
      errorPageCapturing = true
      defer { errorPageCapturing = false }
      guard let path = promptScreenScreenshot(host.window(), name: "errorpages-\(name)") else { return false }
      errorPageImages[name] = path
      return true
    }
    let tab = (host.tabs() as? [any ARTabAPI])?.first { $0.itemId == errorPageItem }
    let state = errorPageItem.map { adapter.checkFailureState(item: $0) } ?? [:]
    func press(_ secondary: Bool) -> Bool {
      guard let id = errorPageItem else { return false }
      return adapter.checkFailurePress(item: id, secondary: secondary, screen: screen)
    }
    switch browserCheckPhase {
    case 0:
      guard let row = sliceRows.first, let url = row.url else { return }
      errorPageItem = row.id
      if screen { NSApp.activate(ignoringOtherApps: true); host.window().makeKeyAndOrderFront(nil) }
      trace("select seed")
      adapter.select(id: row.id, url: url)
      browserCheckPhase = 1
    case 1:
      guard let tab, !tab.isLoading, tab.navigationCount > 0 else { return }
      trace("simulate offline error")
      host.checkNavigate("chrome://network-error/-106", disposition: "current")
      browserCheckPhase = 2
    case 2:
      guard let tab, tab.networkError == -106, state["heading"] as? String == "You’re offline", state["primary"] as? String == "Try Again" else { return }
      guard capture("offline") else { return }
      errorPageConditions["offline"] = true
      errorPageNavigationCount = tab.navigationCount
      trace("retry offline")
      guard press(false) else { return }
      browserCheckPhase = 3
    case 3:
      guard let tab, tab.navigationCount > errorPageNavigationCount, !tab.isLoading else { return }
      errorPageConditions["offline_retry"] = tab.networkError == -106
      trace("navigate nonexistent domain")
      host.checkNavigate("http://ararat-check.invalid/", disposition: "current")
      browserCheckPhase = 4
    case 4:
      guard let tab, [-105, -137].contains(Int(tab.networkError)), state["primary"] as? String == "Try Again" else { return }
      guard capture("dns") else { return }
      errorPageConditions["dns"] = true
      errorPageNavigationCount = tab.navigationCount
      trace("retry DNS")
      guard press(false) else { return }
      browserCheckPhase = 5
    case 5:
      guard let tab, tab.navigationCount > errorPageNavigationCount, !tab.isLoading else { return }
      errorPageConditions["dns_retry"] = [-105, -137].contains(Int(tab.networkError))
      errorPageNavigationCount = tab.navigationCount
      trace("simulate certificate error")
      host.checkNavigate("chrome://network-error/-201", disposition: "current")
      browserCheckPhase = 51
    case 51:
      guard let tab, tab.navigationCount > errorPageNavigationCount, !tab.isLoading, tab.networkError == 0, state.isEmpty else { return }
      errorPageConditions["certificate_code_not_overlaid"] = true
      trace("navigate fixture")
      host.checkNavigate("http://127.0.0.1:\(port)/keyboard", disposition: "current")
      browserCheckPhase = 6
    case 6:
      guard let tab, !tab.isLoading, tab.url.contains("/keyboard"), tab.networkError == 0 else { return }
      trace("crash Today renderer")
      guard tab.checkCrashRenderer() else { finishBrowserCheck(ok: false, values: ["error": "renderer shutdown failed"]); return }
      browserCheckPhase = 7
    case 7:
      guard let tab, tab.crashed, state["heading"] as? String == "This page crashed", state["primary"] as? String == "Reload", state["secondary"] as? String == "Archive Tab" else { return }
      guard capture("today-crash") else { return }
      errorPageNavigationCount = tab.navigationCount
      trace("reload Today")
      guard press(false) else { return }
      browserCheckPhase = 8
    case 8:
      guard let tab, !tab.crashed, !tab.isLoading, tab.navigationCount > errorPageNavigationCount, state.isEmpty else { return }
      errorPageConditions["today_reload"] = true
      trace("crash Today again")
      guard tab.checkCrashRenderer() else { return }
      browserCheckPhase = 9
    case 9:
      guard let tab, tab.crashed, state["secondary"] as? String == "Archive Tab" else { return }
      trace("archive crashed Today tab")
      guard press(true) else { return }
      browserCheckPhase = 10
    case 10:
      guard let old = errorPageItem, !snapshot.spaces.flatMap(\.today).contains(where: { $0.id == old }) else { return }
      errorPageConditions["today_archive"] = true
      trace("create pin fixture")
      browserCheckPhase = 11
      workspace.createTab(url: "http://127.0.0.1:\(port)/keyboard") { [weak self] result in
        guard let self, case .success(let next) = result, let id = next.id else { return }
        self.errorPageItem = id
        self.show(next.snapshot)
        if next.snapshot.selectedId == id { self.adapter?.select(id: id, url: "http://127.0.0.1:\(port)/keyboard") }
      }
    case 11:
      guard let tab, !tab.isLoading, tab.url.contains("/keyboard"), let id = errorPageItem,
            let space = snapshot.spaces.first(where: { $0.id == snapshot.shownSpaceId }) else { return }
      trace("pin fixture")
      browserCheckPhase = 12
      workspace.move(id: id, container: space.pinnedId, index: 0, openFolder: false) { [weak self] result in
        if case .success(let next) = result { self?.show(next) }
      }
    case 12:
      guard let id = errorPageItem, snapshot.spaces.flatMap(\.pinned).contains(where: { $0.id == id }), let tab, !tab.isLoading else { return }
      trace("crash pinned renderer")
      guard tab.checkCrashRenderer() else { return }
      browserCheckPhase = 13
    case 13:
      guard let tab, tab.crashed, state["secondary"] as? String == "Close Tab", state["primary"] as? String == "Reload" else { return }
      guard capture("pin-crash") else { return }
      errorPageNavigationCount = tab.navigationCount
      trace("reload pinned tab")
      guard press(false) else { return }
      browserCheckPhase = 14
    case 14:
      guard let tab, !tab.crashed, !tab.isLoading, tab.navigationCount > errorPageNavigationCount, state.isEmpty else { return }
      errorPageConditions["pin_reload"] = true
      trace("crash pinned tab again")
      guard tab.checkCrashRenderer() else { return }
      browserCheckPhase = 15
    case 15:
      guard let tab, tab.crashed, state["secondary"] as? String == "Close Tab" else { return }
      trace("close crashed pin")
      guard press(true) else { return }
      browserCheckPhase = 16
    case 16:
      guard let id = errorPageItem, snapshot.spaces.flatMap(\.pinned).contains(where: { $0.id == id && $0.unloaded }) else { return }
      errorPageConditions["pin_close"] = true
      trace("create download-check seed")
      browserCheckPhase = 17
      workspace.createTab(url: "http://127.0.0.1:\(port)/keyboard") { [weak self] result in
        guard let self, case .success(let next) = result, let id = next.id else { return }
        self.errorPageItem = id
        self.show(next.snapshot)
        if next.snapshot.selectedId == id { self.adapter?.select(id: id, url: "http://127.0.0.1:\(port)/keyboard") }
      }
    case 17:
      guard host.hasBrowser(), let tab, !tab.isLoading, tab.url.contains("/keyboard") else { return }
      trace("start pending-download close check")
      browserCheckPhase = 1
      browserCheckAttempts = 0
      browserCheckMode = "download-close"
    default: break
    }
  }
}
