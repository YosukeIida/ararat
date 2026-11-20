import AppKit
import AraratEngineAPI
import AraratKit
import AraratUI

@MainActor
final class TabSwitcherScreenCheck {
    private static let names = [
        "visible_vs_detach", "two_real_previews", "top_aligned_crop", "capture",
        "quick_tap", "held_once_without_fade", "release_immediate", "escape_immediate",
        "five_previews_after_space_return", "saved_favicon", "navigation_refresh", "slow_page_favicon",
        "aborted_navigation", "split_focus_no_readback", "split_leave_both_readbacks",
        "little_window_handoff", "private_previews", "private_unpainted_globe", "private_memory_only",
        "private_close_releases", "close_during_readback",
    ]
    private struct CheckFailure: Error, CustomStringConvertible {
        let condition: String
        var description: String { condition }
    }
    private var conditions: [String: Bool] = [:]
    private var failures: [String: String] = [:]
    private var skipped: [String: String] = [:]
    private var events: [[String: Any]] = []
    private var presentations: [(visible: Bool, elapsed: TimeInterval, timestamp: TimeInterval, noAnimation: Bool)] = []
    private var images: [String: String] = [:]
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
            "images": images, "readbacks": events, "unverified": ["drm_hover_card_parity"],
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

    private func check(_ name: String, _ condition: @autoclosure () -> Bool,
                       reason: @autoclosure () -> String = "assertion failed") throws {
        waiting = name
        guard condition() else { throw CheckFailure(condition: reason()) }
        conditions[name] = true
        trace("condition=\(name) ok=true")
    }

    private func fail(_ name: String, _ error: Error) {
        conditions[name] = false
        failures[name] = String(describing: error)
        trace("condition=\(name) ok=false reason=\(error)")
    }

    private func skip(_ name: String, because prerequisite: String) {
        let reason = "skipped because \(prerequisite) failed"
        skipped[name] = reason
        trace("condition=\(name) \(reason)")
    }

    private func attempt(_ name: String, _ body: () async throws -> Void) async {
        waiting = name
        do { try await body() }
        catch { fail(name, error) }
    }

    private func scenario(_ names: [String], runtime: Runtime, space: String,
                          _ body: () async throws -> Void) async {
        let label = names[0]
        waiting = label
        trace("scenario=\(label)")
        scenarioItems.removeAll()
        do {
            try await showSpace(runtime, space)
            try await body()
        } catch {
            let pending = names.filter { conditions[$0] == nil && skipped[$0] == nil }
            if let first = pending.first {
                fail(first, error)
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
        } catch { trace("scenario=\(label) cleanup_failed reason=\(error)") }
    }

    private func showSpace(_ runtime: Runtime, _ space: String) async throws {
        if runtime.snapshot.shownSpaceId != space {
            runtime.switchWorkspaceSpace(space)
            try await wait("select space \(space)") { runtime.snapshot.shownSpaceId == space }
        }
    }

    private func wait(_ name: String, timeout: TimeInterval = 8, until ready: () -> Bool) async throws {
        waiting = name
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !ready() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CheckFailure(condition: "timed out waiting for \(name)") }
            try await Task.sleep(for: .milliseconds(20))
        }
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

