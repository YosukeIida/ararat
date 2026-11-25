import AppKit
import AraratEngineAPI
import AraratKit
import AraratUI

@MainActor
enum SidebarPerformanceCheck {
    nonisolated static let argument = "--ararat-sbperf-check"
    nonisolated static let fixtureOption = "--ararat-sbperf-fixture="
    static let restoreArgument = "--ararat-sbperf-restore"

    nonisolated static func validArguments(_ arguments: [String]) -> Bool {
        let options = PasswordsStoreCheck.guardOptions(arguments)
        let roots = [NSTemporaryDirectory(), "/tmp"].map {
            URL(fileURLWithPath: $0, isDirectory: true).resolvingSymlinksInPath().path + "/"
        }
        let otherModes = ["--ararat-check", "--ararat-screen", "--ararat-measure"]
        guard !options.contains("--"), options.contains("--use-mock-keychain"),
              !otherModes.contains(where: { mode in options.contains { $0 == mode || $0.hasPrefix(mode + "=") } }) else {
            return false
        }
        return ["--user-data-dir=", "--ararat-db=", fixtureOption].allSatisfy { prefix in
            let matches = options.filter { $0 == String(prefix.dropLast()) || $0.hasPrefix(prefix) }
            guard matches.count == 1, matches[0].hasPrefix(prefix), arguments.contains(matches[0]) else { return false }
            let path = String(matches[0].dropFirst(prefix.count))
            guard path.hasPrefix("/") else { return false }
            let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            return roots.contains { canonical.hasPrefix($0) }
        }
    }

    private struct Timeout: Error, CustomStringConvertible {
        let description: String
    }

