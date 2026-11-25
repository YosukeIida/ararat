import AppKit
import AraratKit
import AraratUI
import AraratEngineAPI

@MainActor
final class DockScreenCheck {
    var conditions: [String: Bool] = [:]
    var images: [String: String] = [:]
    var timer: Timer?
    var mid: [CGFloat]?
    var midTrace: [[String: Any]] = []
    var wheelTicks = 0
    var favoritePages: [String: Set<String>] = [:]
    // Set while the fade image is being written: the screenshot spins the run loop, so a check tick
    // can run inside the capture before the image path exists.
    var capturing = false
    var otherWindow: NSWindow?
    var folderCount = 0
    var selectedSpace = ""
    // p4checks: the space the dock menu deletes, its neighbour (the space the sidebar and the
    // host must move to), and the page Space Settings… should show.
    var deletedSpaceID = ""
    var neighbourSpaceID = ""
    var deletedSpaceCount = 0
    var deletedProfile = ""
    var neighbourProfile = ""
    var settingsSpaceID = ""
    var settingsWaited = 0
    // libwidth: the user's own sidebar width, read before the Library opens, and the ticks spent
    // revealing the floating sidebar at the window's left edge.
    var userWidth: CGFloat = 0
    var floatTicks = 0
    var floatBase: TimeInterval = 0
    var details: [String: Any] = [:]

    static func conditionNames(screen: Bool) -> [String] {
        ["seed", "cells", "wheel_input", "wheel_start", "wheel_settled", "favorites_before", "favorites_mid", "favorites_after", "library_open", "library_closed", "menu", "new_folder", "refused", "escape", "drop_refused", "drop_duration", "tint_initial", "minimum_docked", "minimum_hidden", "delete_space_sheet", "delete_space_count", "delete_space_shown", "delete_space_profile", "space_settings_page", "library_own_width", "library_user_width_kept", "library_closed_width", "library_floating_width"] + (screen ? ["tint_inactive", "tint_active", "wheel_mid", "capture_cells", "capture_mid", "capture_refused", "capture_delete_space", "capture_space_settings", "capture_library_docked", "capture_library_closed", "capture_library_floating"] : ["follow_mid"])
    }
    static func conditionResults(_ conditions: [String: Bool], screen: Bool) -> (values: [String: Bool], failed: [String]) {
        let names = conditionNames(screen: screen)
        return (Dictionary(uniqueKeysWithValues: names.map { ($0, conditions[$0] == true) }), names.filter { conditions[$0] != true })
    }
    // The trackpad follow is driven by exact, synchronously applied deltas, so its sample still has
    // to be visibly mid and the hidden variant keeps this band.
    static func midBand(_ values: [CGFloat]) -> Bool {
        values.count > 1 && values[0] > 0.05 && values[0] < 0.95 && values[1] > 0.05 && values[1] < 0.95
    }
    // The wheel's spring is timed by the render server, and a VM presents coarse frames: design
    // measured a real mid state of [0.9905, 0.0095], outside any band worth naming. So the wheel
    // pump accepts any frame with both cells strictly between the two pages whose fractions still
    // add up to one page, compared at 1e-6.
    static let midCrossFadeTolerance: CGFloat = 1e-6
    static func midCrossFade(_ values: [CGFloat]) -> Bool {
        values.count > 1 && values[0] > 0 && values[0] < 1 && values[1] > 0 && values[1] < 1
            && abs(values[0] + values[1] - 1) <= midCrossFadeTolerance
    }
    // One mid_trace row: the accepted frame, whether its image was written, and the re-read after
    // the flush, which is diagnostics only — the slide can land during the capture.
    static func midTraceRow(scroll: [String: Any], offset: Double, fractions: [CGFloat],
                            captured: Bool, postFlush: [CGFloat]?) -> [String: Any] {
        var row = scroll
        row["offset"] = offset
        row["fractions"] = fractions.map { Double($0) }
        row["captured"] = captured
        if let postFlush { row["post_flush"] = postFlush.map { Double($0) } }
        return row
    }
    // Phase 1 may advance only when the switch has landed and the capture is not in flight: the
    // screenshot spins the run loop, so a tick can arrive there before the image path is assigned.
    static func wheelPhaseLanded(shown: Int, fractions: [CGFloat], capturing: Bool) -> Bool {
        !capturing && shown == 1 && fractions.count == 13 && fractions[1] > 0.999
    }
    // Reads the pump trace: an offset of 0 means either no animation (a paging fault) or an
    // animation this display never presented (a frame limit), and the trace carries which.
    var midReading: String {
        guard !midTrace.isEmpty else { return "no samples" }
        let animated = midTrace.contains { $0["animation"] as? Bool == true }
        guard animated else { return "no space.scroll animation in \(midTrace.count) samples: the paging did not animate" }
        let offsets = midTrace.compactMap { ($0["presentation"] as? NSNumber)?.doubleValue }
        guard offsets.contains(where: { $0 != 0 }) else {
            return "animation present, presentation stayed 0 in \(midTrace.count) samples: this display presents no frames"
        }
        return "animation and frames seen in \(midTrace.count) samples"
    }
    func report(_ name: String, _ value: Bool) {
        conditions[name] = value
        FileHandle.standardError.write(Data("ararat-trace: dock \(name)=\(value)\n".utf8))
    }
    func stop() { timer?.invalidate(); timer = nil; otherWindow?.orderOut(nil); otherWindow = nil }
}

