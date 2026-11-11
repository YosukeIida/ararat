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
    var otherWindow: NSWindow?
    var folderCount = 0
    var selectedSpace = ""

    static func conditionNames(screen: Bool) -> [String] {
        ["seed", "cells", "wheel_input", "wheel_settled", "library_open", "library_closed", "menu", "new_folder", "refused", "escape", "drop_refused", "drop_duration", "tint_inactive", "tint_active", "minimum_docked", "minimum_hidden"] + (screen ? ["wheel_mid", "capture_cells", "capture_mid", "capture_refused"] : ["follow_mid"])
    }
    static func conditionResults(_ conditions: [String: Bool], screen: Bool) -> (values: [String: Bool], failed: [String]) {
        let names = conditionNames(screen: screen)
        return (Dictionary(uniqueKeysWithValues: names.map { ($0, conditions[$0] == true) }), names.filter { conditions[$0] != true })
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
        let dock = sidebar.map { dockDescendants($0).compactMap { $0 as? SpaceDockView }.first } ?? nil
        return ["conditions": result.values, "failed_conditions": result.failed, "phase": browserCheckPhase,
                "cell_states": dock?.cellStates.map { ["state": String(describing: $0.state), "open": $0.openFraction, "refused": $0.refused] as [String: Any] } ?? [],
                "cell_widths": dock?.subviews.map { $0.frame.width } ?? [], "mid_fractions": check?.mid ?? [],
                "window_key": host?.window().isKeyWindow ?? false, "window_main": host?.window().isMainWindow ?? false,
                "first_responder": host?.window().firstResponder.map { NSStringFromClass(type(of: $0)) } as Any? ?? NSNull(),
                "images": check?.images ?? [:], "activation_simulated": !screen,
                "mid_source": screen ? "wheel" : "trackpad_follow"]
    }

    func dockDescendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { dockDescendants($0) } }

    func dockCheckTick(_ host: any ARWindowHostAPI, screen: Bool) {
        if dockCheck == nil { dockCheck = DockScreenCheck() }
        guard let check = dockCheck, let sidebar, let container, let session = adapter?.session,
              let dock = dockDescendants(sidebar).compactMap({ $0 as? SpaceDockView }).first else { return }
        let current = session.queue.sync { session.store?.snapshot(windowId: windowID) }
        guard let current else { return }
        let window = host.window()
        func end(_ name: String, _ ok: Bool) {
            check.report(name, ok)
            if !ok { check.stop(); finishBrowserCheck(ok: false, values: dockCheckDiagnostics(screen: screen)) }
            else { browserCheckPhase += 1 }
        }
        func capture(_ name: String) -> Bool {
            guard screen else { return true }
            FileHandle.standardError.write(Data("ararat-trace: dock capturing \(name)\n".utf8))
            guard let path = promptScreenScreenshot(window, name: "dock-\(name)", withoutShadow: true) else { return false }
            check.images[name] = path
            return true
        }
        func sendWheel() {
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: 0, wheel2: -5, wheel3: 0), var input = NSEvent(cgEvent: event) else { end("wheel_input", false); return }
            if input.isDirectionInvertedFromDevice, let inverse = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: 0, wheel2: 5, wheel3: 0), let corrected = NSEvent(cgEvent: inverse) { input = corrected }
            FileHandle.standardError.write(Data("ararat-trace: dock send wheel\n".utf8))
            if screen {
                let timer = Timer(timeInterval: 0.01, repeats: true) { [weak self, weak check] _ in
                    MainActor.assumeIsolated {
                        guard let self, let check, let sidebar = self.sidebar,
                              let dock = self.dockDescendants(sidebar).compactMap({ $0 as? SpaceDockView }).first else { return }
                        let values = dock.cellStates.map(\.openFraction)
                        guard values.count > 1, values[0] > 0.05, values[0] < 0.95, values[1] > 0.05, values[1] < 0.95 else { return }
                        check.mid = values
                        FileHandle.standardError.write(Data("ararat-trace: dock capturing mid\n".utf8))
                        if let path = self.promptScreenScreenshot(window, name: "dock-mid", withoutShadow: true) { check.images["mid"] = path }
                        check.timer?.invalidate(); check.timer = nil
                    }
                }
                check.timer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
            sidebar.scrollWheel(with: input)
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
                check.report("follow_mid", values.count > 1 && values[0] > 0.05 && values[0] < 0.95 && values[1] > 0.05 && values[1] < 0.95)
                sidebar.scrollWheel(with: cancelEvent)
                browserCheckPhase = 10
                return
            }
            sendWheel()
        case 10:
            guard dock.cellStates.count > 1, dock.cellStates[0].openFraction > 0.999 else { return }
            sendWheel()
        case 1:
            guard sidebar.spaceShown == 1, dock.cellStates.count == 13, dock.cellStates[1].openFraction > 0.999, (!screen || check.mid != nil) else { return }
            check.timer?.invalidate(); check.timer = nil
            if screen { check.report("wheel_mid", true); check.report("capture_mid", check.images["mid"] != nil) }
            check.report("wheel_settled", dock.cellStates[0].openFraction < 0.001)
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
            let names = items.map(\.title)
            check.report("menu", names == ["Rename Space…", "Edit Look…", "Space Settings…", "New Folder", "Delete Space…"])
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
            let refused = dock.cellStates[index].refused && abs(dock.subviews[index].alphaValue - 0.35) < 0.001 && NSCursor.current == NSCursor.operationNotAllowed
            if screen { check.report("capture_refused", capture("refused")) }
            end("refused", refused)
        case 5:
            guard sidebar.organizeCheckEnd(cancel: true) else { end("escape", false); return }
            browserCheckPhase += 1
        case 6:
            guard sidebar.organizeCheckIdle else { return }
            check.report("escape", dock.cellStates.allSatisfy { !$0.refused } && NSCursor.current != NSCursor.operationNotAllowed)
            _ = sidebar.organizeCheckEnd()
            guard let row = current.spaces.first(where: { $0.id == check.selectedSpace })?.today.first(where: { $0.url == "about:blank?dock-drag" }),
                  sidebar.organizeCheckBegin(id: row.id, destination: "dock:named"), sidebar.organizeCheckEnd() else { end("drop_refused", false); return }
            check.report("drop_duration", abs((sidebar.organizeCheckSettleDuration ?? -1) - 0.1) < 0.001)
            browserCheckPhase = 11
        case 11:
            guard sidebar.organizeCheckIdle else { return }
            let space = current.spaces.first { $0.id == check.selectedSpace }
            check.report("drop_refused", space?.today.contains { $0.url == "about:blank?dock-drag" } == true && current.shownSpaceId == check.selectedSpace)
            check.report("minimum_docked", abs(window.contentMinSize.width - (sidebar.bounds.width + 250)) < 0.01)
            if screen {
                let other = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
                check.otherWindow = other
                other.makeKeyAndOrderFront(nil)
            } else { container.dockCheckSetMain(false) }
            browserCheckPhase += 1
        case 7:
            guard !container.spaceTintVisible, !screen || !window.isKeyWindow else { return }
            check.report("tint_inactive", true)
            if screen { window.makeKeyAndOrderFront(nil) } else { container.dockCheckSetMain(true) }
            browserCheckPhase += 1
        case 8:
            guard container.spaceTintVisible, !screen || window.isKeyWindow else { return }
            check.report("tint_active", true)
            container.toggleSidebar()
            container.layoutSubtreeIfNeeded()
            end("minimum_hidden", abs(window.contentMinSize.width - 260) < 0.01)
        case 9:
            let result = DockScreenCheck.conditionResults(check.conditions, screen: screen)
            let values = dockCheckDiagnostics(screen: screen)
            check.stop()
            finishBrowserCheck(ok: result.failed.isEmpty, values: values)
        default: break
        }
    }
}
