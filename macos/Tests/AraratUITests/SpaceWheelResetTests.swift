import AppKit
import AraratKit
import Foundation
import Testing
@testable import AraratUI

private struct LiveWheelEvent: Decodable {
    var time: Double
    var dx: Double
    var dy: Double
    var decision: String

    init(from decoder: Decoder) throws {
        var values = try decoder.unkeyedContainer()
        time = try values.decode(Double.self)
        dx = try values.decode(Double.self)
        dy = try values.decode(Double.self)
        decision = try values.decode(String.self)
    }

    var recorded: SpaceScrollRecordedEvent {
        .init(time: time, dx: dx, dy: dy, phase: .none, momentum: false, inverted: true)
    }
}

@Suite @MainActor
struct SpaceWheelRecordingResetTests {
    private func bursts() throws -> [[LiveWheelEvent]] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/trackball-live-bursts.json")
        return try JSONDecoder().decode([[LiveWheelEvent]].self, from: Data(contentsOf: url))
    }

    private func snapshot(_ index: Int) -> WorkspaceSnapshot {
        let spaces = (0..<6).map {
            SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: "default", pinnedId: "", todayId: "", favoritesId: nil, archiveAfter: .hours12, profileName: "Default", profile: .default, id: "space-\($0)", title: "Space \($0)", icon: nil, look: nil, favorites: [], pinned: [], today: [])
        }
        return WorkspaceSnapshot(archive: [], shownSpaceId: "space-\(index)", selectedId: nil, spaces: spaces)
    }

    private func wheel(dx: Double, dy: Double = 0, time: Double, inverted: Bool = true) -> NSEvent {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: 0, wheel2: 0, wheel3: 0)!
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: dx)
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy)
        cg.setIntegerValueField(CGEventField(rawValue: 137)!, value: inverted ? 1 : 0)
        cg.timestamp = UInt64(time * 1_000_000_000)
        return NSEvent(cgEvent: cg)!
    }

    @Test func liveBurstsKeepTheReviewCountsAfterEveryStoreReset() throws {
        let bursts = try bursts()
        #expect(bursts.count == 31)
        #expect(bursts.map(\.count) == [8, 7, 8, 8, 3, 5, 7, 15, 12, 5, 10, 10, 2, 1, 7, 5, 6, 7, 6, 5, 5, 3, 3, 5, 5, 4, 9, 4, 5, 40, 9])
        #expect(bursts.flatMap { $0 }.count == 229)
        var counts: [Int] = []
        for (i, burst) in bursts.enumerated() {
            if i > 0 { #expect(burst[0].time - bursts[i - 1].last!.time > 0.3) }
            for pair in zip(burst, burst.dropFirst()) { #expect(pair.1.time - pair.0.time <= 0.3) }
            let events = burst.map(\.recorded)
            let stable = SpaceScrollReplay.run(events, from: 50, count: 100)
            let reset = SpaceScrollReplay.run(events, from: 50, count: 100, resetAfterSwitch: true)
            #expect(reset.steps == stable.steps)
            counts.append(reset.steps.count)
        }
        var expected = Array(repeating: 1, count: 31)
        expected[12] = 0
        expected[13] = 0
        expected[29] = 5
        #expect(counts == expected)
        #expect(counts.filter { $0 == 1 }.count == 28)
    }

    @Test func storeEchoesDoNotCascadeIntoLibraryOrPull() throws {
        let bursts = try bursts()
        #expect(bursts[6].contains { $0.decision == "list-horizontal" })
        #expect(bursts[25].contains { $0.decision == "pull" })
        for (burstIndex, start, end) in [(6, 1, 0), (25, 4, 5)] {
            let sidebar = SidebarView(snapshot: snapshot(start))
            sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 720)
            defer { sidebar.finishScrollPresentation() }
            var switches = 0
            for event in bursts[burstIndex] {
                let decision = sidebar.decideSpaceScroll(wheel(dx: event.dx, dy: event.dy, time: event.time))
                #expect(decision.action != "pull" && decision.action != "wheel-pull-playing" && decision.action != "list-horizontal")
                if decision.action.hasPrefix("settle") {
                    switches += 1
                    let index = sidebar.spaceShown
                    sidebar.update(snapshot: snapshot(index))
                    sidebar.showSpaceWithoutNotification(at: index)
                }
            }
            #expect(switches == 1)
            #expect(sidebar.spaceShown == end)
            #expect(!sidebar.libraryOpen && !sidebar.createSpaceOpen)
        }
    }

    @Test func allViewResetPathsKeepThePauseDeadline() {
        for reset in 0..<5 {
            let sidebar = SidebarView(snapshot: snapshot(2))
            sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 720)
            defer { sidebar.finishScrollPresentation() }
            #expect(sidebar.decideSpaceScroll(wheel(dx: 2, time: 100)).action == "settle 2->3 switched")
            switch reset {
            case 0: sidebar.update(snapshot: snapshot(3))
            case 1: sidebar.showSpaceWithoutNotification(at: 3)
            case 2: sidebar.setLibraryOpen(true); sidebar.setLibraryOpen(false)
            case 3: sidebar.setCreateSpaceOpen(true); sidebar.setCreateSpaceOpen(false)
            default: sidebar.frame.size.width = 300; sidebar.layoutSubtreeIfNeeded()
            }
            #expect(sidebar.decideSpaceScroll(wheel(dx: 2, time: 100.249)).action == "ignored")
            #expect(sidebar.spaceShown == 3)
            #expect(sidebar.decideSpaceScroll(wheel(dx: 2, time: 100.25)).action == "settle 3->4 switched")
        }
    }

    @Test func directionChangeAndReturnToStartKeepTheWheelPause() {
        for inverted in [false, true] {
            let sidebar = SidebarView(snapshot: snapshot(2))
            sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 720)
            defer { sidebar.finishScrollPresentation() }
            let dx = inverted ? 2.0 : -2.0
            #expect(sidebar.decideSpaceScroll(wheel(dx: dx, time: 100, inverted: inverted)).action == "settle 2->3 switched")
            sidebar.update(snapshot: snapshot(3))
            sidebar.showSpace(at: 2)
            sidebar.spaceScrollDirection = .reversed
            #expect(sidebar.decideSpaceScroll(wheel(dx: dx, time: 100.249, inverted: inverted)).action == "ignored")
            #expect(sidebar.spaceShown == 2)
            #expect(sidebar.decideSpaceScroll(wheel(dx: dx, time: 100.25, inverted: inverted)).action == "settle 2->1 switched")
            #expect(sidebar.spaceShown == 1)
        }
    }

    @Test func playingPullPassesVerticalAndSettlesOnClassifiedReverse() {
        for reversed in [false, true] {
            for inverted in [false, true] {
                let sidebar = SidebarView(snapshot: snapshot(5))
                sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 720)
                sidebar.spaceScrollDirection = reversed ? .reversed : .natural
                var now = 0.0
                sidebar.pullClock = { now }
                defer { sidebar.finishScrollPresentation() }
                let forward = -2.0 * (inverted ? -1 : 1) * (reversed ? -1 : 1)
                #expect(sidebar.decideSpaceScroll(wheel(dx: forward, time: 100, inverted: inverted)).action == "pull")
                #expect(sidebar.decideSpaceScroll(wheel(dx: forward, time: 100.01, inverted: inverted)).action == "wheel-pull-playing")
                let vertical = sidebar.decideSpaceScroll(wheel(dx: forward, dy: 3, time: 100.02, inverted: inverted))
                #expect(!vertical.handled && vertical.action == "vertical")
                #expect(sidebar.decideSpaceScroll(wheel(dx: -forward, time: 100.03, inverted: inverted)).action == "ignored")
                #expect(sidebar.decideSpaceScroll(wheel(dx: -forward, time: 100.25, inverted: inverted)).action == "settle 5->4 switched")
                #expect(sidebar.spaceShown == 4)
                #expect(!sidebar.createSpaceOpen)
                now = 10
                sidebar.stepPull()
                #expect(!sidebar.createSpaceOpen)
            }
        }
    }

    @Test func ignoredReverseKeepsPullPlayingUntilCreationOpens() {
        for reversed in [false, true] {
            for inverted in [false, true] {
                let sidebar = SidebarView(snapshot: snapshot(5))
                sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 720)
                sidebar.spaceScrollDirection = reversed ? .reversed : .natural
                var now = 0.0
                sidebar.pullClock = { now }
                defer { sidebar.finishScrollPresentation() }
                let forward = -2.0 * (inverted ? -1 : 1) * (reversed ? -1 : 1)
                #expect(sidebar.decideSpaceScroll(wheel(dx: forward, time: 100, inverted: inverted)).action == "pull")
                for (time, reverse) in [(100.03, -forward), (100.25, -forward * 0.05)] {
                    #expect(sidebar.decideSpaceScroll(wheel(dx: reverse, time: time, inverted: inverted)).action == "ignored")
                    #expect(sidebar.decideSpaceScroll(wheel(dx: forward, time: time, inverted: inverted)).action == "wheel-pull-playing")
                    #expect(!sidebar.createSpaceOpen)
                }
                now = 10
                sidebar.stepPull()
                #expect(sidebar.createSpaceOpen)
                #expect(sidebar.spaceShown == 5)
            }
        }
    }
}
