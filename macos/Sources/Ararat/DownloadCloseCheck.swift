import AppKit
import AraratEngineAPI

extension Runtime {
  func downloadCloseCheckTick(_ host: any ARWindowHostAPI) {
    func trace(_ step: String) {
      FileHandle.standardError.write(Data("ararat-trace: download-close \(step)\n".utf8))
    }
    func startDownload(_ popup: any ARWindowHostAPI, port: UInt16) {
      trace("start fixture download")
      popup.checkNavigate("http://127.0.0.1:\(port)/slow-download", disposition: "current")
      browserCheckPhase = 3
    }
    switch browserCheckPhase {
    case 0:
      guard let row = sliceRows.first, let url = row.url else { return }
      trace("select seed")
      adapter?.select(id: row.id, url: url)
      browserCheckPhase = 1
    case 1:
      guard host.hasBrowser(), promptFixturePort != nil else { return }
      trace("create private window")
      host.checkCreateIncognito()
      browserCheckPhase = 2
    case 2:
      guard let port = promptFixturePort, let privateChild = children.first(where: { $0.isPrivateWindow && $0.host != nil }), let popup = privateChild.host, popup.isPrivateWindow() else { return }
      downloadCloseConditions["private_window"] = true
      popup.window().makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      trace("configure private download directory")
      guard popup.prepareCheckDownload() else {
        finishBrowserCheck(ok: false, values: ["error": "cannot configure private download fixture"]); return
      }
      if !errorPageConditions.isEmpty {
        trace("simulate private offline error")
        popup.checkNavigate("chrome://network-error/-106", disposition: "current")
        browserCheckPhase = 21
      } else {
        startDownload(popup, port: port)
      }
    case 21:
      guard let port = promptFixturePort, let privateHost = children.first(where: { $0.isPrivateWindow && $0.host != nil }), let popup = privateHost.host,
            let tab = (popup.tabs() as? [any ARTabAPI])?.first else { return }
      // The overlay is the user-visible signal; the net error is recorded for diagnosis.
      let failure = privateHost.adapter?.checkFailureState(item: tab.itemId ?? "") ?? [:]
      let heading = failure["heading"] as? String ?? ""
      trace("private offline url=\(tab.url) error=\(tab.networkError) heading=\(heading) loading=\(tab.isLoading) navigation=\(tab.navigationCount)")
      guard tab.networkError == -106 || heading == "You’re offline" else { return }
      errorPageConditions["private_offline"] = true
      startDownload(popup, port: port)
    case 3:
      guard let privateChild = children.first(where: { $0.isPrivateWindow && $0.host != nil }), let popup = privateChild.host, popup.checkInProgressDownloadCount() == 1 else { return }
      downloadCloseConditions["download_pending"] = true
      trace("close private window with download pending")
      popup.close()
      browserCheckPhase = 4
    case 4:
      guard let privateChild = children.first(where: { $0.isPrivateWindow && $0.host != nil }), let popup = privateChild.host, popup.hasBrowser(), popup.window().isVisible, popup.checkInProgressDownloadCount() == 1,
            let sheet = popup.window().attachedSheet, sheet.isVisible else { return }
      downloadCloseConditions["close_blocked"] = true
      func buttons(_ element: NSAccessibilityProtocol) -> [NSAccessibilityProtocol] {
        let children = NSAccessibility.unignoredChildren(from: element.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityProtocol }
        return children.filter { $0.accessibilityRole() == .button } + children.flatMap { buttons($0) }
      }
      let defaultButton = sheet.accessibilityDefaultButton() as AnyObject?
      let candidates = defaultButton.map { defaultButton in buttons(sheet).filter { ($0 as AnyObject) !== defaultButton } } ?? []
      if candidates.count == 1 && candidates[0].accessibilityPerformPress() {
        trace("pressed accessibility button")
      } else {
        downloadCloseFallback = true
        trace("accept download dialog through Views")
        popup.checkKeyboardCommand("accept-download-close")
      }
      downloadCloseConditions["dialog_action"] = true
      browserCheckPhase = 5
    case 5:
      guard children.first(where: { $0.isPrivateWindow && $0.host != nil }) == nil else { return }
      downloadCloseConditions["window_closed"] = true
      let names = ["private_window", "download_pending", "close_blocked", "dialog_action", "window_closed"]
      let failed = names.filter { downloadCloseConditions[$0] != true }
      if !errorPageConditions.isEmpty {
        errorPageConditions["download_close"] = failed.isEmpty
        errorPageConditions["no_stock_browsers"] = host.checkStockBrowsers() == 0
        let pageFailed = errorPageConditionNames.filter { errorPageConditions[$0] != true }
        browserCheckMode = CommandLine.arguments.contains("--ararat-screen=errorpages") ? "screen-errorpages" : "errorpages"
        finishBrowserCheck(ok: pageFailed.isEmpty, values: ["conditions": errorPageConditions, "failed_conditions": pageFailed,
          "download_conditions": downloadCloseConditions, "download_failed_conditions": failed, "dialog_fallback": downloadCloseFallback, "screenshots": errorPageImages])
        return
      }
      host.checkNewWindow()
      browserCheckPhase = 6
    case 6:
      guard let child = children.first(where: { !$0.isPrivateWindow && $0.host != nil }), let popup = child.host,
            popup.hasBrowser(), let port = promptFixturePort else { return }
      let directory = popup.prepareDownloadsCheckDirectory("regular-close")
      guard !directory.isEmpty else { finishBrowserCheck(ok: false, values: ["error": "cannot configure regular download"]); return }
      popup.checkNavigate("http://127.0.0.1:\(port)/slow-download", disposition: "current")
      browserCheckPhase = 7
    case 7:
      guard let child = children.first(where: { !$0.isPrivateWindow && $0.host != nil }), let popup = child.host,
            popup.checkInProgressDownloadCount() == 1 else { return }
      downloadCloseConditions["regular_download_pending"] = true
      popup.close()
      browserCheckPhase = 8
    case 8:
      guard !children.contains(where: { !$0.isPrivateWindow && $0.host != nil }) else { return }
      downloadCloseConditions["regular_window_closed"] = true
      guard let item = host.downloads().compactMap({ $0 as? [String: Any] }).first(where: { $0["state"] as? Int == 0 }),
            let id = item["id"] as? String, let received = item["received"] as? Int64 else { return }
      regularDownloadCloseSample = (id, received, ProcessInfo.processInfo.systemUptime)
      browserCheckPhase = 9
    case 9:
      guard let sample = regularDownloadCloseSample, ProcessInfo.processInfo.systemUptime - sample.time >= 1 else { return }
      let item = host.downloads().compactMap { $0 as? [String: Any] }.first { $0["id"] as? String == sample.id }
      let state = item?["state"] as? Int
      downloadCloseConditions["regular_download_continues"] = (state == 0 || state == 1) && (item?["received"] as? Int64 ?? 0) > sample.received
      if state == 0 { _ = host.performDownloadAction("cancel", identifier: sample.id) }
      let names = ["private_window", "download_pending", "close_blocked", "dialog_action", "window_closed", "regular_download_pending", "regular_window_closed", "regular_download_continues"]
      let failed = names.filter { downloadCloseConditions[$0] != true }
      finishBrowserCheck(ok: failed.isEmpty, values: ["conditions": downloadCloseConditions, "failed_conditions": failed, "dialog_fallback": downloadCloseFallback])
    default: break
    }
  }
}
