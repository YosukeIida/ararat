import AppKit
import AraratEngineAPI
import AraratKit
import AraratUI

// U25d part 3: the split commands, drag-to-split and the one-page-one-place selection.
//
// One condition per claim the unit makes. The check drives the sidebar's own seams (the menu a
// right-click shows, the drag's press/move/release), so nothing here runs a second copy of the
// rule. Every wait is bounded and names itself when it gives up, so a hung phase reports which
// claim failed instead of running into the watchdog.
@MainActor
final class SplitCommandsCheck {
  static let names = ["seed", "menu_titles", "menu_icons", "menu_leftmost", "add_right", "add_right_focus",
                      "add_right_new_tab_page", "move_left_order", "move_left_engine", "convert_axis",
                      "convert_engine", "convert_top", "menu_vertical", "menu_vertical_moves", "add_left_order",
                      "separate_row", "separate_one_pane", "close_pane", "drag_indicator", "drag_left_joins",
                      "focus_after_drop", "drag_right_joins", "drop_refused", "lone_member", "lone_engine",
                      "lone_source_split", "lone_stays", "lone_row_select", "move_leaves_split",
                      // P5d: the three entry points of Add Split View, from a lone tab each, and the
                      // key on a split's member.
                      "key_split", "key_focus", "key_new_page", "command_split", "command_focus",
                      "command_new_page", "menu_split", "menu_focus", "menu_new_page", "split_third",
                      "split_third_focus"]
  static let screenNames = ["capture_menu", "capture_menu-open", "capture_vertical", "capture_split", "capture_drop-target"]
  var conditions: [String: Bool] = [:]
  var images: [String: String] = [:]
  var capturing = false
  var waitName = ""
  var waitCount = 0
  var split = ""
  var left = ""
  var right = ""
  var added = ""
  var addedLeft = ""
  var dragged = ""
  var draggedRight = ""
  var refusedRow = ""
  var loneMember = ""
  // P5d: the three lone tabs its entry points act on, and the split each made.
  var keyTab = ""
  var commandTab = ""
  var menuTab = ""
  var keySplit = ""
  var commandSplit = ""
  var menuSplit = ""
  var frames: [String: NSRect] = [:]
  var points: [String: NSPoint] = [:]
  var parentPanes = 0
  var memberCount = 0
  var indicatorSeen = false
  var child: Runtime?
  func mark(_ name: String, _ value: Bool = true) {
    conditions[name] = value
    FileHandle.standardError.write(Data("ararat-trace: split-commands \(name)=\(value)\n".utf8))
  }
  func wait(_ name: String, _ details: String, everyTime: Bool = false) {
    if everyTime || name != waitName || waitCount % 20 == 0 { FileHandle.standardError.write(Data("ararat-trace: split-commands wait=\(name) \(details)\n".utf8)) }
    if name != waitName { waitCount = 0; waitName = name }
    waitCount += 1
  }
  func diagnostics(screen: Bool) -> [String: Any] {
    let required = Self.names + (screen ? Self.screenNames : [])
    return ["conditions": Dictionary(uniqueKeysWithValues: required.map { ($0, conditions[$0] == true) }),
            "failed_conditions": required.filter { conditions[$0] != true }, "wait": waitName,
            "images": images, "split": split, "member": loneMember,
            "add_split": ["key": keySplit, "command": commandSplit, "menu": menuSplit],
            "phase": conditions.count]
  }
}

extension Runtime {
  // The check's own failure path, so a completion that fires after the tick can fail the run.
  fileprivate func splitCommandsFail(_ message: String, screen: Bool) {
    var result = (splitCommandsCheck ?? SplitCommandsCheck()).diagnostics(screen: screen)
    result["error"] = message
    finishBrowserCheck(ok: false, values: result)
  }

