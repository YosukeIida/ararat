import AppKit
import AraratEngineAPI
import AraratKit
import AraratUI

@MainActor
final class TabSwitcherScreenCheck {
    private static let names = [
        "visible_vs_detach", "two_real_previews", "top_aligned_crop", "capture",
        "quick_tap", "held_once_without_fade", "release_immediate", "escape_immediate",
        "five_previews_after_space_return", "saved_favicon", "navigation_refresh", "blank_page_globe", "slow_page_favicon",
        "aborted_navigation", "split_focus_no_readback", "split_leave_both_readbacks",
        "little_window_handoff", "private_previews", "private_unpainted_globe", "private_memory_only",
        "private_close_releases", "close_during_readback",
    ]
    private struct CheckFailure: Error, CustomStringConvertible {
        let condition: String
        var observed: [String: Any] = [:]
        var description: String { condition }
    }
    enum CloseReadbackOrder: Equatable {
        static let maxAttempts = 3
        case exercised, retry, unverified

        init(attempt: Int, statusAtClose: String?) {
            switch statusAtClose {
            case "failed", "completed": self = attempt < Self.maxAttempts ? .retry : .unverified
            default: self = .exercised
            }
        }
    }
    private var conditions: [String: Bool] = [:]
    private var failures: [String: String] = [:]
    private var skipped: [String: String] = [:]
    private var details: [String: [String: Any]] = [:]
    private var events: [[String: Any]] = []
    private var presentations: [(visible: Bool, elapsed: TimeInterval, timestamp: TimeInterval, noAnimation: Bool)] = []
    private var images: [String: String] = [:]
    private var unverified = ["drm_hover_card_parity"]
    private var waiting = "fixture"
    private var closeOnReadback: (() -> Void)?
    private var closeLive: String?
    private var scenarioItems: [String] = []

    func result() -> [String: Any] {
        [
            "check": "tab-switcher", "screen": "tab-switcher",
            "conditions": Dictionary(uniqueKeysWithValues: Self.names.map { ($0, conditions[$0] == true) }),
            "failed_conditions": (["fixture"] + Self.names).filter { failures[$0] != nil },
            "condition_failures": failures, "skipped_conditions": skipped,
            "pending_conditions": Self.names.filter { conditions[$0] == nil && skipped[$0] == nil },
            "wait": waiting,
            "details": details, "images": images, "readbacks": events, "unverified": unverified,
        ]
    }

    func presentationChanged(visible: Bool, elapsed: TimeInterval, noAnimation: Bool) {
        presentations.append((visible, elapsed, ProcessInfo.processInfo.systemUptime, noAnimation))
        trace("panel visible=\(visible) elapsed_ms=\(elapsed * 1000) no_fade=\(noAnimation)")
    }

    func trace(_ message: String) {
        FileHandle.standardError.write(Data("ararat-trace: screen-tab-switcher \(message)\n".utf8))
    }

    private func observe(_ runtime: Runtime) {
        runtime.adapter?.onSwitcherThumbnailTrace = { [weak self] event in
            guard let self else { return }
            self.events.append(event)
            if event["live"] as? String == self.closeLive,
               event["source"] as? String == "prehide", event["status"] as? String == "requested",
               let close = self.closeOnReadback {
                self.closeOnReadback = nil
                close()
            }
        }
    }

    private func fail(_ name: String, _ error: Error, context: @autoclosure () -> [String: Any]) {
        if details[name] == nil {
            var observed = context()
            observed["step"] = waiting
            observed["error"] = String(describing: error)
            observed["at_failure"] = (error as? CheckFailure)?.observed ?? [:]
            record(name, observed)
        }
        conditions[name] = false
        failures[name] = String(describing: error)
        trace("condition=\(name) ok=false reason=\(error)")
    }