extension Runtime {
    func dockCheckDiagnostics(screen: Bool) -> [String: Any] {
        let check = dockCheck
        let result = DockScreenCheck.conditionResults(check?.conditions ?? [:], screen: screen)
        let dock = sidebar?.dockCheckView
        return ["conditions": result.values, "failed_conditions": result.failed, "phase": browserCheckPhase,
                "details": check?.details ?? [:],
                "cell_states": dock?.cellStates.map { ["state": String(describing: $0.state), "open": $0.openFraction, "refused": $0.refused] as [String: Any] } ?? [],
                "cell_widths": dock?.subviews.map { $0.frame.width } ?? [],
                "cell_alphas": dock?.subviews.map { $0.alphaValue } ?? [], "mid_fractions": check?.mid ?? [],
                "mid_trace": check?.midTrace ?? [], "wheel_ticks": check?.wheelTicks ?? 0,
                "mid_reading": check?.midReading ?? "", "capturing": check?.capturing ?? false,
                "cursor_not_allowed": NSCursor.current == NSCursor.operationNotAllowed,
                "cursor": String(describing: NSCursor.current),
                "tint_visible": container?.spaceTintVisible as Any? ?? NSNull(),
                "content_min_width": host?.window().contentMinSize.width as Any? ?? NSNull(),
                "sidebar_width": sidebar?.bounds.width as Any? ?? NSNull(),
                "sidebar_mode": container?.sidebarState as Any? ?? NSNull(),
                "window_key": host?.window().isKeyWindow ?? false, "window_main": host?.window().isMainWindow ?? false,
                "first_responder": host?.window().firstResponder.map { NSStringFromClass(type(of: $0)) } as Any? ?? NSNull(),
                "images": check?.images ?? [:],
                "mid_source": screen ? "wheel" : "trackpad_follow"]
    }

