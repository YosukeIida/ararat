import AppKit
import AraratEngineAPI
import AraratKit
import AraratUI

@MainActor
final class ToastsCheck {
  static let common = ["seed", "url_copy", "row_copy", "command_copy", "pasteboard", "replacement", "expiry", "geometry", "window_isolation", "failure_two_windows", "profile_isolation", "retry_clears", "dismiss", "dismiss_tracks", "dismiss_retry_silent", "new_failure", "toast_announcement", "banner_announcement", "clear_undo", "clear_undo_menu", "clear_replacement", "link_click_through", "clear_click_through", "undo_hit", "split_undo"]
  static let screens = ["capture_toast", "capture_banner"]
  var conditions: [String: Bool] = [:]
  var images: [String: String] = [:]
  var capturing = false
  var waitName = ""
  var waitCount = 0
  var row: Row?
  var firstCopy: TimeInterval = 0
  var secondCopy: TimeInterval = 0
  var originalPurge: ((String, String, UInt64, @escaping (Bool) -> Void) -> Void)?
  var succeed = false
  var purgeAttempts = 0
  var retryAttempts = 0
  var firstID = ""
  var secondID = ""
  var failureProfile = ""
  var failureProfileID = ""
  var profileIsolationNote = "not evaluated"
  var toastAnnouncements = 0
  var bannerAnnouncements = 0
  var same: Runtime?
  var other: Runtime?
  var clearOrder: [String] = []
  var clearSelected = ""
  var clearGeneration = 0
  func mark(_ name: String, _ value: Bool = true) {
    conditions[name] = value
    FileHandle.standardError.write(Data("ararat-trace: toasts \(name)=\(value)\n".utf8))
  }
  func wait(_ name: String, _ value: String) {
    if waitName != name || waitCount % 20 == 0 { FileHandle.standardError.write(Data("ararat-trace: toasts wait=\(name) current=\(value)\n".utf8)) }
    if waitName != name { waitCount = 0; waitName = name }
    waitCount += 1
  }
  func diagnostics(screen: Bool) -> [String: Any] {
    let names = Self.common + (screen ? Self.screens : [])
    return ["conditions": Dictionary(uniqueKeysWithValues: names.map { ($0, conditions[$0] == true) }),
            "failed_conditions": names.filter { conditions[$0] != true }, "wait": waitName,
            "images": images, "first_id": firstID, "second_id": secondID,
            "clear_order": clearOrder, "clear_selected": clearSelected,
            "condition_notes": ["profile_isolation": profileIsolationNote],
            "unverified": ["VoiceOver speech output; notification calls are observed", "Full Keyboard Access focus traversal"]]
  }
}

