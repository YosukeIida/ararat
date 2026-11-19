import AppKit
import AraratEngineAPI
import AraratUI

@MainActor
final class DownloadsCheck {
  var conditions: [String: Bool] = [:]
  var images: [String: String] = [:]
  var capturing = false
  var waitCount = 0
  var waitName = ""
  var directory = ""
  var slowID = ""
  var completeID = ""
  var resumeID = ""
  var rowIdentity: UInt?
  var received: Int64 = 0
  var completedDirectory = ""
  var pauseTime: TimeInterval = 0
  var hoverStart: TimeInterval = 0
  var privatePass = 0
  var privateBefore: Set<String> = []
  func privateSettingsMatch(_ settings: [String: Any]) -> Bool? {
    guard !settings.isEmpty else { return nil }
    return settings["directory"] as? String == directory && settings["prompt"] as? Bool == false
  }
  static let common = ["pause", "paused_bytes_stopped", "paused_ring", "paused_resume", "paused_completion", "search_name", "search_url", "search_empty", "clear_keeps_running", "clear_files_intact", "private_clear_isolated", "drag_popover", "drag_page", "seed", "empty_click_archive", "started", "ring_running", "running_actions_safe", "click_list", "popover_first", "popover_row_stable", "hover_list", "library_downloads_page", "popover_cancel_button", "library_back_arrow", "popover_remove_button", "cancel", "remove_done", "completion", "completion_ring_cleared", "resume_available", "resume", "profile_isolation", "profile_return", "private_standard", "private_custom", "private_list_live", "private_close_regular_intact"]
  static let screenNames = ["capture_ring", "capture_popover", "capture_complete", "capture_library", "capture_flight", "popover_inside_above", "popover_readable", "popover_content", "popover_rows_layout", "page_actions_fit", "page_rows_layout"]
  func names(screen: Bool) -> [String] { Self.common + (screen ? Self.screenNames : []) }
  func diagnostics(screen: Bool) -> [String: Any] {
    let names = names(screen: screen)
    return ["conditions": Dictionary(uniqueKeysWithValues: names.map { ($0, conditions[$0] == true) }),
            "failed_conditions": names.filter { conditions[$0] != true }, "wait": waitName,
            "images": images, "directory": directory, "slow_id": slowID, "complete_id": completeID,
            "resume_id": resumeID, "private_pass": privatePass, "condition_notes": ["hover_list": "0.2 second hover timer driven through the test seam; no physical cursor"],
            "unverified": ["dangerous and scanning verdicts: no deterministic fixture", "history restoration across relaunch: list rule is covered by Swift unit tests", "private manager observer destruction is not directly instrumented"]]
  }
  func mark(_ name: String, _ value: Bool = true) {
    conditions[name] = value
    FileHandle.standardError.write(Data("ararat-trace: downloads \(name)=\(value)\n".utf8))
  }
  func wait(_ name: String, _ value: String) {
    if waitName != name || waitCount % 20 == 0 {
      FileHandle.standardError.write(Data("ararat-trace: downloads wait=\(name) current=\(value)\n".utf8))
    }
    if waitName != name { waitCount = 0; waitName = name }
    waitCount += 1
  }
}