    private func record(_ name: String, _ values: [String: Any]) {
        details[name] = values
        if let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) {
            trace("details=\(name) \(String(decoding: data, as: UTF8.self))")
        }
    }

    private func checkNamed(_ name: String, assertions: [String: Bool], observed: [String: Any]) throws {
        waiting = name
        record(name, observed.merging(["assertions": assertions]) { _, assertions in assertions })
        let failed = assertions.keys.filter { assertions[$0] != true }.sorted()
        guard failed.isEmpty else { throw CheckFailure(condition: "failed assertions: \(failed.joined(separator: ", "))") }
        conditions[name] = true
        trace("condition=\(name) ok=true")
    }

    private func skip(_ name: String, because prerequisite: String) {
        let reason = "skipped because \(prerequisite) failed"
        skipped[name] = reason
        trace("condition=\(name) \(reason)")
    }

    private func attempt(_ name: String, onFailure: (@MainActor () -> [String: Any])? = nil,
                         _ body: () async throws -> Void) async {
        waiting = name
        do { try await body() }
        catch {
            fail(name, error, context: onFailure?() ?? [:])
        }
    }

    private func scenario(_ names: [String], runtime: Runtime, space: String,
                          _ body: () async throws -> Void) async {
        let label = names[0]
        waiting = label
        trace("scenario=\(label)")
        let mark = events.count
        scenarioItems.removeAll()
        do {
            try await showSpace(runtime, space)
            try await body()
        } catch {
            let pending = names.filter { conditions[$0] == nil && skipped[$0] == nil }
            if let first = pending.first {
                fail(first, error, context: runtimeDetails(runtime).merging([
                    "fixture_items": scenarioItems, "expected_space": space, "readbacks": Array(events.dropFirst(mark)),
                ]) { _, value in value })
                for name in pending.dropFirst() { skip(name, because: first) }
            }
        }
        runtime.tabSwitcher?.cancel()
        for item in scenarioItems {
            runtime.adapter?.close(id: item, archive: false, animate: false)
        }
        do {
            try await wait("cleanup \(label)") {
                self.scenarioItems.allSatisfy { self.tab(runtime, $0) == nil }
            }
        } catch {
            record("\(label)_cleanup", ["remaining_items": scenarioItems.filter { tab(runtime, $0) != nil },
                                        "error": String(describing: error)])
        }
    }

    private func showSpace(_ runtime: Runtime, _ space: String) async throws {
        if runtime.snapshot.shownSpaceId != space {
            runtime.switchWorkspaceSpace(space)
            try await wait("select space \(space)") { runtime.snapshot.shownSpaceId == space }
        }
    }

    private func wait(_ name: String, timeout: TimeInterval = 8, observed: () -> [String: Any] = { [:] },
                      until ready: () -> Bool) async throws {
        waiting = name
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !ready() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw CheckFailure(condition: "timed out waiting for \(name)", observed: observed())
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func presentationDetails() -> [[String: Any]] {
        presentations.map { ["visible": $0.visible, "elapsed_ms": 1000 * $0.elapsed,
                             "timestamp": $0.timestamp, "no_fade": $0.noAnimation] }
    }

    private func runtimeDetails(_ runtime: Runtime) -> [String: Any] {
        ["fixture_port": runtime.promptFixturePort as Any? ?? NSNull(),
         "space": runtime.snapshot.shownSpaceId as Any? ?? NSNull(),
         "has_host": runtime.host != nil, "has_workspace": runtime.workspace != nil, "has_adapter": runtime.adapter != nil,
         "window_key": runtime.host?.window().isKeyWindow == true,
         "active_item": runtime.host?.activeItemId() as Any? ?? NSNull(),
         "panel_open": runtime.tabSwitcher?.isOpen == true,
         "panel_visible": runtime.tabSwitcher?.visibleWindow != nil,
         "presentations": presentationDetails(),
         "tabs": ((runtime.host?.tabs() as? [any ARTabAPI]) ?? []).map { tab in
            ["item": tab.itemId as Any? ?? NSNull(), "live": tab.liveId, "url": tab.url,
             "loading": tab.isLoading, "has_favicon": tab.favicon != nil, "navigation_count": tab.navigationCount,
             "source": tab.itemId.flatMap { runtime.adapter?.switcherThumbnailSource(item: $0, live: tab.liveId) } as Any? ?? NSNull()]
         }]
    }

    private func tab(_ runtime: Runtime, _ id: String) -> (any ARTabAPI)? {
        (runtime.host?.tabs() as? [any ARTabAPI])?.first { $0.itemId == id }
    }

    private func picture(_ runtime: Runtime, _ item: String) -> NSImage? {
        guard let tab = tab(runtime, item) else { return nil }
        return runtime.adapter?.switcherThumbnail(item: item, live: tab.liveId)
    }

    private func hasEvent(mark: Int = 0, live: String, source: String, status: String,
                          reasons: Set<String>? = nil) -> Bool {
        events.dropFirst(mark).contains { event in
            event["live"] as? String == live && event["source"] as? String == source && event["status"] as? String == status &&
                (reasons.map { $0.contains(event["reason"] as? String ?? "") } ?? true) &&
                (event["elapsed_ms"] as? Double).map { $0 >= 0 } == true && event["viz_error"] is Int
        }
    }

    private func readbacks(for lives: [String], since mark: Int = 0) -> [[String: Any]] {
        events.dropFirst(mark).filter { ($0["live"] as? String).map { lives.contains($0) } == true }
    }

    private func open(_ runtime: Runtime, url: String) async throws -> String {
        guard let workspace = runtime.workspace else { throw CheckFailure(condition: "workspace") }
        let change: WorkspaceAdapter.Change = try await withCheckedThrowingContinuation { continuation in
            workspace.createTab(url: url) { continuation.resume(with: $0) }
        }
        guard let id = change.id else { throw CheckFailure(condition: "create_tab") }
        if !runtime.isPrivateWindow { scenarioItems.append(id) }
        runtime.showAndSelect(.success(change.snapshot), selectedItem: id)
        try await wait("select \(url)", observed: { runtime.checkSelectionDiagnostics(item: id) }) {
            runtime.host?.activeItemId() == id && self.tab(runtime, id) != nil
        }
        return id
    }

    private func select(_ runtime: Runtime, _ id: String) async throws {
        guard let workspace = runtime.workspace else { throw CheckFailure(condition: "workspace") }
        let snapshot: WorkspaceSnapshot = try await withCheckedThrowingContinuation { continuation in
            workspace.select(id: id) { continuation.resume(with: $0) }
        }
        runtime.showAndSelect(.success(snapshot), selectedItem: id)
        try await wait("select \(id)") { runtime.host?.activeItemId() == id }
    }

    private func key(_ runtime: Runtime, _ code: UInt16, type: NSEvent.EventType = .keyDown,
                     flags: NSEvent.ModifierFlags = [], chars: String = "") throws {
        guard let window = runtime.host?.window(), window.isKeyWindow,
              let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)
        else { throw CheckFailure(condition: "key_window") }
        trace("key-post type=\(type.rawValue) key=\(code) control=\(flags.contains(.control)) window=\(window.windowNumber)")
        NSApp.postEvent(event, atStart: false)
    }

    private func hold(_ runtime: Runtime) async throws -> TabSwitcher {
        presentations.removeAll()
        try key(runtime, 48, flags: .control, chars: "\t")
        try await wait("switcher visible", timeout: 2) { runtime.tabSwitcher?.visibleWindow != nil }
        guard let switcher = runtime.tabSwitcher else { throw CheckFailure(condition: "switcher visible") }
        return switcher
    }

    private func escape(_ runtime: Runtime) async throws {
        try key(runtime, 53, chars: "\u{1b}")
        try await wait("escape closed panel") { runtime.tabSwitcher == nil }
    }

    private func bitmap(_ image: NSImage?) -> NSBitmapImageRep? {
        var bounds = NSRect(origin: .zero, size: image?.size ?? .zero)
        guard let cg = image?.cgImage(forProposedRect: &bounds, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cg)
    }

    private func color(_ image: NSImage?, _ name: String, at height: Double = 0.16) -> Bool {
        guard let bitmap = bitmap(image), bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else { return false }
        return color(bitmap, name, row: Int(Double(bitmap.pixelsHigh - 1) * height))
    }

    private func color(_ bitmap: NSBitmapImageRep, _ name: String, row: Int) -> Bool {
        guard let pixel = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: row)?.usingColorSpace(.sRGB)
        else { return false }
        let (r, g, b) = (pixel.redComponent, pixel.greenComponent, pixel.blueComponent)
        switch name {
        case "red": return r > 0.6 && g < 0.35 && b < 0.35
        case "blue": return b > 0.6 && r < 0.35 && g < 0.5
        case "green": return g > 0.45 && r < 0.35 && b < 0.4
        case "yellow": return r > 0.7 && g > 0.55 && b < 0.4
        default: return false
        }
    }

    private func real(_ panel: TabSwitcher, _ item: String, _ name: String) -> Bool {
        guard let tile = panel.previewForCheck(item: item), tile.fillsPreview,
              let rep = bitmap(tile.image), rep.pixelsWide == 312, rep.pixelsHigh == 208 else { return false }
        return color(tile.image, name)
    }

    private func previewDetails(_ tile: (image: NSImage?, fillsPreview: Bool, size: NSSize)?,
                                expected: String? = nil) -> [String: Any] {
        let pixels = bitmap(tile?.image)
        let matches = expected.map { color(tile?.image, $0, at: $0 == "yellow" ? 0.5 : 0.16) }
        return ["present": tile != nil, "fills_preview": tile?.fillsPreview as Any? ?? NSNull(),
                "width_pt": tile?.size.width as Any? ?? NSNull(), "height_pt": tile?.size.height as Any? ?? NSNull(),
                "has_image": tile?.image != nil,
                "width_px": pixels?.pixelsWide as Any? ?? NSNull(), "height_px": pixels?.pixelsHigh as Any? ?? NSNull(),
                "expected_color": expected as Any? ?? NSNull(), "matches_expected_color": matches as Any? ?? NSNull()]
    }

    private func coloredPreviews(_ panel: TabSwitcher, items: [(String, String)]) -> [[String: Any]] {
        items.map { item, expected in
            ["item": item, "tile": previewDetails(panel.previewForCheck(item: item), expected: expected)]
        }
    }

    private func awaitPicture(_ runtime: Runtime, _ item: String, _ name: String) async throws {
        try await wait("painted \(name) thumbnail for \(item)", observed: {
            let pixels = self.bitmap(self.picture(runtime, item))
            return ["item": item, "expected_color": name,
                    "width_px": pixels?.pixelsWide as Any? ?? NSNull(), "height_px": pixels?.pixelsHigh as Any? ?? NSNull()]
        }) { self.color(self.picture(runtime, item), name) }
    }

    private func diskPreviewFiles() throws -> Set<String> {
        guard let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--user-data-dir=") }),
              let entries = FileManager.default.enumerator(atPath: String(arg.dropFirst("--user-data-dir=".count)))
        else { throw CheckFailure(condition: "private_profile_directory") }
        return Set(entries.compactMap { $0 as? String }.filter {
            let path = $0.lowercased()
            return path.contains("thumbnail") || path.hasSuffix(".jpg") || path.hasSuffix(".png")
        })
    }

    func run(_ runtime: Runtime, host: any ARWindowHostAPI) async {
        observe(runtime)
        do {
            try await exercise(runtime, host: host)
        } catch {
            fail("fixture", error, context: runtimeDetails(runtime))
            for name in Self.names where conditions[name] == nil && skipped[name] == nil {
                skip(name, because: "fixture")
            }
        }
        runtime.finishBrowserCheck(ok: Self.names.allSatisfy { conditions[$0] == true }, values: result())
    }

    private func exercise(_ runtime: Runtime, host: any ARWindowHostAPI) async throws {
        try await wait("fixture and key window") {
            runtime.promptFixturePort != nil && host.window().isKeyWindow && runtime.snapshot.shownSpaceId != nil
        }
        guard let port = runtime.promptFixturePort, let originalSpace = runtime.snapshot.shownSpaceId,
              let workspace = runtime.workspace, let adapter = runtime.adapter else { throw CheckFailure(condition: "fixture") }
        func url(_ name: String) -> String { "http://127.0.0.1:\(port)/switcher/\(name)" }
        func scene(_ names: String..., body: () async throws -> Void) async {
            await scenario(names, runtime: runtime, space: originalSpace, body)
        }
        func openPair() async throws -> (previous: String, current: String) {
            let previous = try await open(runtime, url: url("blue"))
            return (previous, try await open(runtime, url: url("green")))
        }
        func assertHeld() throws {
            let first = presentations.first
            try checkNamed("held_once_without_fade", assertions: [
                "one_show": presentations.count == 1 && first?.visible == true,
                "reveal_in_window": first.map { $0.elapsed >= 0.145 && $0.elapsed < 0.3 } == true,
                "no_fade": first?.noAnimation == true,
            ], observed: ["presentations": presentationDetails(), "minimum_ms": 145, "maximum_ms_exclusive": 300])
        }
        func assertClosed(_ name: String, sent: TimeInterval, selection: String) throws {
            let elapsed = presentations.last.map { $0.timestamp - sent }
            try checkNamed(name, assertions: [
                "show_then_hide": presentations.map(\.visible) == [true, false],
                "no_fade": presentations.last?.noAnimation == true, "selection_matches": host.activeItemId() == selection,
                "close_within_limit": elapsed.map { $0 < 0.25 } == true,
            ], observed: ["presentations": presentationDetails(), "expected_selection": selection,
                          "actual_selection": host.activeItemId() as Any? ?? NSNull(),
                          "close_elapsed_ms": elapsed.map { 1000 * $0 } as Any? ?? NSNull(), "close_limit_ms": 250])
        }

        await scene("visible_vs_detach") {
            let red = try await open(runtime, url: url("red"))
            try await awaitPicture(runtime, red, "red")
            guard let live = tab(runtime, red)?.liveId else { throw CheckFailure(condition: "red tab missing") }
            _ = try await open(runtime, url: url("blue"))
            try await wait("prehide readback reports result") {
                self.hasEvent(live: live, source: "prehide", status: "completed") ||
                self.hasEvent(live: live, source: "prehide", status: "failed", reasons: ["timeout", "empty", "error"])
            }
            try checkNamed("visible_vs_detach", assertions: [
                "reserve_requested": hasEvent(live: live, source: "reserve", status: "requested"),
                "reserve_completed": hasEvent(live: live, source: "reserve", status: "completed"),
                "prehide_requested": hasEvent(live: live, source: "prehide", status: "requested"),
            ], observed: ["item": red, "live": live, "readbacks": readbacks(for: [live])])
        }

        await scene("quick_tap") {
            let pair = try await openPair()
            presentations.removeAll()
            try key(runtime, 48, flags: .control, chars: "\t")
            try key(runtime, 59, type: .flagsChanged)
            try await wait("quick tap selected previous", observed: { ["expected_selection": pair.previous] }) {
                host.activeItemId() == pair.previous && runtime.tabSwitcher == nil
            }
            try await Task.sleep(for: .milliseconds(170))
            try checkNamed("quick_tap", assertions: ["no_panel": presentations.isEmpty],
                           observed: ["presentations": presentationDetails(), "expected_selection": pair.previous,
                                      "active_item": host.activeItemId() as Any? ?? NSNull()])
        }
        await scene("held_once_without_fade") {
            _ = try await openPair()
            _ = try await hold(runtime)
            try await Task.sleep(for: .milliseconds(170))
            try assertHeld()
        }
        await scene("release_immediate") {
            let pair = try await openPair()
            _ = try await hold(runtime)
            let sent = ProcessInfo.processInfo.systemUptime
            try key(runtime, 59, type: .flagsChanged)
            try await wait("hold released", observed: { ["expected_selection": pair.previous, "release_timestamp": sent] }) {
                runtime.tabSwitcher == nil && host.activeItemId() == pair.previous
            }
            try assertClosed("release_immediate", sent: sent, selection: pair.previous)
        }
        await scene("escape_immediate") {
            let pair = try await openPair()
            _ = try await hold(runtime)
            let sent = ProcessInfo.processInfo.systemUptime
            try await escape(runtime)
            try assertClosed("escape_immediate", sent: sent, selection: pair.current)
        }

        await scene("two_real_previews", "capture") {
            let red = try await open(runtime, url: url("red"))
            try await awaitPicture(runtime, red, "red")
            let blue = try await open(runtime, url: url("blue"))
            try await awaitPicture(runtime, blue, "blue")
            _ = try await open(runtime, url: url("green"))
            let panel = try await hold(runtime)
            await attempt("two_real_previews") {
                try checkNamed("two_real_previews", assertions: [
                    "red_is_real": real(panel, red, "red"), "blue_is_real": real(panel, blue, "blue"),
                ], observed: ["red": previewDetails(panel.previewForCheck(item: red), expected: "red"),
                              "blue": previewDetails(panel.previewForCheck(item: blue), expected: "blue"),
                              "red_item": red, "blue_item": blue])
            }
            guard conditions["two_real_previews"] == true else {
                skip("capture", because: "two_real_previews")
                return
            }
            await attempt("capture") {
                if let overlay = panel.visibleWindow,
                   let file = runtime.promptScreenScreenshot(host.window(), name: "tab-switcher-two-previews", overlay: overlay) {
                    images["tab-switcher"] = file
                }
                try checkNamed("capture", assertions: ["screenshot_saved": images["tab-switcher"] != nil],
                               observed: ["image": images["tab-switcher"] as Any? ?? NSNull(),
                                          "panel_visible": panel.visibleWindow != nil,
                                          "host_window": host.window().windowNumber,
                                          "host_has_screen": host.window().screen != nil])
            }
        }

        await scene("top_aligned_crop") {
            let red = try await open(runtime, url: url("red"))
            try await awaitPicture(runtime, red, "red")
            let viewport = tab(runtime, red)?.view?.bounds.size ?? .zero
            _ = try await open(runtime, url: url("green"))
            let panel = try await hold(runtime)
            let cropHeight = floor(viewport.width / 3) * 2
            let tolerance = 0.03
            let tile = panel.previewForCheck(item: red)
            let distinguishesCrops = cropHeight > 0 && viewport.height - cropHeight > 2 * tolerance * cropHeight
            let expectedEdge = cropHeight > 0 ? 0.44 * viewport.height / cropHeight : nil
            let measuredEdge = bitmap(tile?.image).flatMap { redPreview in
                (0..<redPreview.pixelsHigh).first { !color(redPreview, "red", row: $0) }.map {
                    Double($0) / Double(redPreview.pixelsHigh)
                }
            }
            let edgeWithinTolerance = measuredEdge.flatMap { measured in expectedEdge.map { abs(measured - $0) <= tolerance } }
            try checkNamed("top_aligned_crop", assertions: [
                "distinguishable_crop": distinguishesCrops, "red_edge_found": measuredEdge != nil,
                "edge_within_tolerance": edgeWithinTolerance == true,
            ], observed: ["item": red, "tile": previewDetails(tile), "viewport_width": viewport.width,
                          "viewport_height": viewport.height, "crop_height": cropHeight, "tolerance": tolerance,
                          "expected_edge": expectedEdge as Any? ?? NSNull(), "measured_edge": measuredEdge as Any? ?? NSNull()])
        }

        await scene("five_previews_after_space_return") {
            var eligible: [(String, String)] = []
            for name in ["red", "blue", "green", "red", "blue", "green"] {
                let item = try await open(runtime, url: url(name) + "?space")
                try await awaitPicture(runtime, item, name)
                eligible.append((item, name))
            }
            let beforeSpace = try await hold(runtime)
            let alternatives = eligible.dropLast()
            try await wait("five real previews before leaving space", observed: {
                ["before": self.coloredPreviews(beforeSpace, items: Array(alternatives))]
            }) {
                alternatives.allSatisfy { self.real(beforeSpace, $0.0, $0.1) }
            }
            let before = coloredPreviews(beforeSpace, items: Array(alternatives))
            try await escape(runtime)
            let newSpace: WorkspaceSnapshot = try await withCheckedThrowingContinuation { continuation in
                workspace.createSpace(name: "Switcher other space") { continuation.resume(with: $0) }
            }
            guard let other = newSpace.spaces.first(where: { $0.title == "Switcher other space" })?.id
            else { throw CheckFailure(condition: "create space") }
            runtime.show(newSpace)
            try await showSpace(runtime, other)
            try await showSpace(runtime, originalSpace)
            try await wait("returned to original tab", observed: { ["expected_selection": eligible.last?.0 as Any? ?? NSNull()] }) {
                host.activeItemId() == eligible.last?.0
            }
            let afterSpace = try await hold(runtime)
            try checkNamed("five_previews_after_space_return", assertions: Dictionary(uniqueKeysWithValues: alternatives.map {
                ("real_\($0.0)", real(afterSpace, $0.0, $0.1))
            }), observed: ["before": before, "after": coloredPreviews(afterSpace, items: Array(alternatives)),
                           "visited_space": other, "returned_space": originalSpace])
        }

        await scene("saved_favicon") {
            let red = try await open(runtime, url: url("red") + "?favicon")
            try await wait("red page favicon saved", observed: {
                ["item": red, "has_favicon": self.tab(runtime, red)?.favicon != nil, "expected_color": "yellow"]
            }) { self.color(self.tab(runtime, red)?.favicon, "yellow", at: 0.5) }
            let initialIDs = Set(runtime.snapshot.spaces.flatMap { $0.today.map(\.id) })
            let duplicated = try adapter.session.queue.sync {
                try adapter.session.store?.duplicateItem(windowId: runtime.windowID, id: red)
            }
            guard let duplicated, let unloaded = duplicated.spaces.flatMap(\.today).first(where: {
                !initialIDs.contains($0.id) && $0.unloaded && $0.url == self.tab(runtime, red)?.url
            }) else {
                let candidates = duplicated?.spaces.flatMap(\.today).filter { !initialIDs.contains($0.id) } ?? []
                throw CheckFailure(condition: "unloaded duplicate", observed: [
                    "source_item": red, "source_url": tab(runtime, red)?.url as Any? ?? NSNull(),
                    "candidates": candidates.map { ["item": $0.id, "unloaded": $0.unloaded, "url": $0.url as Any? ?? NSNull()] },
                ])
            }
            scenarioItems.append(unloaded.id)
            runtime.show(duplicated)
            let panel = try await hold(runtime)
            try await wait("unloaded saved favicon visible", observed: {
                ["item": unloaded.id, "tile": self.previewDetails(panel.previewForCheck(item: unloaded.id), expected: "yellow"),
                 "lookup_items": runtime.switcherUnloadedFavicons.keys.sorted()]
            }) {
                let tile = panel.previewForCheck(item: unloaded.id)
                return tile?.size == NSSize(width: 22, height: 22) && self.color(tile?.image, "yellow", at: 0.5)
            }
            let tile = panel.previewForCheck(item: unloaded.id)
            try checkNamed("saved_favicon", assertions: [
                "row_unloaded": tab(runtime, unloaded.id) == nil, "tile_not_filled": tile?.fillsPreview == false,
            ], observed: ["item": unloaded.id, "live": tab(runtime, unloaded.id)?.liveId as Any? ?? NSNull(),
                          "tile": previewDetails(tile, expected: "yellow"), "lookup_items": runtime.switcherUnloadedFavicons.keys.sorted()])
        }

        await scene("navigation_refresh") {
            let red = try await open(runtime, url: url("red"))
            try await awaitPicture(runtime, red, "red")
            host.checkNavigate("http://localhost:\(port)/switcher/blue?refreshed", disposition: "current")
            try await awaitPicture(runtime, red, "blue")
            _ = try await open(runtime, url: url("green"))
            let panel = try await hold(runtime)
            try checkNamed("navigation_refresh", assertions: ["new_document_preview": real(panel, red, "blue")],
                           observed: ["item": red, "url": tab(runtime, red)?.url as Any? ?? NSNull(),
                                      "tile": previewDetails(panel.previewForCheck(item: red), expected: "blue")])
        }

        await scene("blank_page_globe") {
            let item = try await open(runtime, url: url("red"))
            try await awaitPicture(runtime, item, "red")
            guard let target = tab(runtime, item) else { throw CheckFailure(condition: "blank target tab missing") }
            try await wait("red fixture favicon in sidebar", observed: { target.checkFaviconState() }) {
                self.color(runtime.sidebar?.favicons[item], "yellow", at: 0.5)
            }
            let faviconBeforeCommit = target.checkFaviconState()
            let live = target.liveId
            let navigationCount = target.navigationCount
            let sourceBeforeCommit = adapter.switcherThumbnailSource(item: item, live: live)
            let mark = events.count
            host.checkNavigate("about:blank", disposition: "current")
            try await wait("blank URL committed and reserve skipped", observed: {
                ["item": item, "live": live, "previous_navigation_count": navigationCount,
                 "current_navigation_count": target.navigationCount, "url": target.url, "favicon": target.checkFaviconState(),
                 "readbacks": self.readbacks(for: [live], since: mark)]
            }) {
                target.navigationCount > navigationCount && target.url == "about:blank" && !target.isLoading &&
                    self.hasEvent(mark: mark, live: live, source: "reserve", status: "skipped", reasons: ["blank-url"])
            }
            let sourceAfterCommit = adapter.switcherThumbnailSource(item: item, live: live)

            _ = try await open(runtime, url: url("green"))
            let panel = try await hold(runtime)
            let tile = panel.previewForCheck(item: item)
            let globePixels = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?.tiffRepresentation
            let matchesGlobe = globePixels.map { tile?.image?.tiffRepresentation == $0 } ?? false
            let source = adapter.switcherThumbnailSource(item: item, live: live)
            let prehideSkipped = hasEvent(mark: mark, live: live, source: "prehide", status: "skipped", reasons: ["blank-url"])
            let hasLiveFavicon = target.favicon != nil
            try checkNamed("blank_page_globe", assertions: [
                "same_live_tab": tab(runtime, item)?.liveId == live,
                "picture_dropped_at_commit": sourceBeforeCommit != "favicon" && sourceAfterCommit == "favicon",
                "prehide_skipped_blank_url": prehideSkipped, "source_favicon": source == "favicon",
                "tile_not_filled": tile?.fillsPreview == false,
                "tile_size_22pt": tile?.size == NSSize(width: 22, height: 22), "tile_is_globe": matchesGlobe,
                "no_live_favicon": !hasLiveFavicon,
                "no_sidebar_favicon": runtime.sidebar?.favicons[item] == nil,
            ], observed: [
                "item": item, "live": live, "current_live": tab(runtime, item)?.liveId as Any? ?? NSNull(),
                "url": target.url, "previous_navigation_count": navigationCount, "current_navigation_count": target.navigationCount,
                "source_before_commit": sourceBeforeCommit, "source_after_commit": sourceAfterCommit, "source": source,
                "tile": previewDetails(tile), "matches_globe": matchesGlobe, "has_live_favicon": hasLiveFavicon,
                "favicon_before_commit": faviconBeforeCommit, "favicon": target.checkFaviconState(),
                "has_sidebar_favicon": runtime.sidebar?.favicons[item] != nil,
                "readbacks": readbacks(for: [live], since: mark),
            ])
        }

        await scene("slow_page_favicon") {
            let slow = try await open(runtime, url: "about:blank")
            guard let live = tab(runtime, slow)?.liveId else { throw CheckFailure(condition: "slow tab missing") }
            host.checkNavigate(url("slow"), disposition: "current")
            try await wait("slow navigation pending") { self.tab(runtime, slow)?.isLoading == true }
            _ = try await open(runtime, url: url("red"))
            let panel = try await hold(runtime)
            let tile = panel.previewForCheck(item: slow)
            try checkNamed("slow_page_favicon", assertions: [
                "tile_not_filled": tile?.fillsPreview == false, "tile_width_22pt": tile?.size.width == 22,
                "tile_has_image": tile?.image != nil, "prehide_skipped":
                    hasEvent(live: live, source: "prehide", status: "skipped", reasons: ["navigation-pending", "no-paint"]),
            ], observed: ["item": slow, "live": live, "tile": previewDetails(tile),
                          "favicon": tab(runtime, slow)?.checkFaviconState() ?? [:], "readbacks": readbacks(for: [live])])
        }

        await scene("aborted_navigation") {
            let blue = try await open(runtime, url: url("blue"))
            try await awaitPicture(runtime, blue, "blue")
            guard let before = tab(runtime, blue) else { throw CheckFailure(condition: "blue tab missing") }
            let navigationCount = before.navigationCount
            let live = before.liveId
            host.checkNavigate(url("slow") + "?cancel", disposition: "current")
            try await wait("pending navigation invalidated old preview") {
                self.tab(runtime, blue)?.isLoading == true && self.picture(runtime, blue) == nil
            }
            tab(runtime, blue)?.checkStopSwitcherNavigation()
            try await wait("pending navigation cancelled") { self.tab(runtime, blue)?.isLoading == false }
            try await awaitPicture(runtime, blue, "blue")
            let mark = events.count
            _ = try await open(runtime, url: url("green"))
            let panel = try await hold(runtime)
            try await wait("painted original document after abort", observed: {
                ["item": blue, "tile": self.previewDetails(panel.previewForCheck(item: blue), expected: "blue")]
            }) { self.real(panel, blue, "blue") }
            let actualCount = tab(runtime, blue)?.navigationCount
            try checkNamed("aborted_navigation", assertions: [
                "navigation_did_not_commit": actualCount == navigationCount,
                "prehide_requested": hasEvent(mark: mark, live: live, source: "prehide", status: "requested"),
            ], observed: ["item": blue, "live": live, "expected_navigation_count": navigationCount,
                          "actual_navigation_count": actualCount as Any? ?? NSNull(),
                          "tile": previewDetails(panel.previewForCheck(item: blue), expected: "blue"),
                          "readbacks": readbacks(for: [live], since: mark)])
        }

        func openSplit() async throws -> (blue: String, red: String) {
            let blue = try await open(runtime, url: url("blue"))
            try await awaitPicture(runtime, blue, "blue")
            let red = try await open(runtime, url: url("red"))
            try await awaitPicture(runtime, red, "red")
            let made: Bool = await withCheckedContinuation { continuation in
                adapter.makeSplit(dragged: blue, target: red, side: .right) { continuation.resume(returning: $0) }
            }
            guard made, let blueLive = tab(runtime, blue)?.liveId, let redLive = tab(runtime, red)?.liveId
            else { throw CheckFailure(condition: "make split", observed: ["made": made, "blue_item": blue, "red_item": red]) }
            try await wait("split visible", observed: { ["pane_count": adapter.checkSplitFocus().panes.count] }) {
                adapter.checkSplitFocus().panes.count == 2 && host.activeItemId() != nil
            }
            return (blueLive, redLive)
        }

        await scene("split_focus_no_readback") {
            let split = try await openSplit()
            let active = host.activeItemId()
            let mark = events.count
            adapter.focusPane(backwards: false)
            try await wait("other split pane focused", observed: {
                ["previous_active_item": active as Any? ?? NSNull(), "pane_count": adapter.checkSplitFocus().panes.count]
            }) {
                host.activeItemId() != active && adapter.checkSplitFocus().panes.count == 2
            }
            try checkNamed("split_focus_no_readback", assertions: [
                "red_not_requested": !hasEvent(mark: mark, live: split.red, source: "prehide", status: "requested"),
                "blue_not_requested": !hasEvent(mark: mark, live: split.blue, source: "prehide", status: "requested"),
            ], observed: ["red_live": split.red, "blue_live": split.blue,
                          "previous_active_item": active as Any? ?? NSNull(),
                          "active_item": host.activeItemId() as Any? ?? NSNull(),
                          "readbacks": readbacks(for: [split.red, split.blue], since: mark)])
        }
        await scene("split_leave_both_readbacks") {
            let split = try await openSplit()
            let mark = events.count
            _ = try await open(runtime, url: url("green"))
            try await wait("both split readbacks requested", observed: {
                ["red_live": split.red, "blue_live": split.blue,
                 "readbacks": self.readbacks(for: [split.red, split.blue], since: mark)]
            }) {
                self.hasEvent(mark: mark, live: split.red, source: "prehide", status: "requested") &&
                self.hasEvent(mark: mark, live: split.blue, source: "prehide", status: "requested")
            }
            let panes = adapter.checkSplitFocus().panes.count
            try checkNamed("split_leave_both_readbacks", assertions: ["left_split": panes < 2],
                           observed: ["pane_count": panes, "red_live": split.red, "blue_live": split.blue,
                                      "readbacks": readbacks(for: [split.red, split.blue], since: mark)])
        }

        await scene("little_window_handoff") {
            runtime.openLittleWindow(url: url("red") + "?handoff")
            defer { for little in runtime.littleWindows { little.window?.close() } }
            try await wait("Little Window document", observed: {
                ["windows": runtime.littleWindows.map { little in
                    ["visible": little.window?.isVisible == true,
                     "tabs": ((little.popup.host?.tabs() as? [any ARTabAPI]) ?? []).map {
                        ["live": $0.liveId, "title": $0.title, "loading": $0.isLoading]
                     }]
                }]
            }) {
                guard let popup = runtime.littleWindows.first,
                      let tab = (popup.popup.host?.tabs() as? [any ARTabAPI])?.first else { return false }
                return tab.title == "Switcher red" && !tab.isLoading && popup.window?.isVisible == true
            }
            guard let little = runtime.littleWindows.first,
                  let littleTab = (little.popup.host?.tabs() as? [any ARTabAPI])?.first
            else { throw CheckFailure(condition: "Little Window tab missing") }
            let live = littleTab.liveId
            let navigationCount = littleTab.navigationCount
            let mark = events.count
            little.performOpenIn(spaceID: originalSpace)
            var handedItem: String?
            try await wait("Little Window handed off without reload", observed: {
                ["live": live, "previous_navigation_count": navigationCount, "handed_item": handedItem as Any? ?? NSNull()]
            }) {
                let tab = (host.tabs() as? [any ARTabAPI])?.first { $0.liveId == live }
                handedItem = tab?.itemId
                return handedItem != nil && handedItem == host.activeItemId() && tab?.navigationCount == 0 &&
                    navigationCount > 0 && host.window().isKeyWindow
            }
            guard let handedItem else { throw CheckFailure(condition: "handoff item missing") }
            scenarioItems.append(handedItem)
            try await awaitPicture(runtime, handedItem, "red")
            _ = try await open(runtime, url: url("green"))
            let panel = try await hold(runtime)
            try checkNamed("little_window_handoff", assertions: [
                "preview_is_real": real(panel, handedItem, "red"),
                "prehide_requested": hasEvent(mark: mark, live: live, source: "prehide", status: "requested"),
                "readback_completed": hasEvent(mark: mark, live: live, source: "prehide", status: "completed") ||
                    hasEvent(mark: mark, live: live, source: "reserve", status: "completed"),
            ], observed: ["item": handedItem, "live": live, "previous_navigation_count": navigationCount,
                          "current_navigation_count": tab(runtime, handedItem)?.navigationCount as Any? ?? NSNull(),
                          "tile": previewDetails(panel.previewForCheck(item: handedItem), expected: "red"),
                          "readbacks": readbacks(for: [live], since: mark)])
        }

        await scene("close_during_readback") {
            let name = "close_during_readback"
            var attempts: [[String: Any]] = []
            for attempt in 1...CloseReadbackOrder.maxAttempts {
                let item = try await open(runtime, url: url("red") + "?close=\(attempt)")
                try await awaitPicture(runtime, item, "red")
                guard let live = tab(runtime, item)?.liveId else { throw CheckFailure(condition: "closing tab missing") }
                let mark = events.count
                @MainActor func terminalReadback() -> [String: Any]? {
                    readbacks(for: [live], since: mark).first { event in
                        let status = event["status"] as? String
                        return event["source"] as? String == "prehide" && (status == "failed" || status == "completed")
                    }
                }
                var terminalBeforeClose: [String: Any]?
                var crashedAtClose: Bool?
                closeLive = live
                defer { closeLive = nil; closeOnReadback = nil }
                closeOnReadback = {
                    DispatchQueue.main.async {
                        guard let retiring = self.tab(runtime, item) else { return }
                        terminalBeforeClose = terminalReadback()
                        crashedAtClose = retiring.crashed
                        let status = terminalBeforeClose?["status"] as? String ?? "pending"
                        self.trace("close readback_status=\(status) live=\(live) attempt=\(attempt)")
                        retiring.close(withCommandId: "switcher-in-flight-close")
                    }
                }
                _ = try await open(runtime, url: url("green"))
                let closeDetails = {
                    ["item": item, "live": live, "tab_present": self.tab(runtime, item) != nil,
                     "readbacks": self.readbacks(for: [live], since: mark)] as [String: Any]
                }
                try await wait("tab closed after prehide request", observed: closeDetails) {
                    crashedAtClose != nil && self.tab(runtime, item) == nil
                }
                let statusAtClose = terminalBeforeClose?["status"] as? String
                let order = CloseReadbackOrder(attempt: attempt, statusAtClose: statusAtClose)
                try await wait("closed tab readback resolved", observed: closeDetails) { terminalReadback() != nil }
                var assertions = [
                    "closed": tab(runtime, item) == nil,
                    "no_crash": crashedAtClose == false,
                    "no_image": adapter.switcherThumbnail(item: item, live: live) == nil,
                    "prehide_requested": hasEvent(mark: mark, live: live, source: "prehide", status: "requested"),
                ]
                if statusAtClose != "completed" {
                    assertions["prehide_did_not_complete"] = !hasEvent(mark: mark, live: live, source: "prehide", status: "completed")
                }
                if order == .exercised {
                    assertions["stale_document"] = hasEvent(mark: mark, live: live, source: "prehide",
                                                            status: "failed", reasons: ["stale-document"])
                }
                var observation = closeDetails()
                observation["attempt"] = attempt
                observation["order_exercised"] = order == .exercised
                observation["status_at_close"] = statusAtClose ?? "pending"
                if let terminal = terminalBeforeClose {
                    observation["viz_error"] = terminal["viz_error"]
                    observation["elapsed_ms"] = terminal["elapsed_ms"]
                    assertions["readback_diagnostics"] = terminal["viz_error"] is Int && terminal["elapsed_ms"] is Double
                }
                observation["assertions"] = assertions
                attempts.append(observation)
                if order == .retry && assertions.values.allSatisfy({ $0 }) { continue }

                observation["attempts"] = attempts
                try checkNamed(name, assertions: assertions, observed: observation)
                if order == .unverified { unverified.append(name) }
                break
            }
        }

        await scene("private_previews", "private_unpainted_globe", "private_memory_only", "private_close_releases") {
            let diskBefore = Result { try diskPreviewFiles() }
            let privateToken = UUID().uuidString
            host.checkCreateIncognito()
            defer {
                for child in runtime.children where child.isPrivateWindow {
                    child.tabSwitcher?.cancel()
                    child.host?.close()
                }
            }
            do {
                defer {
                    record("private_window_foreground", [
                        "windows": runtime.children.filter(\.isPrivateWindow).map {
                            ["has_host": $0.host != nil, "key": $0.host?.window().isKeyWindow == true]
                        },
                    ])
                }
                try await wait("private window foreground") {
                    runtime.children.contains { $0.isPrivateWindow && $0.host?.window().isKeyWindow == true }
                }
            }
            guard let child = runtime.children.first(where: { $0.isPrivateWindow && $0.host?.window().isKeyWindow == true }),
                  let privateHost = child.host else { throw CheckFailure(condition: "private window missing") }
            child.tabSwitcherScreenCheck = self
            observe(child)
            @MainActor func privateContext() -> [String: Any] {
                ["key": child.host?.window().isKeyWindow == true,
                 "active_item": child.host?.activeItemId() as Any? ?? NSNull(),
                 "tabs": ((child.host?.tabs() as? [any ARTabAPI]) ?? []).map { tab in
                    ["item": tab.itemId as Any? ?? NSNull(), "live": tab.liveId, "url": tab.url,
                     "loading": tab.isLoading, "has_favicon": tab.favicon != nil,
                     "source": tab.itemId.flatMap { child.adapter?.switcherThumbnailSource(item: $0, live: tab.liveId) } as Any? ?? NSNull()]
                 }]
            }

            await attempt("private_unpainted_globe", onFailure: privateContext) {
                defer { child.tabSwitcher?.cancel() }
                try await wait("private initial NTP selected", observed: {
                    child.checkSelectionDiagnostics(item: child.snapshot.selectedId)
                }) {
                    guard privateHost.window().isKeyWindow, let item = child.snapshot.selectedId,
                          privateHost.activeItemId() == item, let initial = tab(child, item),
                          initial.url.hasPrefix("chrome://newtab/"), let adapter = child.adapter else { return false }
                    return adapter.session.queue.sync { adapter.session.store?.liveTab(item: item) } == initial.liveId
                }
                let blank = try await open(child, url: "about:blank")
                guard let target = tab(child, blank) else {
                    record("private_globe_target", ["item": blank, "tab_present": false])
                    throw CheckFailure(condition: "private globe target tab missing")
                }
                let live = target.liveId
                let mark = events.count
                privateHost.checkNavigate(url("slow") + "?" + privateToken, disposition: "current")
                do {
                    defer {
                        record("private_globe_target", [
                            "item": blank, "live": live, "url": target.url,
                            "loading": target.isLoading, "navigation_count": target.navigationCount,
                            "has_live_favicon": target.favicon != nil, "has_thumbnail": picture(child, blank) != nil,
                            "favicon": target.checkFaviconState(),
                        ])
                    }
                    try await wait("private globe target loading with no thumbnail") {
                        target.isLoading && self.picture(child, blank) == nil
                    }
                }
                _ = try await open(child, url: url("green") + "?" + privateToken)
                let panel: TabSwitcher
                do {
                    panel = try await hold(child)
                } catch {
                    record("private_globe_hold", ["item": blank, "switcher_open": child.tabSwitcher?.isOpen == true,
                           "panel_visible": child.tabSwitcher?.visibleWindow != nil, "presentation_count": presentations.count])
                    throw error
                }
                let tile = panel.previewForCheck(item: blank)
                let rows = panel.rows.compactMap { row -> String? in
                    if case .tab(let id, _) = row.target { return id }
                    return nil
                }
                let expectedGlobe = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?.tiffRepresentation
                let matchesGlobe = expectedGlobe.map { tile?.image?.tiffRepresentation == $0 } ?? false
                let liveTab = tab(child, blank)
                let source = child.adapter?.switcherThumbnailSource(item: blank, live: live)
                let prehideSkipped = hasEvent(mark: mark, live: live, source: "prehide", status: "skipped",
                                              reasons: ["navigation-pending", "no-paint"])
                let savedFavicon = child.switcherUnloadedFavicons[blank]
                try checkNamed("private_unpainted_globe", assertions: [
                    "panel_visible": panel.visibleWindow != nil, "target_in_rows": rows.contains(blank),
                    "target_is_live": liveTab?.liveId == live, "target_is_loading": liveTab?.isLoading == true,
                    "target_prehide_skipped": prehideSkipped, "no_thumbnail": source == "favicon",
                    "tile_present": tile != nil, "tile_not_filled": tile?.fillsPreview == false,
                    "tile_size_22pt": tile?.size == NSSize(width: 22, height: 22), "tile_has_image": tile?.image != nil,
                    "tile_is_globe": matchesGlobe, "no_live_favicon": liveTab?.favicon == nil,
                    "no_sidebar_favicon": child.sidebar?.favicons[blank] == nil,
                    "no_saved_favicon": savedFavicon == nil,
                ], observed: [
                    "item": blank, "live": live, "current_live": liveTab?.liveId as Any? ?? NSNull(), "rows": rows,
                    "panel_window": panel.visibleWindow?.windowNumber as Any? ?? NSNull(),
                    "presentation_count": presentations.count, "source": source as Any? ?? NSNull(),
                    "loading": liveTab?.isLoading as Any? ?? NSNull(), "tile": previewDetails(tile),
                    "globe_reference_available": expectedGlobe != nil, "matches_globe": matchesGlobe,
                    "has_live_favicon": liveTab?.favicon != nil, "saved_favicon_items": child.switcherUnloadedFavicons.keys.sorted(),
                    "favicon": liveTab?.checkFaviconState() ?? [:], "has_sidebar_favicon": child.sidebar?.favicons[blank] != nil,
                    "readbacks": events.dropFirst(mark).filter { $0["live"] as? String == live },
                ])
            }
            await attempt("private_previews", onFailure: privateContext) {
                defer { child.tabSwitcher?.cancel() }
                let red = try await open(child, url: url("red") + "?" + privateToken)
                try await awaitPicture(child, red, "red")
                let blue = try await open(child, url: url("blue") + "?" + privateToken)
                try await awaitPicture(child, blue, "blue")
                _ = try await open(child, url: url("green") + "?" + privateToken)
                let panel = try await hold(child)
                let redIsReal = real(panel, red, "red")
                let blueIsReal = real(panel, blue, "blue")
                try checkNamed("private_previews", assertions: [
                    "panel_visible": panel.visibleWindow != nil,
                    "red_is_real": redIsReal, "blue_is_real": blueIsReal,
                ], observed: [
                    "panel_window": panel.visibleWindow?.windowNumber as Any? ?? NSNull(),
                    "red_item": red, "red_tile": previewDetails(panel.previewForCheck(item: red)),
                    "blue_item": blue, "blue_tile": previewDetails(panel.previewForCheck(item: blue)),
                    "red_pixel_matches": color(panel.previewForCheck(item: red)?.image, "red"),
                    "blue_pixel_matches": color(panel.previewForCheck(item: blue)?.image, "blue"),
                ])
            }
            let cached: Result<(item: String, live: String, adapter: EngineAdapter), Error>
            do {
                let item = try await open(child, url: url("red") + "?" + privateToken + "-retire")
                try await awaitPicture(child, item, "red")
                guard let live = tab(child, item)?.liveId, let adapter = child.adapter
                else { throw CheckFailure(condition: "private thumbnail owner missing") }
                cached = .success((item, live, adapter))
            } catch {
                cached = .failure(error)
            }
            let diskDuring = Result { try diskPreviewFiles() }
            privateHost.close()
            let closed: Result<Void, Error>
            do {
                try await wait("private session closed") { child.host == nil && PrivateWorkspaces.liveCount == 0 }
                closed = .success(())
            } catch {
                closed = .failure(error)
            }
            record("private_session_close", [
                "remaining_host": child.host != nil, "remaining_sessions": PrivateWorkspaces.liveCount,
                "cached_fixture": (try? cached.get().item) as Any? ?? NSNull(),
            ])
            await attempt("private_close_releases", onFailure: privateContext) {
                let cached = try cached.get()
                try closed.get()
                let retainsImage = cached.adapter.switcherThumbnail(item: cached.item, live: cached.live) != nil
                try checkNamed("private_close_releases", assertions: ["cache_released": !retainsImage],
                                 observed: ["item": cached.item, "live": cached.live, "retains_image": retainsImage])
            }
            await attempt("private_memory_only", onFailure: privateContext) {
                _ = try cached.get()
                try closed.get()
                let before = try diskBefore.get()
                let during = try diskDuring.get()
                let after = try diskPreviewFiles()
                let rows = runtime.captureCheckRows()
                let leaksToken = rows?.contains { $0.contains { $0.contains(privateToken) } }
                try checkNamed("private_memory_only", assertions: [
                    "files_unchanged_during": before == during, "files_unchanged_after": during == after,
                    "regular_rows_available": rows != nil, "private_token_absent": leaksToken == false,
                ], observed: [
                    "during_added": during.subtracting(before).sorted(), "during_removed": before.subtracting(during).sorted(),
                    "after_added": after.subtracting(during).sorted(), "after_removed": during.subtracting(after).sorted(),
                    "regular_row_count": rows?.count as Any? ?? NSNull(), "private_token_found": leaksToken as Any? ?? NSNull(),
                ])
            }
        }
    }
}

extension Runtime {
    func tabSwitcherScreenCheckTick(_ host: any ARWindowHostAPI) {
        guard tabSwitcherScreenCheck == nil else { return }
        let check = TabSwitcherScreenCheck()
        tabSwitcherScreenCheck = check
        Task { await check.run(self, host: host) }
    }
}