    func dockCheckTick(_ host: any ARWindowHostAPI, screen: Bool) {
        if dockCheck == nil { dockCheck = DockScreenCheck() }
        guard let check = dockCheck, let sidebar, let container, let session = adapter?.session else { return }
        let dock = sidebar.dockCheckView
        let current = session.queue.sync { session.store?.snapshot(windowId: windowID) }
        guard let current else { return }
        let window = host.window()
        func end(_ name: String, _ ok: Bool) {
            check.report(name, ok)
            if !ok { check.stop(); finishBrowserCheck(ok: false, values: dockCheckDiagnostics(screen: screen)) }
            else { browserCheckPhase += 1 }
        }
        func capture(_ name: String, window target: NSWindow? = nil) -> Bool {
            guard screen else { return true }
            FileHandle.standardError.write(Data("ararat-trace: dock capturing \(name)\n".utf8))
            guard let path = promptScreenScreenshot(target ?? window, name: "dock-\(name)", withoutShadow: true) else { return false }
            check.images[name] = path
            return true
        }
        func sendWheel() {
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: 0, wheel2: -5, wheel3: 0), var input = NSEvent(cgEvent: event) else { end("wheel_input", false); return }
            if input.isDirectionInvertedFromDevice, let inverse = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: 0, wheel2: 5, wheel3: 0), let corrected = NSEvent(cgEvent: inverse) { input = corrected }
            FileHandle.standardError.write(Data("ararat-trace: dock send wheel\n".utf8))
            if screen {
                // Why the check pumps the dock sampler: SidebarView moves the dock from a display
                // link, and the VM run landed the switch with no sample in between (mid_fractions
                // empty while cell 1 was open), so the display link delivered no callbacks there.
                // The offset the pump reads is still the page layer's presentation value, and the
                // acceptance rule is midCrossFade: the VM presents coarse frames, so a near-end
                // pair still counts as the cross-fade.
                check.midTrace.removeAll()
                let timer = Timer(timeInterval: 0.01, repeats: true) { [weak self, weak check] _ in
                    MainActor.assumeIsolated {
                        guard let self, let check, let sidebar = self.sidebar else { return }
                        let dock = sidebar.dockCheckView
                        let offset = sidebar.dockCheckSampleLook()
                        let scroll = sidebar.dockCheckScrollState
                        let values = dock.cellStates.map(\.openFraction)
                        var captured = false
                        var postFlush: [CGFloat]?
                        if DockScreenCheck.midCrossFade(values) {
                            let pages = sidebar.dockCheckFavoritePages
                            check.report("favorites_mid", check.favoritePages.count == 2 && check.favoritePages.allSatisfy { pages[$0.key] == $0.value })
                            // Draw the accepted sample before imaging it: the pump only marks the
                            // cells for display and screencapture blocks the main thread, so without
                            // this the image is the previous pass.
                            window.displayIfNeeded()
                            CATransaction.flush()
                            // Why the re-read is not a condition: the spring can land during the
                            // flush and the capture, so the drawn frame may no longer be a
                            // cross-fade; the frame the rule accepted is the one that gets imaged.
                            // The re-read stays in mid_trace so a run still shows that the slide
                            // landed in the capture.
                            postFlush = dock.cellStates.map(\.openFraction)
                            check.mid = values
                            FileHandle.standardError.write(Data("ararat-trace: dock capturing mid\n".utf8))
                            // Set around the wait, not just the call: screencapture is waited for by
                            // spinning the run loop, so a phase-1 tick runs before this returns.
                            check.capturing = true
                            if let path = self.promptScreenScreenshot(window, name: "dock-mid", withoutShadow: true) { check.images["mid"] = path }
                            check.capturing = false
                            captured = check.images["mid"] != nil
                            check.timer?.invalidate(); check.timer = nil
                        }
                        if check.midTrace.count < 60 {
                            check.midTrace.append(DockScreenCheck.midTraceRow(scroll: scroll, offset: offset,
                                                                             fractions: values, captured: captured,
                                                                             postFlush: postFlush))
                        }
                    }
                }
                check.timer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
            sidebar.scrollWheel(with: input)
            // Both variants: the switch must start from the departing cell, so a switch that snapped
            // the dock fill to the destination fails here. Only the screen variant can also see the
            // fade itself (wheel_mid), and only with presentation frames to sample.
            let states = dock.cellStates
            check.report("wheel_start", sidebar.spaceShown == 1 && states.count > 1 && states[0].openFraction > 0.999 && states[1].openFraction < 0.001)
            check.report("wheel_input", true)
            browserCheckPhase = 1
        }
        switch browserCheckPhase {
        case 0:
            guard current.spaces.count == 13, current.shownSpaceId == "default", sidebar.spaceShown == 0 else { return }
            sidebar.layoutSubtreeIfNeeded()
            let states = dock.cellStates
            guard states.count == 13, dock.subviews.count == 13 else { return }
            let sameProfile = current.spaces.filter { $0.profileKey == current.spaces[0].profileKey }
            for space in current.spaces.prefix(2) {
                check.favoritePages[space.id] = Set(space.favorites.filter { $0.url == "about:blank?dock-favorite-\(space.id)" }.map(\.id))
            }
            let firstTiles = check.favoritePages["default"] ?? []
            let nextTiles = check.favoritePages["dock-0"] ?? []
            check.userWidth = container.resizeHandle.sidebarWidth
            check.report("favorites_before", firstTiles.count == 1 && nextTiles.count == 1 && firstTiles.isDisjoint(with: nextTiles)
                         && sidebar.dockCheckFavoritePages["default"] == firstTiles)
            let widths = dock.subviews.map { $0.frame.width }
            let total = widths.reduce(0, +)
            check.report("seed", sameProfile.count == 12 && current.spaces.last?.id == "named")
            let touching = zip(dock.subviews, dock.subviews.dropFirst()).allSatisfy { abs($0.frame.maxX - $1.frame.minX) < 0.01 }
            check.report("cells", widths[0] == 22 && states[0].state != .dot && states.dropFirst().allSatisfy { $0.state == .dot } && touching && total <= dock.bounds.width && abs((dock.subviews.first?.frame.minX ?? -1) - (dock.bounds.width - total) / 2) < 0.01)
            if screen { check.report("capture_cells", capture("cells")) }
            if !screen {
                guard let follow = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: -144, wheel3: 0),
                      let cancel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: 0, wheel3: 0) else { end("follow_mid", false); return }
                follow.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(CGScrollPhase.began.rawValue))
                cancel.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(CGScrollPhase.cancelled.rawValue))
                guard let followEvent = NSEvent(cgEvent: follow), let cancelEvent = NSEvent(cgEvent: cancel) else { end("follow_mid", false); return }
                FileHandle.standardError.write(Data("ararat-trace: dock send trackpad follow and cancel\n".utf8))
                sidebar.scrollWheel(with: followEvent)
                let values = dock.cellStates.map(\.openFraction)
                check.mid = values
                check.report("follow_mid", DockScreenCheck.midBand(values))
                let pages = sidebar.dockCheckFavoritePages
                check.report("favorites_mid", check.favoritePages.count == 2 && check.favoritePages.allSatisfy { pages[$0.key] == $0.value })
                sidebar.scrollWheel(with: cancelEvent)
                browserCheckPhase = 10
                return
            }
            sendWheel()
        case 10:
            guard dock.cellStates.count > 1, dock.cellStates[0].openFraction > 0.999 else { return }
            sendWheel()
        case 1:
            check.wheelTicks += 1
            guard DockScreenCheck.wheelPhaseLanded(shown: sidebar.spaceShown,
                                                   fractions: dock.cellStates.map(\.openFraction),
                                                   capturing: check.capturing) else {
                // Why the flag and not a re-ordering: promptScreenScreenshot waits for screencapture
                // by spinning the run loop, so this tick can run inside the capture, before
                // check.images["mid"] is assigned; nothing can be assigned before the call returns.
                guard !check.capturing else { return }
                // A 0.25 s spring plus one engine round trip; past three seconds the switch is not
                // coming, and the tick count and mid trace below name what did happen.
                guard check.wheelTicks >= 30 else { return }
                FileHandle.standardError.write(Data("ararat-trace: dock wheel did not land after \(check.wheelTicks) ticks shown=\(sidebar.spaceShown) open=\(dock.cellStates.map(\.openFraction)) mid=\(check.midReading)\n".utf8))
                if screen { check.report("wheel_mid", check.mid != nil) }
                check.report("wheel_settled", false)
                finishBrowserCheck(ok: false, values: dockCheckDiagnostics(screen: screen))
                return
            }
            // The pump writes the mid sample; once the landing is visible no later sample can be
            // mid, so an empty mid here is the answer rather than a reason to wait for the timeout.
            check.timer?.invalidate(); check.timer = nil
            if screen {
                if check.mid == nil { FileHandle.standardError.write(Data("ararat-trace: dock no mid sample, mid=\(check.midReading)\n".utf8)) }
                check.report("wheel_mid", check.mid != nil); check.report("capture_mid", check.images["mid"] != nil)
            }
            let landed = dock.cellStates[0].openFraction < 0.001
            check.report("wheel_settled", landed)
            let favoritePages = sidebar.dockCheckFavoritePages
            check.report("favorites_after", favoritePages["dock-0"] == check.favoritePages["dock-0"])
            guard landed else { finishBrowserCheck(ok: false, values: dockCheckDiagnostics(screen: screen)); return }
            sidebar.setLibraryOpen(true)
            end("library_open", sidebar.libraryOpen && sidebar.libraryOpenFraction == 1)
        case 2:
            sidebar.setLibraryOpen(false)
            end("library_closed", !sidebar.libraryOpen && sidebar.libraryOpenFraction == 0)
        case 3:
            guard current.spaces.indices.contains(sidebar.spaceShown) else { return }
            let space = current.spaces[sidebar.spaceShown]
            check.selectedSpace = space.id
            let items = sidebar.dockMenuItems(for: space.id)
            let names = items.map { $0.isSeparatorItem ? nil : $0.title }
            check.report("menu", names == ["Rename Space…", "Edit Look…", "Space Settings…", nil, "New Folder", nil, "Delete Space…"])
            guard let item = items.first(where: { $0.title == "New Folder" }), item.isEnabled, let action = item.action else { end("new_folder", false); return }
            check.folderCount = Int(space.pinnedCount)
            FileHandle.standardError.write(Data("ararat-trace: dock invoke New Folder\n".utf8))
            if !NSApp.sendAction(action, to: item.target, from: item) { end("new_folder", false); return }
            browserCheckPhase += 1
        case 4:
            guard let space = current.spaces.first(where: { $0.id == check.selectedSpace }), Int(space.pinnedCount) == check.folderCount + 1,
                  let row = space.today.first(where: { $0.url == "about:blank?dock-drag" }) else { return }
            check.report("new_folder", true)
            sidebar.dockCheckEnableDragAnimation()
            window.makeFirstResponder(sidebar)
            FileHandle.standardError.write(Data("ararat-trace: dock begin refused drag\n".utf8))
            guard sidebar.organizeCheckBegin(id: row.id, destination: "dock:named") else { end("refused", false); return }
            let index = current.spaces.firstIndex { $0.id == "named" }!
            FileHandle.standardError.write(Data("ararat-trace: dock inspect refused cursor=\(String(describing: NSCursor.current)) not_allowed=\(NSCursor.current == NSCursor.operationNotAllowed) alpha=\(dock.subviews[index].alphaValue)\n".utf8))
            let refused = dock.cellStates[index].refused && abs(dock.subviews[index].alphaValue - 0.35) < 0.001 && NSCursor.current == NSCursor.operationNotAllowed
            if screen { check.report("capture_refused", capture("refused")) }
            end("refused", refused)
        case 5:
            FileHandle.standardError.write(Data("ararat-trace: dock send Escape\n".utf8))
            guard sidebar.organizeCheckEnd(cancel: true) else { end("escape", false); return }
            browserCheckPhase += 1
        case 6:
            guard sidebar.organizeCheckIdle else { return }
            check.report("escape", dock.cellStates.allSatisfy { !$0.refused } && NSCursor.current != NSCursor.operationNotAllowed)
            _ = sidebar.organizeCheckEnd()
            FileHandle.standardError.write(Data("ararat-trace: dock begin second refused drag and drop\n".utf8))
            guard let row = current.spaces.first(where: { $0.id == check.selectedSpace })?.today.first(where: { $0.url == "about:blank?dock-drag" }),
                  sidebar.organizeCheckBegin(id: row.id, destination: "dock:named"), sidebar.organizeCheckEnd() else { end("drop_refused", false); return }
            check.report("drop_duration", abs((sidebar.organizeCheckSettleDuration ?? -1) - 0.1) < 0.001)
            browserCheckPhase = 11
        case 11:
            guard sidebar.organizeCheckIdle else { return }
            let space = current.spaces.first { $0.id == check.selectedSpace }
            check.report("drop_refused", space?.today.contains { $0.url == "about:blank?dock-drag" } == true && current.shownSpaceId == check.selectedSpace)
            check.report("minimum_docked", abs(window.contentMinSize.width - (sidebar.bounds.width + 250)) < 0.01)
            browserCheckPhase = 12
        case 12:
            guard container.spaceTintVisible, !screen || window.isKeyWindow else { return }
            check.report("tint_initial", true)
            guard screen else { browserCheckPhase = 8; return }
            FileHandle.standardError.write(Data("ararat-trace: dock switch window inactive\n".utf8))
            let other = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
            check.otherWindow = other
            other.makeKeyAndOrderFront(nil)
            browserCheckPhase = 7
        case 7:
            guard !window.isMainWindow else { return }
            check.report("tint_inactive", container.spaceTintVisible)
            FileHandle.standardError.write(Data("ararat-trace: dock switch window active\n".utf8))
            window.makeKeyAndOrderFront(nil)
            browserCheckPhase += 1
        case 8:
            guard !screen || window.isKeyWindow else { return }
            if screen { check.report("tint_active", container.spaceTintVisible) }
            FileHandle.standardError.write(Data("ararat-trace: dock toggle sidebar\n".utf8))
            container.toggleSidebar()
            container.layoutSubtreeIfNeeded()
            check.report("minimum_hidden", abs(window.contentMinSize.width - 260) < 0.01)
            // p4checks: Delete Space… through the dock menu and the alert's own button; then
            // Space Settings… opens the shown space's page. The space deleted is the one whose
            // neighbour has the other profile (the seeded `named`, Profile 1), so the sidebar's
            // move and the host's profile can disagree; with two Default neighbours the profile
            // half of B4 would pass without the fix.
            guard current.spaces.count >= 2 else {
                check.report("delete_space_sheet", false); browserCheckPhase = 9; return
            }
            let target = current.spaces[current.spaces.count - 2]
            let neighbour = current.spaces[current.spaces.count - 1]
            check.deletedSpaceID = target.id
            check.neighbourSpaceID = neighbour.id
            check.deletedSpaceCount = current.spaces.count
            check.deletedProfile = target.profileName
            check.neighbourProfile = neighbour.profileName
            check.details["delete_space"] = ["deleted": target.id, "deleted_profile": target.profileName,
                                             "neighbour": neighbour.id, "neighbour_profile": neighbour.profileName]
            guard target.profileKey != neighbour.profileKey else {
                // Without different profiles the condition cannot fail: say so instead of passing.
                check.report("delete_space_profile", false)
                browserCheckPhase = 9
                return
            }
            guard current.shownSpaceId == target.id else {
                switchWorkspaceSpace(target.id)
                browserCheckPhase = 121
                return
            }
            browserCheckPhase = 122
        case 121:
            guard current.shownSpaceId == check.deletedSpaceID,
                  host.profileDirectory() == check.deletedProfile,
                  !screen || window.isKeyWindow else { return }
            browserCheckPhase = 122
        case 122:
            let items = sidebar.dockMenuItems(for: check.deletedSpaceID)
            guard let item = items.first(where: { $0.title == "Delete Space…" }), item.isEnabled, let action = item.action else {
                check.report("delete_space_sheet", false); browserCheckPhase = 9; return
            }
            FileHandle.standardError.write(Data("ararat-trace: dock invoke Delete Space… \(check.deletedSpaceID)\n".utf8))
            NSApp.sendAction(action, to: item.target, from: item)
            browserCheckPhase = 13
        case 13:
            guard let sheet = window.attachedSheet, sheet.isVisible else { return }
            check.report("delete_space_sheet", true)
            FileHandle.standardError.write(Data("ararat-trace: dock accept \(sheet.title) with its Delete Space button\n".utf8))
            guard pressSheetButton(sheet, title: "Delete Space") else {
                // No fallback: the alert's own button is the path this condition is about.
                check.report("delete_space_count", false)
                browserCheckPhase = 9
                return
            }
            browserCheckPhase = 14
        case 14:
            guard window.attachedSheet == nil else { return }
            guard current.spaces.count == check.deletedSpaceCount - 1,
                  !current.spaces.contains(where: { $0.id == check.deletedSpaceID }) else { return }
            check.report("delete_space_count", true)
            guard let index = current.spaces.firstIndex(where: { $0.id == check.neighbourSpaceID }) else {
                check.report("delete_space_shown", false); browserCheckPhase = 9; return
            }
            // B4: the sidebar's neighbour move and the host's profile follow the same space.
            check.report("delete_space_shown", current.shownSpaceId == check.neighbourSpaceID && sidebar.spaceShown == index)
            let neighbour = current.spaces[index]
            check.report("delete_space_profile", check.neighbourProfile != check.deletedProfile
                         && host.profileDirectory() == neighbour.profileName
                         && neighbour.profileName == check.neighbourProfile)
            if screen { check.report("capture_delete_space", capture("deleted-space")) }
            check.settingsSpaceID = neighbour.id
            check.settingsWaited = 0
            guard let item = sidebar.dockMenuItems(for: neighbour.id).first(where: { $0.title == "Space Settings…" }),
                  item.isEnabled, let action = item.action else {
                check.report("space_settings_page", false); browserCheckPhase = 9; return
            }
            FileHandle.standardError.write(Data("ararat-trace: dock invoke Space Settings… \(neighbour.id)\n".utf8))
            NSApp.sendAction(action, to: item.target, from: item)
            browserCheckPhase = 15
        case 15:
            let settings = (root ?? self).settings
            guard let probe = settings?.checkProbe(), probe.pageID == "space-\(check.settingsSpaceID)" else {
                if check.settingsWaited < 60 {
                    check.settingsWaited += 1
                    FileHandle.standardError.write(Data("ararat-trace: dock space settings waiting page=\(settings?.checkProbe()?.pageID ?? "nil") want=space-\(check.settingsSpaceID)\n".utf8))
                    return
                }
                check.report("space_settings_page", false); browserCheckPhase = 9; return
            }
            FileHandle.standardError.write(Data("ararat-trace: dock space settings page=\(probe.pageID) visible=\(probe.isVisible)\n".utf8))
            check.report("space_settings_page", probe.isVisible)
            if screen, let target = settings?.window {
                check.report("capture_space_settings", capture("space-settings", window: target))
            }
            settings?.window?.performClose(nil)
            browserCheckPhase = 9
        case 9:
            // The dock's own work is done. The Library's widths and their captures follow on
            // phases 20 and up so the phases above keep their numbers and their traces.
            browserCheckPhase = 20
        case 20:
            // Pinned: a docked sidebar with the Library closed, then the Library opens at its own
            // width. Floating is phase 23.
            guard !container.sidebarAnimating else { return }
            guard container.sidebarState == "docked" else {
                FileHandle.standardError.write(Data("ararat-trace: dock library sidebar=\(container.sidebarState)\n".utf8))
                container.toggleSidebar()
                return
            }
            guard !sidebar.libraryOpen else { sidebar.setLibraryOpen(false); return }
            sidebar.setLibraryOpen(true)
            browserCheckPhase = 21
        case 21:
            guard !container.sidebarAnimating, sidebar.libraryOpen else { return }
            // libwidth: the Library takes its own measured width, not the user's 240 pt sidebar.
            let width = sidebar.bounds.width
            let arc = SidebarContainerView.libraryWidthsForCheck
            check.report("library_own_width", width == arc.library)
            check.details["library"] = ["user": check.userWidth, "docked": width,
                                        "rail": arc.rail, "list": width - arc.rail - arc.divider]
            if screen { check.report("capture_library_docked", capture("library-docked")) }
            sidebar.setLibraryOpen(false)
            browserCheckPhase = 22
        case 22:
            guard !container.sidebarAnimating, !sidebar.libraryOpen else { return }
            check.report("library_closed_width", abs(sidebar.bounds.width - check.userWidth) < 0.01)
            if screen { check.report("capture_library_closed", capture("library-closed")) }
            sidebar.setLibraryOpen(true)
            browserCheckPhase = 23
        case 23:
            // Floating: hide the sidebar and reveal it at the window's left edge, as the owner's
            // pointer does, with the Library still open. A window with no selection toggles
            // straight to floating, so both answers are accepted.
            guard !container.sidebarAnimating, sidebar.libraryOpen else { return }
            if container.sidebarState == "docked" {
                FileHandle.standardError.write(Data("ararat-trace: dock library hide for floating\n".utf8))
                container.toggleSidebar()
                return
            }
            if container.sidebarState == "hidden" {
                if check.floatBase == 0 { check.floatBase = ProcessInfo.processInfo.systemUptime }
                check.floatTicks += 1
                container.checkSamplePointer(at: NSPoint(x: window.frame.minX + 2, y: window.frame.midY),
                                             now: check.floatBase + Double(check.floatTicks) * 0.2)
                return
            }
            guard container.sidebarState == "floating" else { return }
            check.report("library_floating_width", sidebar.bounds.width == SidebarContainerView.libraryWidthsForCheck.library)
            var library = check.details["library"] as? [String: Any] ?? [:]
            library["floating"] = sidebar.bounds.width
            check.details["library"] = library
            if screen { check.report("capture_library_floating", capture("library-floating")) }
            sidebar.setLibraryOpen(false)
            browserCheckPhase = 24
        case 24:
            guard !container.sidebarAnimating, !sidebar.libraryOpen else { return }
            // The Library never writes the user's width: it is the same after both closes.
            check.report("library_user_width_kept", abs(container.resizeHandle.sidebarWidth - check.userWidth) < 0.01)
            let result = DockScreenCheck.conditionResults(check.conditions, screen: screen)
            let values = dockCheckDiagnostics(screen: screen)
            check.stop()
            finishBrowserCheck(ok: result.failed.isEmpty, values: values)
        default: break
        }
    }
}