extension Runtime {
  func downloadsCheckTick(_ host: any ARWindowHostAPI, screen: Bool) {
    if downloadsCheck == nil { downloadsCheck = DownloadsCheck() }
    guard let check = downloadsCheck, !check.capturing, let sidebar else { return }
    let window = host.window()
    let state = sidebar.downloadsCheckState()
    let items = state["items"] as? [[String: Any]] ?? []
    func find(_ name: String) -> [String: Any]? { items.first { ($0["name"] as? String)?.contains(name) == true } }
    func itemID(_ item: [String: Any]?) -> String { item?["id"] as? String ?? "" }
    func number(_ item: [String: Any]?, _ key: String) -> Int64 { (item?[key] as? NSNumber)?.int64Value ?? 0 }
    func actions(_ item: [String: Any]?) -> [String] { item?["actions"] as? [String] ?? [] }
    func wait(_ name: String) { check.wait(name, "phase=\(browserCheckPhase) items=\(items.map { "\($0["name"] ?? "?"):\($0["state"] ?? "?"):\($0["received"] ?? "?")" }) key=\(window.isKeyWindow) popup=\(popups.count)") }
    func fail(_ reason: String) {
      var result = check.diagnostics(screen: screen)
      result["error"] = reason; result["phase"] = browserCheckPhase
      finishBrowserCheck(ok: false, values: result)
    }
    func capture(_ name: String, window: NSWindow) -> Bool {
      guard screen else { return true }
      check.capturing = true
      defer { check.capturing = false }
      guard let path = promptScreenScreenshot(window, name: "downloads-\(name)", withoutShadow: true) else { return false }
      check.images[name] = path
      return true
    }
    func clickLibrary() -> Bool {
      let frame = sidebar.convert(sidebar.checkLibraryButtonFrame, to: nil)
      let point = NSPoint(x: frame.midX, y: frame.midY)
      guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
            let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0) else { return false }
      NSApp.postEvent(down, atStart: false); NSApp.postEvent(up, atStart: false)
      return true
    }
    func start(_ path: String) {
      guard let port = promptFixturePort else { return }
      host.checkNavigate("http://127.0.0.1:\(port)/\(path)", disposition: "current")
    }
    func finish() {
      let result = check.diagnostics(screen: screen)
      let failed = result["failed_conditions"] as? [String] ?? ["invalid_result"]
      finishBrowserCheck(ok: failed.isEmpty, values: result)
    }
    if let error = promptFixtureError { fail("fixture: \(error)"); return }
    switch browserCheckPhase {
    case 0:
      guard let space = snapshot.spaces.first(where: { $0.id == snapshot.shownSpaceId }), let row = space.today.first, row.url != nil,
            host.hasBrowser(), promptFixturePort != nil, window.isVisible, window.isKeyWindow else { wait("seed and key window"); return }
      check.mark("seed")
      browserCheckSeedID = row.id
      FileHandle.standardError.write(Data("ararat-trace: downloads seed-select space=\(space.id) profile=\(space.profileName) item=\(row.id)\n".utf8))
      selectCheckSeed(row)
      browserCheckPhase = 1
    case 1:
      let tab = (host.tabs() as? [any ARTabAPI])?.first { $0.itemId == browserCheckSeedID }
      guard let id = browserCheckSeedID, snapshot.selectedId == id, host.activeItemId() == id,
            let tab, !tab.isLoading, tab.navigationCount > 0 else {
        check.wait("active seed tab", "seed=\(browserCheckSeedID ?? "nil") shown=\(snapshot.shownSpaceId ?? "nil") selected=\(snapshot.selectedId ?? "nil") active=\(host.activeItemId() ?? "nil") tab=\(tab != nil) loading=\(tab?.isLoading ?? false) navigations=\(tab?.navigationCount ?? 0) stage=\(checkSeedSelectionStage)")
        return
      }
      check.directory = host.prepareDownloadsCheckDirectory("standard")
      guard !check.directory.isEmpty else { fail("cannot configure scratch download directory"); return }
      guard clickLibrary() else { fail("cannot post Library click"); return }
      browserCheckPhase = 2
    case 2:
      guard state["library_open"] as? Bool == true, state["library_page"] as? String == "Archive" else { wait("empty Library click"); return }
      check.mark("empty_click_archive")
      sidebar.setLibraryOpen(false)
      start("slow-download")
      browserCheckPhase = 3
    case 3:
      if screen && check.conditions["capture_flight"] == nil {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
          check.mark("capture_flight", state["flight"] as? Bool == false && capture("reduced-motion", window: window))
        } else if state["flight"] as? Bool == true {
          check.mark("capture_flight", capture("flight", window: window))
        }
      }
      let item = find("fixture.bin")
      guard number(item, "received") > 0, state["progress"] as? String != "none", state["ring_visible"] as? Bool == true else { wait("slow download and ring"); return }
      check.slowID = itemID(item); check.received = number(item, "received")
      check.mark("started"); check.mark("ring_running")
      check.mark("running_actions_safe", actions(item).contains("cancel") && !actions(item).contains("remove") && !actions(item).contains("open"))
      if screen {
        check.mark("capture_ring", capture("ring", window: window))
      }
      guard clickLibrary() else { fail("cannot post downloads click"); return }
      browserCheckPhase = 4
    case 4:
      guard state["list"] as? Bool == true else { wait("click popover"); return }
      check.mark("click_list"); check.mark("popover_first", state["library_action"] as? String == "Open in Library")
      if screen {
        check.mark("popover_inside_above", state["popover_inside_above"] as? Bool == true)
        check.mark("popover_readable", state["popover_readable"] as? Bool == true)
        let metrics = state["popover_metrics"] as? [String: Any] ?? [:]
        FileHandle.standardError.write(Data("ararat-trace: downloads popover metrics=\(metrics)\n".utf8))
        check.mark("popover_content", (metrics["content_width"] as? CGFloat ?? 0) >= 240 && (metrics["title_font"] as? CGFloat ?? 0) >= 13 && (metrics["title_height"] as? CGFloat ?? 0) >= 13)
        check.mark("popover_rows_layout", metrics["rows_leading_and_status_fit"] as? Bool == true && metrics["header_layout"] as? Bool == true && metrics["header_title"] as? String == "Downloads")
        check.mark("capture_popover", sidebar.downloadsCheckPopoverWindow.map { capture("popover", window: $0) } ?? false)
      }
      check.rowIdentity = (state["rows"] as? [String: UInt])?[check.slowID]
      check.received = number(find("fixture.bin"), "received")
      browserCheckPhase = 5
    case 5:
      guard number(find("fixture.bin"), "received") > check.received else { wait("next progress update"); return }
      let identity = (state["rows"] as? [String: UInt])?[check.slowID]
      check.mark("popover_row_stable", identity != nil && identity == check.rowIdentity)
      sidebar.downloadsCheckClosePopover()
      browserCheckPhase = 51
    case 51:
      guard state["list"] as? Bool == false else { wait("popover close before hover"); return }
      check.hoverStart = ProcessInfo.processInfo.systemUptime
      sidebar.downloadsCheckHover()
      browserCheckPhase = 6
    case 6:
      guard ProcessInfo.processInfo.systemUptime - check.hoverStart >= 0.2,
            state["hover_fired"] as? Bool == true, state["list"] as? Bool == true else { wait("hover delay and popover"); return }
      check.mark("hover_list")
      sidebar.downloadsCheckOpenLibrary()
      browserCheckPhase = 7
    case 7:
      guard state["library_open"] as? Bool == true, state["library_page"] as? String == "Downloads",
            (state["page_ids"] as? [String] ?? []).contains(check.slowID),
            actions(find("fixture.bin")).contains("cancel") else { wait("Library Downloads page with the running row"); return }
      check.mark("library_downloads_page")
      if screen {
        check.mark("page_actions_fit", state["page_actions_fit"] as? Bool == true)
        check.mark("page_rows_layout", state["page_rows_layout"] as? Bool == true)
        check.mark("capture_library", capture("library", window: window))
      }
      // p4checks: the page's own back arrow closes the Library.
      guard sidebar.checkPressLibraryBack() else { check.mark("library_back_arrow", false); browserCheckPhase = 71; return }
      browserCheckPhase = 71
    case 71:
      guard state["library_open"] as? Bool == false else { wait("the back arrow closed the Library"); return }
      check.mark("library_back_arrow", true)
      guard clickLibrary() else { fail("cannot post the downloads click again"); return }
      browserCheckPhase = 72
    case 72:
      // The popover row's own Cancel button, on the still-running row the Library page showed.
      guard state["list"] as? Bool == true,
            actions(find("fixture.bin")).contains("cancel") else { wait("popover with the running row"); return }
      let pressed = sidebar.checkPressDownloadsRowButton(action: "cancel", id: check.slowID)
      check.mark("popover_cancel_button", pressed)
      browserCheckPhase = 73
    case 73:
      // The cancelled row offers Remove; that button, in the same popover, removes it.
      guard state["list"] as? Bool == true,
            let item = items.first(where: { itemID($0) == check.slowID }), number(item, "state") == 2,
            actions(item).contains("remove") else { wait("cancelled item with Remove"); return }
      check.mark("cancel", true)
      let removed = sidebar.checkPressDownloadsRowButton(action: "remove", id: check.slowID)
      check.mark("popover_remove_button", removed)
      sidebar.downloadsCheckClosePopover()
      browserCheckPhase = 9
    case 9:
      guard !items.contains(where: { itemID($0) == check.slowID }) else { wait("removed item"); return }
      check.mark("remove_done")
      start("complete-download")
      browserCheckPhase = 10
    case 10:
      let item = find("complete-check")
      guard number(item, "state") == 1, !itemID(item).isEmpty else { wait("completed item"); return }
      check.completeID = itemID(item)
      check.completedDirectory = check.directory
      check.mark("completion")
      sidebar.downloadsCheckHover()
      browserCheckPhase = 101
    case 101:
      guard state["list"] as? Bool == true else { wait("completed popover"); return }
      // The image design reads for the header's inset and a finished row's action buttons.
      if screen && check.conditions["capture_complete"] == nil {
        check.mark("capture_complete", sidebar.downloadsCheckPopoverWindow.map { capture("popover-complete", window: $0) } ?? false)
      }
      let expected = URL(fileURLWithPath: (check.directory as NSString).appendingPathComponent("complete-check.txt"))
      check.mark("drag_popover", sidebar.downloadsCheckDragURL(id: check.completeID, page: false).flatMap(URL.init(string:)) == expected)
      sidebar.downloadsCheckOpenLibrary()
      check.mark("drag_page", sidebar.downloadsCheckDragURL(id: check.completeID, page: true).flatMap(URL.init(string:)) == expected)
      sidebar.downloadsCheckSearch("COMPLETE-CHECK")
      check.mark("search_name", (sidebar.downloadsCheckState()["page_ids"] as? [String]) == [check.completeID])
      sidebar.downloadsCheckSearch("/complete-download")
      check.mark("search_url", (sidebar.downloadsCheckState()["page_ids"] as? [String]) == [check.completeID])
      sidebar.downloadsCheckSearch("no-match-for-download")
      check.mark("search_empty", (sidebar.downloadsCheckState()["page_ids"] as? [String])?.isEmpty == true)
      sidebar.downloadsCheckSearch("")
      sidebar.setLibraryOpen(false)
      check.mark("completion_ring_cleared", state["progress"] as? String == "none" && state["ring_visible"] as? Bool == false)
      start("resume-download")
      browserCheckPhase = 11
    case 11:
      let item = find("resume-check")
      guard number(item, "state") == 3, actions(item).contains("resume") else { wait("resumable interrupted download"); return }
      check.resumeID = itemID(item)
      check.mark("resume_available")
      guard let fixture = promptFixture else { fail("fixture disappeared"); return }
      browserCheckPhase = 111
      fixture.allowDownloadResume { [weak self, weak host] in
        DispatchQueue.main.async {
          guard let self, let host, self.browserCheckPhase == 111 else { return }
          guard host.performDownloadAction("resume", identifier: check.resumeID) else { fail("resume was not accepted"); return }
          self.browserCheckPhase = 12
        }
      }
    case 12:
      guard let item = items.first(where: { itemID($0) == check.resumeID }), number(item, "state") == 1 else { wait("resumed completion"); return }
      check.mark("resume")
      sidebar.setLibraryOpen(false)
      switchWorkspaceSpace("named")
      browserCheckPhase = 13
    case 111:
      wait("fixture enabling manual resume")
    case 13:
      guard snapshot.shownSpaceId == "named", host.profileDirectory() == "Profile 1", host.hasBrowser() else { wait("named profile"); return }
      check.mark("profile_isolation", items.isEmpty)
      switchWorkspaceSpace("default")
      browserCheckPhase = 14
    case 14:
      guard snapshot.shownSpaceId == "default", host.profileDirectory() == "Default",
            items.contains(where: { itemID($0) == check.completeID }), items.contains(where: { itemID($0) == check.resumeID }) else { wait("return to original profile"); return }
      check.mark("profile_return")
      check.privatePass = 0
      check.privateBefore = Set(items.map(itemID))
      host.checkCreateIncognito()
      browserCheckPhase = 15
    case 15:
      guard let privateChild = children.first(where: { $0.isPrivateWindow && $0.host != nil }), let popup = privateChild.host, popup.isPrivateWindow(), popup.hasBrowser() else { wait("private window"); return }
      let settings = popup.downloadsCheckSettings()
      guard let matches = check.privateSettingsMatch(settings) else { wait("private download settings snapshot"); return }
      guard matches else { fail("private profile did not inherit scratch directory without prompt"); return }
      guard let port = promptFixturePort else { wait("fixture port"); return }
      popup.window().makeKeyAndOrderFront(nil)
      popup.checkNavigate("http://127.0.0.1:\(port)/private-download?pass=\(check.privatePass)", disposition: "current")
      browserCheckPhase = 16
    case 16:
      guard let privateChild = children.first(where: { $0.isPrivateWindow && $0.host != nil }), let popup = privateChild.host else { wait("private download window"); return }
      let path = (check.directory as NSString).appendingPathComponent("private-check.txt")
      guard FileManager.default.fileExists(atPath: path), popup.checkInProgressDownloadCount() == 0 else { wait("private file completed in regular directory"); return }
      let attrs = try? FileManager.default.attributesOfItem(atPath: path)
      let correct = (attrs?[.size] as? NSNumber)?.intValue == 8192 && popup.window().attachedSheet == nil
      check.mark(check.privatePass == 0 ? "private_standard" : "private_custom", correct)
      check.mark("private_list_live", !popup.downloads().isEmpty)
      privateChild.sidebar?.downloadsCheckHover()
      browserCheckPhase = 161
    case 161:
      guard let privateChild = children.first(where: { $0.isPrivateWindow && $0.host != nil }),
            privateChild.sidebar?.downloadsCheckState()["list"] as? Bool == true else { wait("private downloads popover"); return }
      privateChild.sidebar?.downloadsCheckClearAll()
      browserCheckPhase = 162
    case 162:
      guard let privateChild = children.first(where: { $0.isPrivateWindow && $0.host != nil }), let popup = privateChild.host,
            popup.downloads().isEmpty else { wait("private Clear All"); return }
      check.mark("private_clear_isolated", check.privateBefore == Set(items.map(itemID)))
      popup.close()
      browserCheckPhase = 17
    case 17:
      guard children.first(where: { $0.isPrivateWindow && $0.host != nil }) == nil else { wait("private window teardown"); return }
      if check.privatePass == 0 {
        check.privatePass = 1
        check.directory = host.prepareDownloadsCheckDirectory("custom")
        guard !check.directory.isEmpty else { fail("cannot configure custom scratch directory"); return }
        host.checkCreateIncognito()
        browserCheckPhase = 15
      } else {
        check.mark("private_close_regular_intact", check.privateBefore == Set(items.map(itemID)))
        start("pausable-download")
        browserCheckPhase = 18
      }
    case 18:
      guard let item = find("pausable-check"), number(item, "received") > 0, actions(item).contains("pause") else { wait("pausable download"); return }
      check.slowID = itemID(item)
      check.mark("pause", host.performDownloadAction("pause", identifier: check.slowID))
      check.pauseTime = ProcessInfo.processInfo.systemUptime
      browserCheckPhase = 19
    case 19:
      guard let item = find("pausable-check"), item["paused"] as? Bool == true,
            ProcessInfo.processInfo.systemUptime - check.pauseTime > 1 else { wait("pause settling"); return }
      check.received = number(item, "received")
      check.pauseTime = ProcessInfo.processInfo.systemUptime
      check.mark("paused_ring", state["progress"] as? String == "paused" && state["ring_visible"] as? Bool == true)
      browserCheckPhase = 20
    case 20:
      guard ProcessInfo.processInfo.systemUptime - check.pauseTime > 1 else { return }
      check.mark("paused_bytes_stopped", number(find("pausable-check"), "received") == check.received)
      check.mark("paused_resume", host.performDownloadAction("resume", identifier: check.slowID))
      sidebar.setLibraryOpen(true)
      sidebar.downloadsCheckShowPage()
      sidebar.downloadsCheckClearAll()
      browserCheckPhase = 21
    case 21:
      guard !items.contains(where: { itemID($0) == check.completeID || itemID($0) == check.resumeID }) else { wait("Clear All"); return }
      check.mark("clear_keeps_running", items.contains { itemID($0) == check.slowID && number($0, "state") == 0 })
      check.mark("clear_files_intact", FileManager.default.fileExists(atPath: (check.completedDirectory as NSString).appendingPathComponent("complete-check.txt")))
      browserCheckPhase = 22
    case 22:
      guard let item = find("pausable-check"), number(item, "state") == 1 else { wait("paused and resumed completion"); return }
      check.mark("paused_completion")
      finish()
    default: break
    }
  }
}