    private func open(_ runtime: Runtime, url: String) async throws -> String {
        guard let workspace = runtime.workspace else { throw CheckFailure(condition: "workspace") }
        let change: WorkspaceAdapter.Change = try await withCheckedThrowingContinuation { continuation in
            workspace.createTab(url: url) { continuation.resume(with: $0) }
        }
        guard let id = change.id else { throw CheckFailure(condition: "create_tab") }
        if !runtime.isPrivateWindow { scenarioItems.append(id) }
        runtime.showAndSelect(.success(change.snapshot), selectedItem: id)
        try await wait("select \(url)") { runtime.host?.activeItemId() == id && self.tab(runtime, id) != nil }
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

    private func awaitPicture(_ runtime: Runtime, _ item: String, _ name: String) async throws {
        try await wait("painted \(name) thumbnail for \(item)") { self.color(self.picture(runtime, item), name) }
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
            fail("fixture", error)
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
            try check("held_once_without_fade", presentations.count == 1 && presentations[0].visible &&
                      presentations[0].elapsed >= 0.145 && presentations[0].elapsed < 0.3 && presentations[0].noAnimation,
                      reason: "expected one visible transition at 145–300 ms without animation, got \(presentations)")
        }
        func assertClosed(_ name: String, sent: TimeInterval, selection: String) throws {
            try check(name, presentations.map(\.visible) == [true, false] &&
                      presentations.last?.noAnimation == true && host.activeItemId() == selection &&
                      (presentations.last?.timestamp ?? .infinity) - sent < 0.25,
                      reason: "expected visible then hidden within 250 ms, selected=\(host.activeItemId() ?? "none"), transitions=\(presentations)")
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
            try check("visible_vs_detach", hasEvent(live: live, source: "reserve", status: "requested") &&
                      hasEvent(live: live, source: "reserve", status: "completed") &&
                      hasEvent(live: live, source: "prehide", status: "requested"))
        }

        await scene("quick_tap") {
            let pair = try await openPair()
            presentations.removeAll()
            try key(runtime, 48, flags: .control, chars: "\t")
            try key(runtime, 59, type: .flagsChanged)
            try await wait("quick tap selected previous") { host.activeItemId() == pair.previous && runtime.tabSwitcher == nil }
            try await Task.sleep(for: .milliseconds(170))
            try check("quick_tap", presentations.isEmpty)
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
            try await wait("hold released") { runtime.tabSwitcher == nil && host.activeItemId() == pair.previous }
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
                try check("two_real_previews", real(panel, red, "red") && real(panel, blue, "blue"))
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
                try check("capture", images["tab-switcher"] != nil)
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
            guard cropHeight > 0, viewport.height - cropHeight > 2 * tolerance * cropHeight,
                  let redPreview = bitmap(panel.previewForCheck(item: red)?.image),
                  let edgeRow = (0..<redPreview.pixelsHigh).first(where: { !color(redPreview, "red", row: $0) })
            else { throw CheckFailure(condition: "red edge missing or viewport cannot distinguish crops") }
            let expectedEdge = 0.44 * viewport.height / cropHeight
            let measuredEdge = Double(edgeRow) / Double(redPreview.pixelsHigh)
            try check("top_aligned_crop", abs(measuredEdge - expectedEdge) <= tolerance)
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
            try await wait("five real previews before leaving space") {
                alternatives.allSatisfy { self.real(beforeSpace, $0.0, $0.1) }
            }
            try await escape(runtime)
            let newSpace: WorkspaceSnapshot = try await withCheckedThrowingContinuation { continuation in
                workspace.createSpace(name: "Switcher other space") { continuation.resume(with: $0) }
            }
            guard let other = newSpace.spaces.first(where: { $0.title == "Switcher other space" })?.id
            else { throw CheckFailure(condition: "create space") }
            runtime.show(newSpace)
            try await showSpace(runtime, other)
            try await showSpace(runtime, originalSpace)
            try await wait("returned to original tab") { host.activeItemId() == eligible.last?.0 }
            let afterSpace = try await hold(runtime)
            try check("five_previews_after_space_return", alternatives.allSatisfy { real(afterSpace, $0.0, $0.1) })
        }

        await scene("saved_favicon") {
            let red = try await open(runtime, url: url("red") + "?favicon")
            try await wait("red page favicon saved") { self.color(self.tab(runtime, red)?.favicon, "yellow", at: 0.5) }
            let initialIDs = Set(runtime.snapshot.spaces.flatMap { $0.today.map(\.id) })
            let duplicated = try adapter.session.queue.sync {
                try adapter.session.store?.duplicateItem(windowId: runtime.windowID, id: red)
            }
            guard let duplicated, let unloaded = duplicated.spaces.flatMap(\.today).first(where: {
                !initialIDs.contains($0.id) && $0.unloaded && $0.url == self.tab(runtime, red)?.url
            }) else { throw CheckFailure(condition: "unloaded duplicate") }
            scenarioItems.append(unloaded.id)
            runtime.show(duplicated)
            let panel = try await hold(runtime)
            try await wait("unloaded saved favicon visible") {
                let tile = panel.previewForCheck(item: unloaded.id)
                return tile?.size == NSSize(width: 22, height: 22) && self.color(tile?.image, "yellow", at: 0.5)
            }
            try check("saved_favicon", tab(runtime, unloaded.id) == nil && panel.previewForCheck(item: unloaded.id)?.fillsPreview == false)
        }

        await scene("navigation_refresh") {
            let red = try await open(runtime, url: url("red"))
            try await awaitPicture(runtime, red, "red")
            host.checkNavigate("http://localhost:\(port)/switcher/blue?refreshed", disposition: "current")
            try await awaitPicture(runtime, red, "blue")
            _ = try await open(runtime, url: url("green"))
            let panel = try await hold(runtime)
            try check("navigation_refresh", real(panel, red, "blue"))
        }

        await scene("slow_page_favicon") {
            let slow = try await open(runtime, url: "about:blank")
            guard let live = tab(runtime, slow)?.liveId else { throw CheckFailure(condition: "slow tab missing") }
            host.checkNavigate(url("slow"), disposition: "current")
            try await wait("slow navigation pending") { self.tab(runtime, slow)?.isLoading == true }
            _ = try await open(runtime, url: url("red"))
            let panel = try await hold(runtime)
            let tile = panel.previewForCheck(item: slow)
            try check("slow_page_favicon", tile?.fillsPreview == false && tile?.size.width == 22 &&
                      tile?.image != nil && hasEvent(live: live, source: "prehide", status: "skipped",
                                                     reasons: ["navigation-pending", "no-paint"]))
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
            try await wait("painted original document after abort") { self.real(panel, blue, "blue") }
            try check("aborted_navigation", tab(runtime, blue)?.navigationCount == navigationCount &&
                      hasEvent(mark: mark, live: live, source: "prehide", status: "requested"))
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
            else { throw CheckFailure(condition: "make split") }
            try await wait("split visible") { adapter.checkSplitFocus().panes.count == 2 && host.activeItemId() != nil }
            return (blueLive, redLive)
        }

        await scene("split_focus_no_readback") {
            let split = try await openSplit()
            let active = host.activeItemId()
            let mark = events.count
            adapter.focusPane(backwards: false)
            try await wait("other split pane focused") {
                host.activeItemId() != active && adapter.checkSplitFocus().panes.count == 2
            }
            try check("split_focus_no_readback", !hasEvent(mark: mark, live: split.red, source: "prehide", status: "requested") &&
                      !hasEvent(mark: mark, live: split.blue, source: "prehide", status: "requested"))
        }
        await scene("split_leave_both_readbacks") {
            let split = try await openSplit()
            let mark = events.count
            _ = try await open(runtime, url: url("green"))
            try await wait("both split readbacks requested") {
                self.hasEvent(mark: mark, live: split.red, source: "prehide", status: "requested") &&
                self.hasEvent(mark: mark, live: split.blue, source: "prehide", status: "requested")
            }
            try check("split_leave_both_readbacks", adapter.checkSplitFocus().panes.count < 2)
        }

        await scene("little_window_handoff") {
            runtime.openLittleWindow(url: url("red") + "?handoff")
            defer { for little in runtime.littleWindows { little.window?.close() } }
            try await wait("Little Window document") {
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
            try await wait("Little Window handed off without reload") {
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
            try check("little_window_handoff", real(panel, handedItem, "red") &&
                      hasEvent(mark: mark, live: live, source: "prehide", status: "requested") &&
                      (hasEvent(mark: mark, live: live, source: "prehide", status: "completed") ||
                       hasEvent(mark: mark, live: live, source: "reserve", status: "completed")))
        }

        await scene("close_during_readback") {
            let item = try await open(runtime, url: url("red") + "?close")
            try await awaitPicture(runtime, item, "red")
            guard let live = tab(runtime, item)?.liveId else { throw CheckFailure(condition: "closing tab missing") }
            let mark = events.count
            closeLive = live
            defer { closeLive = nil; closeOnReadback = nil }
            closeOnReadback = { [weak self, weak runtime] in
                DispatchQueue.main.async {
                    guard let self, let runtime, let retiring = self.tab(runtime, item),
                          !self.hasEvent(mark: mark, live: live, source: "prehide", status: "completed"),
                          !self.hasEvent(mark: mark, live: live, source: "prehide", status: "failed") else { return }
                    self.trace("close while readback pending live=\(live)")
                    retiring.close(withCommandId: "switcher-in-flight-close")
                }
            }
            _ = try await open(runtime, url: url("green"))
            try await wait("closed tab with readback pending") { self.tab(runtime, item) == nil }
            try await wait("closed tab readback reported failure") {
                self.hasEvent(mark: mark, live: live, source: "prehide", status: "failed", reasons: ["stale-document", "error"])
            }
            try check("close_during_readback", hasEvent(mark: mark, live: live, source: "prehide", status: "requested") &&
                      !hasEvent(mark: mark, live: live, source: "prehide", status: "completed"))
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
            try await wait("private window foreground") {
                runtime.children.contains { $0.isPrivateWindow && $0.host?.window().isKeyWindow == true }
            }
            guard let child = runtime.children.first(where: { $0.isPrivateWindow && $0.host != nil }),
                  let privateHost = child.host else { throw CheckFailure(condition: "private window missing") }
            child.tabSwitcherScreenCheck = self
            observe(child)

            await attempt("private_unpainted_globe") {
                defer { child.tabSwitcher?.cancel() }
                let blank = try await open(child, url: "about:blank")
                _ = try await open(child, url: url("green") + "?" + privateToken)
                let panel = try await hold(child)
                let globe = panel.previewForCheck(item: blank)
                try check("private_unpainted_globe", globe?.fillsPreview == false && globe?.size.width == 22 &&
                          globe?.image != nil && tab(child, blank)?.favicon == nil)
            }
            await attempt("private_previews") {
                defer { child.tabSwitcher?.cancel() }
                let red = try await open(child, url: url("red") + "?" + privateToken)
                try await awaitPicture(child, red, "red")
                let blue = try await open(child, url: url("blue") + "?" + privateToken)
                try await awaitPicture(child, blue, "blue")
                _ = try await open(child, url: url("green") + "?" + privateToken)
                let panel = try await hold(child)
                try check("private_previews", real(panel, red, "red") && real(panel, blue, "blue"))
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
            await attempt("private_close_releases") {
                let cached = try cached.get()
                try closed.get()
                try check("private_close_releases", cached.adapter.switcherThumbnail(item: cached.item, live: cached.live) == nil)
            }
            await attempt("private_memory_only") {
                _ = try cached.get()
                try closed.get()
                let before = try diskBefore.get()
                let during = try diskDuring.get()
                let after = try diskPreviewFiles()
                let rows = runtime.captureCheckRows()
                try check("private_memory_only", before == during && during == after && rows != nil &&
                          rows?.contains(where: { $0.contains(where: { $0.contains(privateToken) }) }) == false)
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