extension Runtime {
  func toastsCheckTick(_ host: any ARWindowHostAPI, screen: Bool) {
    if toastsCheck == nil { toastsCheck = ToastsCheck() }
    guard let check = toastsCheck, !check.capturing, let sidebar, let container,
          let session = adapter?.session, let workspace else { return }
    let window = host.window()
    func wait(_ name: String) {
      check.wait(name, "phase=\(browserCheckPhase) key=\(window.isKeyWindow) selected=\(snapshot.selectedId ?? "nil") toast=\(container.checkToastState.visible) same=\(check.same?.sidebar?.checkHistoryVisible ?? false) other=\(check.other?.sidebar?.checkHistoryVisible ?? false)")
    }
    func fail(_ message: String) {
      if let original = check.originalPurge { session.purgeHistory = original }
      var result = check.diagnostics(screen: screen); result["error"] = message
      finishBrowserCheck(ok: false, values: result)
    }
    func capture(_ name: String) -> Bool {
      guard screen else { return true }
      check.capturing = true; defer { check.capturing = false }
      guard let path = promptScreenScreenshot(window, name: "toasts-\(name)", withoutShadow: true) else { return false }
      check.images[name] = path
      return true
    }
    func pending(_ id: String) -> Bool {
      session.queue.sync { (try? session.store?.pendingHistoryPurges().contains { $0.id == id }) ?? false }
    }
    func createFailure(next: Int) {
      browserCheckPhase = 100
      workspace.createTab(url: "data:text/html,<title>toast purge</title>") { result in
        guard case .success(let snapshot) = result, let id = snapshot.selectedId else { fail("create purge fixture"); return }
        workspace.close(id: id) { result in
          guard case .success = result else { fail("close purge fixture"); return }
          session.queue.async {
            let purge = (try? session.store?.pendingHistoryPurges().first { $0.item == id }) ?? nil
            DispatchQueue.main.async {
              guard let purge else { fail("purge fixture missing"); return }
              if next == 9 {
                check.firstID = purge.id
                switch purge.profile {
                case .default: check.failureProfile = "Default"
                case .named(let name): check.failureProfile = name
                }
                check.failureProfileID = snapshot.spaces.first { $0.profile == purge.profile }?.profileKey ?? "unknown"
              } else { check.secondID = purge.id }
              self.browserCheckPhase = next
            }
          }
        }
      }
    }
    switch browserCheckPhase {
    case 0:
      guard let space = snapshot.spaces.first(where: { $0.id == snapshot.shownSpaceId }), let row = space.today.first, row.url != nil,
            host.hasBrowser(), promptFixturePort != nil, window.isVisible, window.isKeyWindow else { wait("seed and key window"); return }
      check.row = row; browserCheckSeedID = row.id
      container.checkToastAnnouncement = { _ in check.toastAnnouncements += 1 }
      sidebar.checkHistoryAnnouncement = { _ in check.bannerAnnouncements += 1 }
      selectCheckSeed(row); browserCheckPhase = 1
    case 1:
      guard let id = browserCheckSeedID, snapshot.selectedId == id, host.activeItemId() == id,
            let tab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == id }), !tab.isLoading, tab.navigationCount > 0 else { wait("active seed tab"); return }
      check.mark("seed")
      sidebar.checkClickCopyLink(); check.firstCopy = ProcessInfo.processInfo.systemUptime
      check.mark("url_copy", container.checkToastState.visible)
      check.mark("pasteboard", NSPasteboard.general.string(forType: .string) == check.row?.url)
      container.layoutSubtreeIfNeeded()
      check.mark("link_click_through", container.checkToastHits().labelPasses)
      let state = container.checkToastState
      let grid: (CGFloat) -> Bool = { abs($0 / 8 - ($0 / 8).rounded()) < 0.001 }
      check.mark("geometry", state.page.contains(state.frame) && abs(state.frame.midX - state.page.midX) < 1 && abs(state.page.maxY - state.frame.maxY - 16) < 1 && grid(state.frame.width) && grid(state.frame.height))
      if screen { check.mark("capture_toast", capture("toast")) }
      browserCheckPhase = 2
    case 2:
      guard ProcessInfo.processInfo.systemUptime - check.firstCopy >= 1, let row = check.row else { wait("replacement interval"); return }
      let generation = container.checkToastState.generation
      check.mark("row_copy", sidebar.checkCopyMenu(row: row) && NSPasteboard.general.string(forType: .string) == row.url && container.checkToastState.generation > generation)
      check.secondCopy = ProcessInfo.processInfo.systemUptime
      browserCheckPhase = 3
    case 3:
      guard ProcessInfo.processInfo.systemUptime - check.firstCopy >= 2.25 else { wait("first expiry"); return }
      check.mark("replacement", container.checkToastState.visible)
      browserCheckPhase = 4
    case 4:
      guard ProcessInfo.processInfo.systemUptime - check.secondCopy >= 2.25, !container.checkToastState.visible else { wait("second expiry"); return }
      check.mark("expiry")
      openCommandBar(.newTab)
      guard let bar = commandPresenter?.controller else { fail("command bar unavailable"); return }
      bar.update(query: "Copy Link")
      browserCheckPhase = 41
    case 41:
      guard let bar = commandPresenter?.controller,
            let suggestion = bar.result.rows.first(where: { if case .command(let id) = $0.target { return id == "copy_link" }; return false }) else { wait("copy command suggestion"); return }
      bar.commit(suggestion)
      check.mark("command_copy", container.checkToastState.visible && NSPasteboard.general.string(forType: .string) == check.row?.url)
      check.mark("toast_announcement", check.toastAnnouncements >= 3)
      browserCheckPhase = 5
    case 5:
      guard let shown = snapshot.shownSpaceId, let named = snapshot.spaces.first(where: { $0.profileName != host.profileDirectory() })?.id else { fail("profile fixture missing"); return }
      do {
        let same = Runtime(); same.root = self; try same.start(session: session, shownSpace: shown); children.append(same)
        let other = Runtime(); other.root = self; try other.start(session: session, shownSpace: named); children.append(other)
        check.same = same; check.other = other
        same.sidebar?.checkHistoryAnnouncement = { _ in check.bannerAnnouncements += 1 }
        other.sidebar?.checkHistoryAnnouncement = { _ in check.bannerAnnouncements += 1 }
        same.host?.window().orderFront(nil); other.host?.window().orderFront(nil)
        window.makeKeyAndOrderFront(nil)
      } catch { fail("create profile windows: \(error)"); return }
      browserCheckPhase = 6
    case 6:
      guard let same = check.same, let other = check.other,
            same.snapshot.shownSpaceId == snapshot.shownSpaceId,
            let otherSpace = other.snapshot.spaces.first(where: { $0.id == other.snapshot.shownSpaceId }),
            otherSpace.profileName != host.profileDirectory(),
            other.sidebar?.checkHistoryContext.space == otherSpace.id else { wait("profile windows"); return }
      container.showLinkCopied()
      check.mark("window_isolation", container.checkToastState.visible && same.container?.checkToastState.visible == false && other.container?.checkToastState.visible == false)
      guard let original = session.purgeHistory else { fail("purge seam unavailable"); return }
      check.originalPurge = original
      session.purgeHistory = { _, _, _, completion in check.purgeAttempts += 1; completion(check.succeed) }
      createFailure(next: 9)
    case 9:
      guard sidebar.checkHistoryVisible, check.same?.sidebar?.checkHistoryVisible == true else { wait("failure banners"); return }
      check.mark("failure_two_windows")
      func windowDescription(_ label: String, _ runtime: Runtime?) -> String {
        guard let runtime else { return "\(label)=missing" }
        let space = runtime.snapshot.spaces.first { $0.id == runtime.snapshot.shownSpaceId }
        let context = runtime.sidebar?.checkHistoryContext
        return "\(label) window=\(runtime.windowID) native=\(runtime.host?.window().windowNumber ?? -1) host_profile=\(runtime.host?.profileDirectory() ?? "nil") shown_space=\(space?.id ?? "nil") shown_profile_id=\(space?.profileKey ?? "nil") shown_profile_name=\(space?.profileName ?? "nil") sidebar_space=\(context?.space ?? "nil") sidebar_profile_id=\(context?.profileID ?? "nil") sidebar_profile_name=\(context?.profile ?? "nil") banner=\(runtime.sidebar?.checkHistoryVisible == true ? "visible" : "hidden") message=\(context?.message ?? "nil")"
      }
      let detail = "purge_id=\(check.firstID) purge_profile_id=\(check.failureProfileID) purge_profile_name=\(check.failureProfile); \(windowDescription("source", self)); \(windowDescription("same", check.same)); \(windowDescription("other", check.other))"
      check.profileIsolationNote = detail
      FileHandle.standardError.write(Data("ararat-trace: toasts profile_isolation compare=source/same.sidebar.profile == purge.profile && other.sidebar == other.shown && other.profile != purge.profile && other.banner == hidden; \(detail)\n".utf8))
      let otherContext = check.other?.sidebar?.checkHistoryContext
      let otherShown = check.other?.snapshot.spaces.first { $0.id == check.other?.snapshot.shownSpaceId }
      let isolated = otherContext?.profile != nil && otherContext?.profile != check.failureProfile &&
        otherContext?.space == otherShown?.id && otherContext?.profile == otherShown?.profileName &&
        sidebar.checkHistoryContext.profile == check.failureProfile && check.same?.sidebar?.checkHistoryContext.profile == check.failureProfile &&
        check.other?.sidebar?.checkHistoryVisible == false
      check.mark("profile_isolation", isolated)
      check.mark("banner_announcement", check.bannerAnnouncements == 1)
      if screen { window.makeKeyAndOrderFront(nil); check.mark("capture_banner", capture("banner")) }
      sidebar.checkClickHistoryDismiss(); browserCheckPhase = 10
    case 10:
      guard !sidebar.checkHistoryVisible, check.same?.sidebar?.checkHistoryVisible == false else { wait("dismiss banners"); return }
      check.mark("dismiss"); check.mark("dismiss_tracks", pending(check.firstID))
      check.retryAttempts = check.purgeAttempts
      sidebar.checkClickHistoryRetry(); browserCheckPhase = 11
    case 11:
      session.queue.sync {}
      guard check.purgeAttempts > check.retryAttempts else { wait("dismissed retry submitted"); return }
      browserCheckPhase = 111
    case 111:
      guard !sidebar.checkHistoryVisible, check.same?.sidebar?.checkHistoryVisible == false, pending(check.firstID) else { wait("dismissed failed retry"); return }
      check.mark("dismiss_retry_silent"); createFailure(next: 12)
    case 12:
      guard sidebar.checkHistoryVisible, check.same?.sidebar?.checkHistoryVisible == true else { wait("new purge failure"); return }
      check.mark("new_failure"); check.succeed = true
      sidebar.checkClickHistoryRetry(); browserCheckPhase = 13
    case 13:
      guard !pending(check.firstID), !pending(check.secondID), !sidebar.checkHistoryVisible,
            check.same?.sidebar?.checkHistoryVisible == false else { wait("successful retry"); return }
      check.mark("retry_clears")
      if let original = check.originalPurge { session.purgeHistory = original }
      workspace.createTab(url: "data:text/html,<title>undo one</title>") { result in
        guard case .success = result else { fail("create undo fixture"); return }
        workspace.createTab(url: "data:text/html,<title>undo two</title>") { result in
          guard case .success(let snapshot) = result else { fail("create undo fixture"); return }
          self.show(snapshot)
          self.browserCheckPhase = 14
        }
      }
      browserCheckPhase = 100
    case 14:
      guard let space = snapshot.spaces.first(where: { $0.id == snapshot.shownSpaceId }),
            space.today.count >= 3, let selected = snapshot.selectedId,
            let row = space.today.first(where: { $0.id == selected }), let url = row.url else { wait("undo fixtures"); return }
      check.clearOrder = space.today.map(\.id); check.clearSelected = selected
      adapter?.select(id: selected, url: url)
      browserCheckPhase = 15
    case 15:
      guard host.activeItemId() == check.clearSelected else { wait("undo selected tab"); return }
      clearToday(); browserCheckPhase = 16
    case 16:
      guard let space = snapshot.spaces.first(where: { $0.id == snapshot.shownSpaceId }), space.today.isEmpty,
            container.checkToastState.visible else { wait("clear toast"); return }
      let hits = container.checkToastHits()
      check.mark("clear_click_through", hits.labelPasses)
      check.mark("undo_hit", hits.undoReceives)
      // p4checks: the Edit menu's Undo Clear Tabs item — the app's own undo path (it carries no
      // ⌘Z on purpose: a page's editable first responder keeps its own undo) — rather than the
      // toast's button, so dismissTabsCleared and the rows' return are driven by the menu.
      guard let edit = NSApp.mainMenu?.item(withTitle: "Edit")?.submenu,
            let item = edit.items.first(where: { $0.action == #selector(Runtime.undoClearTabs(_:)) }) else {
        check.mark("clear_undo_menu", false)
        container.checkUndoToast()
        browserCheckPhase = 17
        return
      }
      edit.update()
      guard item.isEnabled else {
        check.mark("clear_undo_menu", false)
        container.checkUndoToast()
        browserCheckPhase = 17
        return
      }
      FileHandle.standardError.write(Data("ararat-trace: toasts run the Edit menu's \(item.title)\n".utf8))
      NSApp.sendAction(item.action!, to: item.target, from: item)
      browserCheckPhase = 17
    case 17:
      guard let space = snapshot.spaces.first(where: { $0.id == snapshot.shownSpaceId }),
            space.today.map(\.id) == check.clearOrder, snapshot.selectedId == check.clearSelected,
            host.activeItemId() == check.clearSelected else { wait("undo restored"); return }
      check.mark("clear_undo_menu", !container.checkToastState.visible)
      check.mark("clear_undo", space.today.filter { $0.id != check.clearSelected }.allSatisfy(\.unloaded))
      clearToday(); browserCheckPhase = 18
    case 18:
      guard let space = snapshot.spaces.first(where: { $0.id == snapshot.shownSpaceId }), space.today.isEmpty,
            container.checkToastState.visible else { wait("first replacement clear"); return }
      check.clearGeneration = container.checkToastState.generation
      workspace.createTab(url: "data:text/html,<title>second clear</title>") { result in
        guard case .success(let snapshot) = result else { fail("create replacement fixture"); return }
        self.show(snapshot)
        self.browserCheckPhase = 19
      }
      browserCheckPhase = 100
    case 19:
      guard snapshot.spaces.first(where: { $0.id == snapshot.shownSpaceId })?.today.isEmpty == false else { wait("second clear fixture"); return }
      clearToday(); browserCheckPhase = 20
    case 20:
      guard container.checkToastState.generation > check.clearGeneration else { wait("second clear toast"); return }
      container.checkUndoToast(); browserCheckPhase = 21
    case 21:
      guard let space = snapshot.spaces.first(where: { $0.id == snapshot.shownSpaceId }), !space.today.isEmpty else { wait("second clear undo"); return }
      check.mark("clear_replacement", space.today.count == 1 && check.clearOrder.allSatisfy { id in !space.today.contains { $0.id == id } })
      browserCheckPhase = 100
      workspace.move(id: "close-split", container: space.todayId, index: 0, openFolder: false) { result in
        guard case .success = result else { fail("move split fixture"); return }
        workspace.select(id: "close-split-a") { result in
          guard case .success = result else { fail("select split fixture"); return }
          self.showAndSelect(result)
          self.browserCheckPhase = 22
        }
      }
    case 22:
      guard snapshot.selectedId == "close-split-a", host.activeItemId() == "close-split-a", splitCheckPagesPresented(host) else { wait("split pages before clear"); return }
      clearToday(); browserCheckPhase = 23
    case 23:
      guard snapshot.spaces.first(where: { $0.id == snapshot.shownSpaceId })?.today.isEmpty == true,
            container.checkToastState.visible else { wait("split clear"); return }
      container.checkUndoToast(); browserCheckPhase = 24
    case 24:
      guard snapshot.selectedId == "close-split-a", host.activeItemId() == "close-split-a", splitCheckPagesPresented(host) else { wait("split pages after undo"); return }
      check.mark("split_undo")
      let result = check.diagnostics(screen: screen)
      finishBrowserCheck(ok: (result["failed_conditions"] as? [String] ?? ["invalid"]).isEmpty, values: result)
    default: break
    }
  }
}