  func splitCommandsCheckTick(_ host: any ARWindowHostAPI, screen: Bool) {
    if splitCommandsCheck == nil { splitCommandsCheck = SplitCommandsCheck() }
    guard let check = splitCommandsCheck, !check.capturing, let adapter, let sidebar, let container, let workspace else { return }
    let window = host.window()
    let tabs = (host.tabs() as? [any ARTabAPI]) ?? []
    let state = adapter.checkSplitLayout()
    func details() -> String {
      let drag = sidebar.dragStateForCheck
      var selection = ""
      if (28...35).contains(browserCheckPhase) {
        let source = browserCheckPhase <= 29 ? check.keyTab : browserCheckPhase <= 32 ? check.commandTab : check.menuTab
        let members = splitHolding(source).map { adapter.checkSplitMembers($0) } ?? []
        selection = " " + adapter.checkSplitSelectionTrace(items: [check.keyTab, source] + members)
          + " shownSpace=\(snapshot.shownSpaceId ?? "nil") sidebarSpace=\(sidebar.spaceShown) source=\(source) newPane=\(members.last ?? "nil") focusedPane=\(sidebar.focusedPane?.id ?? "nil")"
      }
      return "phase=\(browserCheckPhase) selected=\(snapshot.selectedId ?? "nil") active=\(host.activeItemId() ?? "nil") "
        + "panes=\(state.panes) members=\(check.split.isEmpty ? [] : adapter.checkSplitMembers(check.split)) "
        + "split=\(check.split) left=\(check.left.isEmpty ? "nil" : check.left) right=\(check.right.isEmpty ? "nil" : check.right) "
        + "added=\(check.added.isEmpty ? "nil" : check.added) addedLeft=\(check.addedLeft.isEmpty ? "nil" : check.addedLeft) "
        + "drag=\(drag.active)/\(drag.settling)/\(drag.drop)" + selection
    }
    func fail(_ message: String) {
      var result = check.diagnostics(screen: screen); result["error"] = message
      finishBrowserCheck(ok: false, values: result)
    }
    // A bounded hold: true once the condition holds, false after 6 s with a named failure.
    func ready(_ name: String, _ condition: @autoclosure () -> Bool) -> Bool {
      if condition() { return true }
      check.wait(name, details(), everyTime: (28...35).contains(browserCheckPhase))
      if check.waitCount > 60 { fail("\(name) never resolved (\(details()))") }
      return false
    }
    func capture(_ name: String) {
      guard screen else { return }
      check.capturing = true; defer { check.capturing = false }
      if let path = promptScreenScreenshot(window, name: "split-commands-\(name)", withoutShadow: true) {
        check.images[name] = path; check.mark("capture_\(name)")
      }
    }
    func select(_ id: String, next: Int) {
      browserCheckPhase = 100
      workspace.select(id: id) { result in
        guard case .success = result else { self.splitCommandsFail("select \(id)", screen: screen); return }
        self.showAndSelect(result)
        self.browserCheckPhase = next
      }
    }
    func rowURL(_ id: String) -> String? { adapter.checkRowURL(id) }
    func childAdapterLayout(_ check: SplitCommandsCheck) -> Int {
      check.child?.adapter?.checkSplitLayout().panes ?? -1
    }
    func traceWholeSplit(_ stage: String, child: Runtime, childAdapter: EngineAdapter) {
      let rows = child.snapshot.spaces.flatMap { $0.today + $0.pinned + $0.favorites }
      let row = rows.first { $0.id == check.loneMember }
      let layout = childAdapter.checkSplitLayout()
      let childTabs = (child.host?.tabs() as? [any ARTabAPI]) ?? []
      let message = "ararat-trace: split-commands whole-split=\(stage) "
        + "a_window=\(adapter.checkWindowID) a_selected=\(snapshot.selectedId ?? "nil") a_active=\(host.activeItemId() ?? "nil") "
        + "b_window=\(childAdapter.checkWindowID) b_selected=\(child.snapshot.selectedId ?? "nil") b_active=\(child.host?.activeItemId() ?? "nil") "
        + "member=\(check.loneMember) split=\(check.split) owner=\(splitOwner(check.loneMember, rows: rows)) "
        + "member_live_in=\(childAdapter.checkLiveWindow(check.loneMember) ?? "nil") b_tabs=\(childTabs.map { "\($0.itemId):\($0.liveId)" }) "
        + "row_present=\(row != nil) row_parent=\(row?.parentId ?? "nil") row_kind=\(String(describing: row?.kind)) row_unloaded=\(String(describing: row?.unloaded)) row_has_url=\(rowURL(check.loneMember) != nil) "
        + "b_panes=\(layout.panes) b_split=\(layout.split) expected_panes=\(check.parentPanes)\n"
      FileHandle.standardError.write(Data(message.utf8))
    }
    func pageHalfPoint(_ rightHalf: Bool) -> NSPoint? {
      guard let frame = container.pageFrameInWindowForCheck, frame.width > 0 else { return nil }
      return NSPoint(x: frame.minX + frame.width * (rightHalf ? 0.75 : 0.25), y: frame.midY)
    }
    func awaitTab(_ id: String) -> Bool { tabs.contains { $0.itemId == id && !$0.isLoading } }
    // A row that exists only in the store (created by WorkspaceAdapter.createTab: a core row plus
    // the window's selection, no live tab) is waited for by its delivered row, not by a tab: the
    // press's own select opens the tab.
    func rowInSnapshot(_ id: String) -> Bool {
      snapshot.spaces.flatMap { $0.today + $0.pinned }.contains { $0.id == id }
    }
    func menuTitles(_ pane: String) -> [String]? {
      sidebar.paneMenuForCheck(paneID: pane)?.items.filter { !$0.isSeparatorItem }.map(\.title)
    }
    // P5d: the split that holds a row, found in the delivered snapshot (the split row names it)
    // and confirmed by the core's own members.
    func splitHolding(_ pane: String) -> String? {
      guard let space = snapshot.spaces.first(where: { $0.id == snapshot.shownSpaceId }) else { return nil }
      return space.today.filter { $0.kind == .split }.first { adapter.checkSplitMembers($0.id).contains(pane) }?.id
    }
    // The pane that became a member: the one id that was not there before.
    func newMember(in members: [String], known: Set<String>) -> String? {
      members.first { !known.contains($0) }
    }
    switch browserCheckPhase {
    case 0:
      guard ready("seed", window.isKeyWindow && window.isVisible && host.hasBrowser()
                  && snapshot.spaces.first { $0.id == snapshot.shownSpaceId }?.today.contains { $0.kind == .split } == true) else { return }
      guard let space = snapshot.spaces.first(where: { $0.id == snapshot.shownSpaceId }),
            let splitRow = space.today.first(where: { $0.kind == .split }) else { fail("no split row in the seed space"); return }
      check.split = splitRow.id
      let members = adapter.checkSplitMembers(splitRow.id)
      guard let left = members.first(where: { rowURL($0)?.contains("split-commands-left") == true }),
            let right = members.first(where: { rowURL($0)?.contains("split-commands-right") == true }) else {
        fail("the seed split is not the two seeded tabs: \(members.map { rowURL($0) ?? "nil" })"); return
      }
      check.left = left
      check.right = right
      check.mark("seed", members == [left, right])
      select(left, next: 1)
    case 1:
      guard ready("split pages", snapshot.selectedId == check.left && host.activeItemId() == check.left
                  && state.panes == 2 && awaitTab(check.left)) else { return }
      guard let menu = sidebar.paneMenuForCheck(paneID: check.left) else { fail("no menu for the split pane"); return }
      let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
      check.mark("menu_titles", titles == ["Move Left", "Move Right", "Add Right Split", "Add Left Split",
                                           "Separate Tab from Split", "Convert to Vertical Split View", "Close Pane"])
      let items = menu.items.filter { !$0.isSeparatorItem }
      check.mark("menu_icons", !items.isEmpty && items.allSatisfy { $0.image != nil })
      let rightMenu = sidebar.paneMenuForCheck(paneID: check.right)
      check.mark("menu_leftmost", menu.items[0].isEnabled == false && menu.items[1].isEnabled == true
                  && rightMenu?.items[0].isEnabled == true && rightMenu?.items[1].isEnabled == false)
      capture("menu")
      if screen, let frame = sidebar.rowFrameForCheck(check.split), let view = window.contentView {
        let point = view.convert(NSPoint(x: frame.minX + frame.width / 4, y: frame.midY), from: nil)
        check.capturing = true
        let path = promptScreenMenuScreenshot(menu, window: window, name: "split-commands-menu-open") {
          menu.popUp(positioning: nil, at: point, in: view)
        }
        check.capturing = false
        check.images["menu-open"] = path
        check.mark("capture_menu-open", path != nil)
      }
      check.frames = adapter.checkSplitFocus().panes
      guard sidebar.runPaneMenuItemForCheck(paneID: check.right, titled: "Add Right Split") else { fail("add right split item"); return }
      browserCheckPhase = 2
    case 2:
      let members = adapter.checkSplitMembers(check.split)
      guard ready("add right split", members.count == 3 && state.panes == 3 && awaitTab(members.last ?? "")) else { return }
      guard let pane = newMember(in: members, known: [check.left, check.right]) else { fail("no new member after Add Right Split: \(members)"); return }
      check.added = pane
      check.mark("add_right", members == [check.left, check.right, pane])
      guard ready("add right focus", sidebar.focusedPane?.id == pane && host.activeItemId() == pane) else { return }
      check.mark("add_right_focus", sidebar.focusedPane?.id == pane)
      check.mark("add_right_new_tab_page", rowURL(pane) == "chrome://newtab/")
      check.frames = adapter.checkSplitFocus().panes
      guard sidebar.runPaneMenuItemForCheck(paneID: check.added, titled: "Move Left") else { fail("move left item"); return }
      browserCheckPhase = 3
    case 3:
      let members = adapter.checkSplitMembers(check.split)
      guard ready("move left", members == [check.left, check.added, check.right] && state.panes == 3) else { return }
      check.mark("move_left_order")
      let before = check.frames[check.added]
      guard ready("move left frames", before.map { old in
        adapter.checkSplitFocus().panes[check.added].map { abs($0.minX - old.minX) > 1 } ?? false
      } ?? false) else { return }
      check.mark("move_left_engine")
      // The frames the Convert must change, captured after the move has been drawn.
      check.frames = adapter.checkSplitFocus().panes
      guard sidebar.runPaneMenuItemForCheck(paneID: check.left, titled: "Convert to Vertical Split View") else { fail("convert item"); return }
      browserCheckPhase = 4
    case 4:
      // The core turns the axis before main delivers the new frames, so the changed geometry is
      // part of the wait (review 3, N2): a stale tick cannot mark these false.
      func converted() -> Bool {
        guard adapter.checkSplitAxis(check.split) == "vertical", state.panes == 3,
              !check.frames.isEmpty, adapter.checkSplitFocus().panes != check.frames else { return false }
        return true
      }
      guard ready("convert", converted()) else { return }
      check.mark("convert_axis")
      let members = adapter.checkSplitMembers(check.split)
      let frames = adapter.checkSplitFocus().panes
      // The card is unflipped, so a greater y is higher on screen: the first pane must be on top.
      let top = frames.max { $0.value.minY < $1.value.minY }?.key
      let stacked = frames.values.sorted { $0.minY < $1.minY }
      check.mark("convert_engine", stacked.count == 3
                  && abs(stacked[0].minX - stacked[1].minX) < 1 && abs(stacked[1].minX - stacked[2].minX) < 1
                  && abs(stacked[0].minY - stacked[1].minY) > 1)
      check.mark("convert_top", top == members.first)
      capture("vertical")
      // Move's words follow the axis, and the ends disable as they do side by side.
      let vertical = sidebar.paneMenuForCheck(paneID: check.left)
      let verticalTitles = vertical?.items.filter { !$0.isSeparatorItem }.map(\.title) ?? []
      check.mark("menu_vertical", verticalTitles == ["Move Up", "Move Down", "Add Right Split", "Add Left Split",
                                                     "Separate Tab from Split", "Convert to Horizontal Split View", "Close Pane"])
      check.mark("menu_vertical_moves", vertical?.items[0].isEnabled == false && vertical?.items[1].isEnabled == true)
      guard sidebar.runPaneMenuItemForCheck(paneID: check.left, titled: "Convert to Horizontal Split View") else { fail("convert back item"); return }
      browserCheckPhase = 5
    case 5:
      guard ready("convert back", adapter.checkSplitAxis(check.split) == "horizontal") else { return }
      check.frames = adapter.checkSplitFocus().panes
      guard sidebar.runPaneMenuItemForCheck(paneID: check.left, titled: "Add Left Split") else { fail("add left item"); return }
      browserCheckPhase = 6
    case 6:
      let members = adapter.checkSplitMembers(check.split)
      guard ready("add left split", members.count == 4 && state.panes == 4) else { return }
      guard let pane = newMember(in: members, known: [check.left, check.right, check.added]) else { fail("no new member after Add Left Split: \(members)"); return }
      check.addedLeft = pane
      check.mark("add_left_order", members == [pane, check.left, check.added, check.right])
      capture("split")
      // Separate acts on the focused pane: make it the selection and wait for the core and the
      // engine to agree before the command runs (design's VM, phase 7).
      select(check.addedLeft, next: 7)
    case 7:
      guard ready("separate pane focused", snapshot.selectedId == check.addedLeft && host.activeItemId() == check.addedLeft),
            ready("separate split drawn", adapter.checkSplitMembers(check.split).count == 4 && state.panes == 4) else { return }
      check.frames = adapter.checkSplitFocus().panes
      guard sidebar.runPaneMenuItemForCheck(paneID: check.addedLeft, titled: "Separate Tab from Split") else { fail("separate item"); return }
      browserCheckPhase = 8
    case 8:
      // The pane leaves the split: one less member, and its own top-level Today row right after
      // the split's row. The window keeps the separated pane as its page, so no split is drawn.
      // The row lives in the delivered snapshot, so the wait includes it (review 3, N2).
      func separated() -> ([String], Bool) {
        let members = adapter.checkSplitMembers(check.split)
        let rows = (snapshot.spaces.first { $0.id == snapshot.shownSpaceId }?.today ?? []).filter { $0.depth == 0 }
        let splitIndex = rows.firstIndex { $0.id == check.split }
        let paneIndex = rows.firstIndex { $0.id == check.addedLeft }
        return (members, splitIndex != nil && paneIndex != nil && paneIndex == splitIndex.map { $0 + 1 })
      }
      let (members, rowAfterSplit) = separated()
      guard ready("separate result", members == [check.left, check.added, check.right] && rowAfterSplit) else { return }
      check.mark("separate_one_pane")
      check.mark("separate_row", rowAfterSplit)
      select(check.left, next: 9)
    case 9:
      guard ready("close pane ready", snapshot.selectedId == check.left && host.activeItemId() == check.left
                  && state.panes == 3) else { return }
      guard sidebar.runPaneMenuItemForCheck(paneID: check.added, titled: "Close Pane") else { fail("close pane item"); return }
      browserCheckPhase = 10
    case 10:
      let members = adapter.checkSplitMembers(check.split)
      guard ready("close pane", members == [check.left, check.right] && state.panes == 2) else { return }
      check.mark("close_pane")
      check.frames = adapter.checkSplitFocus().panes
      workspace.createTab(url: "https://split-commands-drag.example/") { [weak self] result in
        guard let self, case .success(let next) = result, let id = next.id else {
          self?.splitCommandsFail("drag row", screen: screen); return
        }
        check.dragged = id
        self.browserCheckPhase = 11
      }
    case 11:
      guard ready("drag row ready", rowInSnapshot(check.dragged) && sidebar.rowFrameForCheck(check.dragged) != nil) else { return }
      // The frame is measured after the shown pane is selected again: selecting it may scroll the
      // list, and the press point must be the row's place at the press.
      select(check.left, next: 12)
    case 12:
      guard ready("drag shown tab", snapshot.selectedId == check.left && host.activeItemId() == check.left) else { return }
      guard let frame = sidebar.rowFrameForCheck(check.dragged), let left = pageHalfPoint(false) else {
        fail("no frame for the drag row"); return
      }
      let origin = NSPoint(x: frame.midX, y: frame.midY)
      guard sidebar.beginDragForCheck(id: check.dragged, at: origin) else { fail("begin drag"); return }
      for step in 1...5 { sidebar.moveDragForCheck(to: NSPoint(x: origin.x - CGFloat(step) * 16, y: origin.y)) }
      sidebar.moveDragForCheck(to: left)
      check.points["target"] = left
      browserCheckPhase = 13
    case 13:
      let indicatorVisible = container.paneDropForCheck != nil && sidebar.dragStateForCheck.drop == "split"
      if indicatorVisible { check.indicatorSeen = true }
      guard ready("drop indicator", check.indicatorSeen) else { return }
      check.mark("drag_indicator")
      if indicatorVisible { capture("drop-target") }
      guard let left = check.points["target"] else { fail("no drop point"); return }
      _ = sidebar.releaseDragForCheck(at: left)
      browserCheckPhase = 14
    case 14:
      guard ready("left drop settle", !sidebar.dragStateForCheck.active && !sidebar.dragStateForCheck.settling) else { return }
      // The core's members and the delivered selection/focus are both waited for (review 3, N2).
      guard ready("left drop", adapter.checkSplitMembers(check.split) == [check.dragged, check.left, check.right]
                  && snapshot.selectedId == check.dragged && sidebar.focusedPane?.id == check.dragged
                  && host.activeItemId() == check.dragged) else { return }
      check.mark("drag_left_joins")
      check.mark("focus_after_drop")
      workspace.createTab(url: "https://split-commands-drag-right.example/") { [weak self] result in
        guard let self, case .success(let next) = result, let id = next.id else {
          self?.splitCommandsFail("right drag row", screen: screen); return
        }
        check.draggedRight = id
        self.browserCheckPhase = 15
      }
    case 15:
      guard ready("right drag row", rowInSnapshot(check.draggedRight) && sidebar.rowFrameForCheck(check.draggedRight) != nil) else { return }
      select(check.left, next: 16)
    case 16:
      guard ready("right drag shown tab", snapshot.selectedId == check.left && host.activeItemId() == check.left) else { return }
      guard let frame = sidebar.rowFrameForCheck(check.draggedRight), let right = pageHalfPoint(true) else {
        fail("no frame for the right drag row"); return
      }
      let origin = NSPoint(x: frame.midX, y: frame.midY)
      guard sidebar.beginDragForCheck(id: check.draggedRight, at: origin) else { fail("begin right drag"); return }
      sidebar.moveDragForCheck(to: NSPoint(x: origin.x - 40, y: origin.y))
      sidebar.moveDragForCheck(to: right)
      _ = sidebar.releaseDragForCheck(at: right)
      browserCheckPhase = 17
    case 17:
      guard ready("right drop settle", !sidebar.dragStateForCheck.active && !sidebar.dragStateForCheck.settling) else { return }
      guard ready("right drop", adapter.checkSplitMembers(check.split) == [check.dragged, check.left, check.draggedRight, check.right]) else { return }
      check.mark("drag_right_joins")
      check.memberCount = adapter.checkSplitMembers(check.split).count
      // A row dragged onto the page while it is the shown tab has no half to land on.
      workspace.createTab(url: "https://split-commands-refused.example/") { [weak self] result in
        guard let self, case .success(let next) = result, let id = next.id else {
          self?.splitCommandsFail("refused row", screen: screen); return
        }
        check.refusedRow = id
        self.browserCheckPhase = 18
      }
    case 18:
      guard ready("refused row", rowInSnapshot(check.refusedRow) && sidebar.rowFrameForCheck(check.refusedRow) != nil) else { return }
      // The new tab is the shown row: dragging it onto the page offers nothing.
      select(check.refusedRow, next: 19)
    case 19:
      guard ready("refused drag ready", snapshot.selectedId == check.refusedRow && host.activeItemId() == check.refusedRow) else { return }
      guard let frame = sidebar.rowFrameForCheck(check.refusedRow), let point = pageHalfPoint(false) else {
        fail("no frame for the refused row"); return
      }
      let origin = NSPoint(x: frame.midX, y: frame.midY)
      guard sidebar.beginDragForCheck(id: check.refusedRow, at: origin) else { fail("begin refused drag"); return }
      sidebar.moveDragForCheck(to: NSPoint(x: origin.x - 40, y: origin.y))
      sidebar.moveDragForCheck(to: point)
      let offered = container.paneDropForCheck != nil || sidebar.dragStateForCheck.drop == "split"
      _ = sidebar.releaseDragForCheck(at: point)
      check.mark("drop_refused", !offered)
      browserCheckPhase = 20
    case 20:
      guard ready("refused settle", !sidebar.dragStateForCheck.settling && !sidebar.dragStateForCheck.active) else { return }
      let members = adapter.checkSplitMembers(check.split)
      check.mark("drop_refused", check.conditions["drop_refused"] == true && members.count == check.memberCount)
      guard members.count == check.memberCount else { fail("the refused drop changed the split: \(members)"); return }
      check.loneMember = members.last ?? ""
      guard !check.loneMember.isEmpty else { fail("no member for the lone check"); return }
      // §4.6: the second window takes a member of a split the first window draws — its pane keeps
      // the row and shows the captured placeholder, and the first window becoming key takes the
      // page back. The refused drop left A on a loose row, so put A on a member first; then A both
      // draws the split and holds a member as its selection when the reclaim fires.
      select(check.left, next: 21)
    case 21:
      guard ready("parent split drawn", snapshot.selectedId == check.left && host.activeItemId() == check.left
                  && state.panes == check.memberCount && state.panes > 1) else { return }
      // Captured here, while A draws its own split: the claim below is A's pane count staying the
      // same while a member is borrowed and after it comes back.
      check.parentPanes = state.panes
      guard let shown = snapshot.shownSpaceId else { fail("no space for the second window"); return }
      let child = Runtime()
      child.root = self
      do { try child.start(session: adapter.session, shownSpace: shown) } catch { fail("cannot start the second window: \(error)"); return }
      children.append(child)
      check.child = child
      browserCheckPhase = 22
    case 22:
      guard let child = check.child, let childAdapter = child.adapter else { return }
      guard ready("second window", child.snapshot.shownSpaceId == snapshot.shownSpaceId),
            let url = rowURL(check.loneMember) else { return }
      // B is the window the user is in when it takes the member: B key, A not key. A's own key
      // change at the end of phase 23 is what must reclaim the page.
      guard ready("second window key", child.host?.window().isKeyWindow == true) else {
        child.host?.window().makeKeyAndOrderFront(nil)
        return
      }
      if child.snapshot.selectedId != check.loneMember {
        childAdapter.select(id: check.loneMember, url: url, wholeSplit: false)
      }
      browserCheckPhase = 23
    case 23:
      guard let child = check.child, let childAdapter = child.adapter else { return }
      let childLayout = childAdapter.checkSplitLayout()
      // The verification lives in the child window, so its state is part of the wait's trace and
      // of the failure (review 2/design's VM: the parent's details alone could not tell which
      // half of the claim failed). Both window ids are printed: m_live_in is only readable when
      // A's own id sits beside it (design's VM, phase 23).
      let childState = "child_selected=\(child.snapshot.selectedId ?? "nil") child_active=\(child.host?.activeItemId() ?? "nil") "
        + "child_panes=\(childLayout.panes) child_split=\(childLayout.split) child_window=\(childAdapter.checkWindowID) "
        + "a_selected=\(snapshot.selectedId ?? "nil") a_panes=\(state.panes) a_window=\(adapter.checkWindowID) "
        + "m_live_in=\(childAdapter.checkLiveWindow(check.loneMember) ?? "nil") m=\(check.loneMember)"
      check.wait("lone member", childState)
      if !(child.snapshot.selectedId == check.loneMember && child.host?.activeItemId() == check.loneMember && childLayout.panes == 0) {
        if check.waitCount > 60 { fail("lone member never resolved (\(childState))") }
        return
      }
      check.mark("lone_member")
      check.mark("lone_engine", childLayout.panes == 0 && !childLayout.split)
      // The split stays in A's workspace and A still draws it (A is on a member), with M a member
      // whose page is now in B: the S4 claim, before any key change.
      let parentLayout = adapter.checkSplitLayout()
      check.mark("lone_source_split", parentLayout.panes == check.parentPanes && parentLayout.panes > 1
                  && adapter.checkSplitMembers(check.split).contains(check.loneMember)
                  && childAdapter.checkWindowID != adapter.checkWindowID)
      // MF1, the real path (review 2, N1 / review 3): A is key and its selection is a split member,
      // so A's own key change reclaims the borrowed page through takeRemoteSelection.
      window.makeKeyAndOrderFront(nil)
      browserCheckPhase = 24
    case 24:
      guard let child = check.child else { return }
      // A's selection is already a member: the key change alone must bring M's live tab back. A
      // selection here would reclaim through select(wholeSplit) and hide the key-change path.
      guard ready("A on a split member", snapshot.selectedId == check.left && host.activeItemId() == check.left) else { return }
      let childLayout = childAdapterLayout(check)
      check.wait("first window reclaims", "A selected=\(snapshot.selectedId ?? "nil") active=\(host.activeItemId() ?? "nil") "
                 + "A window=\(adapter.checkWindowID) A panes=\(adapter.checkSplitLayout().panes) A key=\(window.isKeyWindow) "
                 + "B window=\(child.adapter?.checkWindowID ?? "nil") B key=\(child.host?.window().isKeyWindow == true) "
                 + "m_live_in=\(adapter.checkLiveWindow(check.loneMember) ?? "nil") m=\(check.loneMember) child_panes=\(childLayout)")
      guard window.isKeyWindow,
            adapter.checkLiveWindow(check.loneMember) == adapter.checkWindowID,
            adapter.checkSplitLayout().panes == check.parentPanes,
            adapter.checkSplitMembers(check.split).contains(check.loneMember) else {
        if check.waitCount > 60 { fail("first window reclaims never resolved (\(check.waitName))") }
        return
      }
      // …and B becoming key takes only M back, never the whole split.
      child.host?.window().makeKeyAndOrderFront(nil)
      browserCheckPhase = 25
    case 25:
      guard let child = check.child, let childAdapter = child.adapter else { return }
      // B is key and has taken M alone, so it draws no split; A keeps its split and its members.
      guard ready("lone stays", child.host?.window().isKeyWindow == true
                  && childAdapter.checkLiveWindow(check.loneMember) == childAdapter.checkWindowID
                  && childAdapter.checkSplitLayout().panes == 0
                  && !childAdapter.checkSplitLayout().split
                  && adapter.checkSplitLayout().panes == check.parentPanes
                  && adapter.checkSplitMembers(check.split).contains(check.loneMember)) else { return }
      check.mark("lone_stays")
      // The split row's own selection in B takes the whole split, as before.
      traceWholeSplit("press", child: child, childAdapter: childAdapter)
      if child.snapshot.selectedId == check.loneMember, let url = rowURL(check.loneMember) {
        childAdapter.select(id: check.loneMember, url: url, wholeSplit: true)
      }
      browserCheckPhase = 26
    case 26:
      guard let child = check.child, let childAdapter = child.adapter else { return }
      traceWholeSplit("wait", child: child, childAdapter: childAdapter)
      guard ready("whole split in the second window", childAdapter.checkSplitLayout().panes == check.parentPanes
                  && childAdapter.checkSplitLayout().split) else { return }
      check.mark("lone_row_select")
      // S4 (1): Move Tab to another space leaves the split (the core's own rule).
      workspace.createSpace(name: "Split Commands Other") { [weak self] result in
        guard let self, case .success(let next) = result,
              let other = next.spaces.first(where: { $0.id == next.shownSpaceId }) else {
          self?.splitCommandsFail("second space", screen: screen); return
        }
        workspace.move(id: check.loneMember, container: other.todayId, index: 0, openFolder: false) { [weak self] moved in
          guard let self, case .success(let after) = moved else {
            self?.splitCommandsFail("move to another space", screen: screen); return
          }
          check.mark("move_leaves_split", !adapter.checkSplitMembers(check.split).contains(check.loneMember)
                      && after.spaces.first { $0.id == other.id }?.today.contains { $0.id == check.loneMember } == true)
          self.show(after)
          // P5d: the space was made through the adapter, so the app's create-space path (which
          // ends in the sidebar's own showSpace, applyCreatedSpace) did not run. A row menu opens
          // only on a row the sidebar shows, so the sidebar follows the window here.
          if let shown = after.shownSpaceId { sidebar.showSpaceWithoutNotification(id: shown) }
          // P5d: the three Add Split View entry points (the space the move made is the one the
          // check keeps using, so each case starts from a lone Today tab in it).
          self.browserCheckPhase = 27
        }
      }
    case 27:
      browserCheckPhase = 100
      workspace.createTab(url: "https://split-commands-add-key.example/") { [weak self] result in
        guard let self, case .success(let next) = result, let id = next.id else {
          self?.splitCommandsFail("add split key tab", screen: screen); return
        }
        check.keyTab = id
        self.showAndSelect(result.map(\.snapshot))
        self.browserCheckPhase = 28
      }
    case 28:
      guard ready("add split key tab", snapshot.selectedId == check.keyTab && rowInSnapshot(check.keyTab)
                  && host.activeItemId() == check.keyTab) else { return }
      // The key goes to the key window; the second window took the key in phase 25, so A takes it
      // back first (its menu item then answers, as it would for a user in A).
      guard ready("add split key window", window.isKeyWindow) else { window.makeKeyAndOrderFront(nil); return }
      // The key itself: Arc's ⇧⌃= as a native event through NSApp, so the menu's key equivalent
      // is what fires (the menu item is the key's one home, as with ⌘S).
      guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .shift],
                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                         context: nil, characters: "+", charactersIgnoringModifiers: "=",
                                         isARepeat: false, keyCode: 24) else { fail("no add split key event"); return }
      NSApp.sendEvent(event)
      browserCheckPhase = 29
    case 29:
      // A lone row is wrapped in a split at its place: the row first, the new pane after it.
      let split = splitHolding(check.keyTab)
      let members = split.map { adapter.checkSplitMembers($0) } ?? []
      guard ready("add split key", split != nil && members.count == 2 && members.first == check.keyTab
                  && state.panes == 2 && awaitTab(members.last ?? "")) else { return }
      let pane = members.last
      check.keySplit = split ?? ""
      check.mark("key_split")
      guard ready("add split key focus", pane.map { sidebar.focusedPane?.id == $0 && host.activeItemId() == $0 } == true) else { return }
      check.mark("key_focus")
      check.mark("key_new_page", pane.flatMap { rowURL($0) } == "chrome://newtab/")
      browserCheckPhase = 100
      workspace.createTab(url: "https://split-commands-add-command.example/") { [weak self] result in
        guard let self, case .success(let next) = result, let id = next.id else {
          self?.splitCommandsFail("add split command tab", screen: screen); return
        }
        check.commandTab = id
        self.showAndSelect(result.map(\.snapshot))
        self.browserCheckPhase = 30
      }
    case 30:
      guard ready("add split command tab", snapshot.selectedId == check.commandTab && rowInSnapshot(check.commandTab)
                  && host.activeItemId() == check.commandTab) else { return }
      // The command-bar row: the core's own list, typed the way a user reaches it. The rows land
      // when the per-open session arrives, so the wait is on the row itself.
      openCommandBar(.newTab)
      browserCheckPhase = 31
    case 31:
      guard let bar = commandPresenter?.controller else {
        check.wait("add split command bar", "no command bar \(details())", everyTime: true)
        if check.waitCount > 60 { fail("the command bar never opened") }
        return
      }
      if bar.query != "Add Split View" { bar.update(query: "Add Split View") }
      let row = { bar.result.rows.firstIndex { if case .command(let id) = $0.target { return id == "add_split_view" }; return false } }
      guard ready("add split command row", row() != nil) else { return }
      guard let index = row() else { return }
      bar.moveSelection(by: index - bar.selectedIndex)
      bar.commit(forceNewTab: false)
      browserCheckPhase = 32
    case 32:
      let split = splitHolding(check.commandTab)
      let members = split.map { adapter.checkSplitMembers($0) } ?? []
      guard ready("add split command", split != nil && members.count == 2 && members.first == check.commandTab
                  && state.panes == 2 && awaitTab(members.last ?? "")) else { return }
      let pane = members.last
      check.commandSplit = split ?? ""
      check.mark("command_split")
      guard ready("add split command focus", pane.map { sidebar.focusedPane?.id == $0 && host.activeItemId() == $0 } == true) else { return }
      check.mark("command_focus")
      check.mark("command_new_page", pane.flatMap { rowURL($0) } == "chrome://newtab/")
      browserCheckPhase = 100
      workspace.createTab(url: "https://split-commands-add-menu.example/") { [weak self] result in
        guard let self, case .success(let next) = result, let id = next.id else {
          self?.splitCommandsFail("add split menu tab", screen: screen); return
        }
        check.menuTab = id
        self.showAndSelect(result.map(\.snapshot))
        self.browserCheckPhase = 33
      }
    case 33:
      guard ready("add split menu tab", snapshot.selectedId == check.menuTab && rowInSnapshot(check.menuTab)
                  && host.activeItemId() == check.menuTab) else { return }
      // The row menu's item, after Duplicate, run through the item's own action.
      guard sidebar.runTabMenuItemForCheck(id: check.menuTab, titled: "Add Split View") else {
        let menu = sidebar.tabMenuForCheck(id: check.menuTab)
        fail("no enabled Add Split View item on the tab row: menu=\(menu.map { $0.items.map { "\($0.title)=\($0.isEnabled)" }.joined(separator: ",") } ?? "nil") "
             + "sidebar_space=\(sidebar.spaceShown) window_space=\(snapshot.shownSpaceId ?? "nil")")
        return
      }
      browserCheckPhase = 34
    case 34:
      let split = splitHolding(check.menuTab)
      let members = split.map { adapter.checkSplitMembers($0) } ?? []
      guard ready("add split menu", split != nil && members.count == 2 && members.first == check.menuTab
                  && state.panes == 2 && awaitTab(members.last ?? "")) else { return }
      let pane = members.last
      check.menuSplit = split ?? ""
      check.mark("menu_split")
      guard ready("add split menu focus", pane.map { sidebar.focusedPane?.id == $0 && host.activeItemId() == $0 } == true) else { return }
      check.mark("menu_focus")
      check.mark("menu_new_page", pane.flatMap { rowURL($0) } == "chrome://newtab/")
      // Already a split: the selection is the new pane, a member, so the same key adds a pane to
      // its right (the segment menu's Add Right Split on that pane).
      guard ready("add split third window", window.isKeyWindow) else { window.makeKeyAndOrderFront(nil); return }
      guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .shift],
                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                         context: nil, characters: "+", charactersIgnoringModifiers: "=",
                                         isARepeat: false, keyCode: 24) else { fail("no add split third key event"); return }
      NSApp.sendEvent(event)
      browserCheckPhase = 35
    case 35:
      let members = adapter.checkSplitMembers(check.menuSplit)
      guard ready("add split third", members.count == 3 && state.panes == 3) else { return }
      check.mark("split_third")
      guard ready("add split third focus", members.last.map { sidebar.focusedPane?.id == $0 && host.activeItemId() == $0 } == true) else { return }
      check.mark("split_third_focus")
      let result = check.diagnostics(screen: screen)
      finishBrowserCheck(ok: (result["failed_conditions"] as? [String] ?? ["invalid"]).isEmpty, values: result)
    default: break
    }
  }
}
