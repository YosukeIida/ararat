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
  var hoverStart: TimeInterval = 0
  var privatePass = 0
  var privateBefore: Set<String> = []
  static let common = ["seed", "empty_click_archive", "started", "ring_running", "running_actions_safe", "click_list", "popover_first", "popover_row_stable", "hover_list", "library_downloads_page", "cancel", "remove_done", "completion", "completion_ring_cleared", "resume_available", "resume", "profile_isolation", "profile_return", "private_standard", "private_custom", "private_no_list", "private_close_regular_intact"]
  static let screenNames = ["capture_ring", "capture_popover", "capture_library", "capture_flight", "popover_inside_above", "popover_readable"]
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
      check.mark("click_list"); check.mark("popover_first", state["first"] as? String == "Open Library")
      if screen {
        check.mark("popover_inside_above", state["popover_inside_above"] as? Bool == true)
        check.mark("popover_readable", state["popover_readable"] as? Bool == true)
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
      check.hoverStart = ProcessInfo.processInfo.systemUptime
      sidebar.downloadsCheckHover()
      browserCheckPhase = 6
    case 6:
      guard state["list"] as? Bool == true else { wait("hover delay and popover"); return }
      check.mark("hover_list", ProcessInfo.processInfo.systemUptime - check.hoverStart >= 0.2)
      sidebar.downloadsCheckOpenLibrary()
      browserCheckPhase = 7
    case 7:
      guard state["library_open"] as? Bool == true, state["library_page"] as? String == "Downloads",
            (state["page_ids"] as? [String] ?? []).contains(check.slowID) else { wait("Library Downloads page"); return }
      check.mark("library_downloads_page")
      if screen { check.mark("capture_library", capture("library", window: window)) }
      guard host.performDownloadAction("cancel", identifier: check.slowID) else { fail("cancel was not offered"); return }
      browserCheckPhase = 8
    case 8:
      guard let item = items.first(where: { itemID($0) == check.slowID }), number(item, "state") == 2 else { wait("cancelled item"); return }
      check.mark("cancel", actions(item).contains("remove"))
      guard host.performDownloadAction("remove", identifier: check.slowID) else { fail("remove cancelled item failed"); return }
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
      check.mark("completion")
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
      guard let popup = popups.first?.host, popup.isPrivateWindow(), popup.hasBrowser() else { wait("private window"); return }
      let settings = popup.downloadsCheckSettings()
      guard settings["directory"] as? String == check.directory, settings["prompt"] as? Bool == false else { fail("private profile did not inherit scratch directory without prompt"); return }
      guard let port = promptFixturePort else { wait("fixture port"); return }
      popup.window().makeKeyAndOrderFront(nil)
      popup.checkNavigate("http://127.0.0.1:\(port)/private-download?pass=\(check.privatePass)", disposition: "current")
      browserCheckPhase = 16
    case 16:
      guard let popup = popups.first?.host else { wait("private download window"); return }
      let path = (check.directory as NSString).appendingPathComponent("private-check.txt")
      guard FileManager.default.fileExists(atPath: path), popup.checkInProgressDownloadCount() == 0 else { wait("private file completed in regular directory"); return }
      let attrs = try? FileManager.default.attributesOfItem(atPath: path)
      let correct = (attrs?[.size] as? NSNumber)?.intValue == 8192 && popup.window().attachedSheet == nil
      check.mark(check.privatePass == 0 ? "private_standard" : "private_custom", correct)
      check.mark("private_no_list", (check.conditions["private_no_list"] ?? true) && popup.downloads().isEmpty)
      popup.close()
      browserCheckPhase = 17
    case 17:
      guard popups.isEmpty else { wait("private window teardown"); return }
      if check.privatePass == 0 {
        check.privatePass = 1
        check.directory = host.prepareDownloadsCheckDirectory("custom")
        guard !check.directory.isEmpty else { fail("cannot configure custom scratch directory"); return }
        host.checkCreateIncognito()
        browserCheckPhase = 15
      } else {
        check.mark("private_close_regular_intact", check.privateBefore == Set(items.map(itemID)))
        finish()
      }
    default: break
    }
  }
}