    private static func wait(_ description: String, until ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !ready() {
            guard ContinuousClock.now < deadline else { throw Timeout(description: description) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func nextTurn() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            RunLoop.main.perform(inModes: [.common, .modalPanel]) { done.resume() }
        }
    }

    static func run(_ runtime: Runtime, host: any ARWindowHostAPI, arguments: [String]) async {
        runtime.browserCheckMode = "sidebar-performance"
        var conditions: [String: Bool] = [:]
        var values: [String: Any] = [:]
        defer {
            let failed = conditions.filter { !$0.value }.keys.sorted()
            runtime.finishBrowserCheck(ok: failed.isEmpty,
                values: values.merging(["conditions": conditions, "failed_conditions": failed]) { _, new in new })
        }
        func tabs() -> [any ARTabAPI] { host.tabs() as? [any ARTabAPI] ?? [] }
        func liveIDs() -> Set<String> { Set(tabs().compactMap(\.itemId)) }
        func settled(_ item: String) -> Bool {
            runtime.snapshot.selectedId == item && host.activeItemId() == item &&
                tabs().contains { $0.itemId == item && $0.title == "Loaded \(item)" && !$0.isLoading }
        }
        func importedTabs() -> [Row] {
            let spaces = runtime.snapshot.spaces.filter { $0.title.hasPrefix("SBPerf ") }
            let rows: [Row] = spaces.flatMap { $0.pinned + $0.today + $0.favorites }
            return rows.filter { $0.kind == .tab }
        }
        guard let sidebar = runtime.sidebar, let adapter = runtime.adapter,
              let fixture = arguments.first(where: { $0.hasPrefix(fixtureOption) }) else {
            conditions["fixture"] = false
            return
        }
        let expected = (0..<24).map { "tab-\($0)-0" }
        let restore = arguments.contains(restoreArgument)
        do {
            if restore {
                try await wait("restored selection") { settled(expected[23]) }
                conditions["restored_selection_only"] = liveIDs() == [expected[23]] && tabs().count == 1
                conditions["restored_lifecycle"] = importedTabs().filter(\.unloaded).count == 228
                values["restored_ids"] = liveIDs().sorted()
                return
            }
            let directory = URL(fileURLWithPath: String(fixture.dropFirst(fixtureOption.count)), isDirectory: true)
            guard let model = runtime.arcImportModel(directory: directory) else {
                conditions["fixture"] = false
                return
            }
            for _ in 0..<4 { model.advance() }
            try await wait("Arc import completed") {
                if case .error = model.stage { return true }
                return model.stage == .done
            }
            guard model.stage == .done else { throw Timeout(description: String(describing: model.stage)) }
            try await wait("imported tabs published") { importedTabs().count == 229 }
            let unloaded = importedTabs().filter(\.unloaded).count
            values["unloaded_after_import"] = unloaded
            conditions["import_writes_unloaded"] = unloaded == 229
            conditions["import_opens_no_tabs"] = tabs().isEmpty

            sidebar.workCountsForCheck = .init()
            var reloads: [Int] = []
            var sweeps: [Int] = []
            var rowOrderChanges: [Int] = []
            for pass in 0..<2 {
                for (index, item) in expected.enumerated() {
                    guard let position = runtime.snapshot.spaces.firstIndex(where: { $0.id == "space-\(index)" }),
                          let before = sidebar.workCountsForCheck else { throw Timeout(description: "space \(index) missing") }
                    sidebar.showSpace(at: position)
                    try await wait("pass \(pass + 1), selected \(item)") { settled(item) }
                    await nextTurn()
                    guard let after = sidebar.workCountsForCheck else { throw Timeout(description: "missing work counters") }
                    reloads.append(after.reloads - before.reloads)
                    sweeps.append(after.statusSweeps - before.statusSweeps)
                    rowOrderChanges.append(after.rowOrderChanges - before.rowOrderChanges)
                    let ids = pass == 0 ? Set(expected.prefix(index + 1)) : Set(expected)
                    let previous = conditions["only_committed_tabs_open"] ?? true
                    conditions["only_committed_tabs_open"] = previous && liveIDs() == ids && tabs().count == ids.count
                }
            }
            values["reloads_per_switch"] = reloads
            values["status_sweeps_per_switch"] = sweeps
            values["row_order_changes_per_switch"] = rowOrderChanges
            values["after_revisit_ids"] = liveIDs().sorted()
            conditions["at_most_one_composition_per_switch"] = reloads.count == 48 && reloads.allSatisfy { $0 <= 1 }
            conditions["at_most_one_row_order_change_per_switch"] = rowOrderChanges.count == 48 && rowOrderChanges.allSatisfy { $0 <= 1 }
            conditions["no_full_status_sweeps"] = sweeps.count == 48 && sweeps.allSatisfy { $0 == 0 }

            let before = sidebar.workCountsForCheck
            runtime.updateSidebar(runtime.snapshot)
            runtime.updateSidebar(runtime.snapshot)
            await nextTurn()
            conditions["duplicate_snapshots_do_no_work"] = sidebar.workCountsForCheck == before

            guard let middle = runtime.snapshot.spaces.firstIndex(where: { $0.id == "space-12" }) else {
                throw Timeout(description: "middle space missing")
            }
            sidebar.showSpace(at: middle)
            try await wait("middle space selected") { settled(expected[12]) }
            let time = ProcessInfo.processInfo.systemUptime
            var followed = false
            for (dx, phase, delay): (Int32, CGScrollPhase, Double) in [(-20, .began, 0), (0, .ended, 0.12)] {
                let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                    wheel1: 0, wheel2: -dx, wheel3: 0)
                event?.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
                event?.timestamp = UInt64((time + delay) * 1_000_000_000)
                guard let event, let scroll = NSEvent(cgEvent: event) else { throw Timeout(description: "wheel event") }
                sidebar.scrollWheel(with: scroll)
                if phase == .began { followed = !sidebar.canPublishAutoArchive }
            }
            try await wait("wheel presentation settled") { sidebar.canPublishAutoArchive }
            conditions["uncommitted_scroll_opens_no_tabs"] = followed && liveIDs() == Set(expected) &&
                runtime.snapshot.shownSpaceId == "space-12"

            guard let first = runtime.snapshot.spaces.firstIndex(where: { $0.id == "space-0" }),
                  let last = runtime.snapshot.spaces.firstIndex(where: { $0.id == "space-23" }) else {
                throw Timeout(description: "fixture spaces missing")
            }
            sidebar.showSpace(at: first)
            try await wait("space 0 returned") { settled(expected[0]) }
            guard sidebar.selectRow(id: "split-0") else { throw Timeout(description: "split fixture missing") }
            let splitIDs: Set<String> = ["tab-0-1", "tab-0-2"]
            try await wait("split members opened") { splitIDs.isSubset(of: liveIDs()) }
            conditions["split_opens_its_two_members"] = liveIDs() == Set(expected).union(splitIDs) && tabs().count == 26
            sidebar.showSpace(at: last)
            try await wait("restore target selected") { settled(expected[23]) }
            try adapter.session.queue.sync { try adapter.session.store?.flush() }
        } catch {
            conditions["check_completed"] = false
            values["error"] = String(describing: error)
            values["live_ids_at_failure"] = liveIDs().sorted()
        }
    }
}
