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
        "little_window_handoff", "private_previews", "private_globe", "private_memory_only",
        "private_close_releases", "close_during_readback",
    ]
    private struct CheckFailure: Error { let condition: String }
    private var conditions: [String: Bool] = [:]
    private var events: [[String: Any]] = []
    private var presentations: [(visible: Bool, elapsed: TimeInterval, timestamp: TimeInterval, noAnimation: Bool)] = []
    private var images: [String: String] = [:]
    private var waiting = "fixture"
    private var closeOnReadback: (() -> Void)?
    private var closeLive: String?

    func result() -> [String: Any] {
        [
            "check": "tab-switcher", "screen": "tab-switcher",
            "conditions": Dictionary(uniqueKeysWithValues: Self.names.map { ($0, conditions[$0] == true) }),
            "failed_conditions": Self.names.filter { conditions[$0] != true }, "wait": waiting,
            "images": images, "readbacks": events, "unverified": ["drm_hover_card_parity"],
        ]
    }

    func presentationChanged(visible: Bool, elapsed: TimeInterval, noAnimation: Bool) {
        presentations.append((visible, elapsed, ProcessInfo.processInfo.systemUptime, noAnimation))
        trace("panel visible=\(visible) elapsed_ms=\(elapsed * 1000) no_fade=\(noAnimation)")
    }

    private func trace(_ message: String) {
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

    private func check(_ name: String, _ condition: @autoclosure () -> Bool) throws {
        waiting = name
        guard condition() else { throw CheckFailure(condition: name) }
        conditions[name] = true
        trace("condition=\(name) ok=true")
    }

    private func wait(_ name: String, until ready: () -> Bool) async throws {
        waiting = name
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while !ready() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CheckFailure(condition: name) }
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
        NSApp.postEvent(event, atStart: false)
    }

    private func hold(_ runtime: Runtime) async throws -> TabSwitcher {
        presentations.removeAll()
        try key(runtime, 48, flags: .control, chars: "\t")
        try await wait("switcher visible") { runtime.tabSwitcher?.visibleWindow != nil }
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
        guard let bitmap = bitmap(image), bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0,
              let pixel = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: Int(Double(bitmap.pixelsHigh - 1) * height))?.usingColorSpace(.sRGB)
        else { return false }
        let (r, g, b) = (pixel.redComponent, pixel.greenComponent, pixel.blueComponent)
        switch name {
        case "red": return r > 0.6 && g < 0.35 && b < 0.35
        case "blue": return b > 0.6 && r < 0.35 && g < 0.5
        case "green": return g > 0.45 && r < 0.35 && b < 0.4
        case "yellow": return r > 0.7 && g > 0.55 && b < 0.4
        case "dark": return max(r, g, b) < 0.24
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
        var errorMessage: String?
        defer {
            var values = result()
            if let errorMessage { values["error"] = errorMessage }
            runtime.finishBrowserCheck(ok: errorMessage == nil && Self.names.allSatisfy { conditions[$0] == true }, values: values)
        }
        do { try await exercise(runtime, host: host) }
        catch let error as CheckFailure { errorMessage = error.condition }
        catch { errorMessage = String(describing: error) }
    }

    private func exercise(_ runtime: Runtime, host: any ARWindowHostAPI) async throws {
        observe(runtime)
        try await wait("fixture and key window") {
            runtime.promptFixturePort != nil && host.window().isKeyWindow && runtime.snapshot.shownSpaceId != nil
        }
        guard let port = runtime.promptFixturePort, let originalSpace = runtime.snapshot.shownSpaceId,
              let workspace = runtime.workspace, let adapter = runtime.adapter else { throw CheckFailure(condition: "fixture") }
        func url(_ name: String) -> String { "http://127.0.0.1:\(port)/switcher/\(name)" }

        let red = try await open(runtime, url: url("red"))
        try await awaitPicture(runtime, red, "red")
        guard let redTab = tab(runtime, red) else { throw CheckFailure(condition: "red_tab") }
        let redLive = redTab.liveId
        let viewport = redTab.view?.bounds.size ?? .zero
        let blue = try await open(runtime, url: url("blue"))
        try await awaitPicture(runtime, blue, "blue")
        let green = try await open(runtime, url: url("green"))
        try await awaitPicture(runtime, green, "green")
        try await wait("prehide readback reports result") {
            self.hasEvent(live: redLive, source: "prehide", status: "completed") ||
            self.hasEvent(live: redLive, source: "prehide", status: "failed", reasons: ["timeout", "empty", "error"])
        }
        try check("visible_vs_detach", hasEvent(live: redLive, source: "reserve", status: "requested") &&
                  hasEvent(live: redLive, source: "reserve", status: "completed") &&
                  hasEvent(live: redLive, source: "prehide", status: "requested"))

        presentations.removeAll()
        try key(runtime, 48, flags: .control, chars: "\t")
        try key(runtime, 59, type: .flagsChanged)
        try await wait("quick tap selected previous") { host.activeItemId() == blue && runtime.tabSwitcher == nil }
        try await Task.sleep(for: .milliseconds(170))
        try check("quick_tap", presentations.isEmpty)
        try await select(runtime, green)

        let panel = try await hold(runtime)
        try check("two_real_previews", real(panel, red, "red") && real(panel, blue, "blue"))
        let cropHeight = min(viewport.height, viewport.width * 2 / 3)
        let edge = cropHeight > 0 ? 0.44 * viewport.height / cropHeight : 0
        let redPreview = panel.previewForCheck(item: red)?.image
        try check("top_aligned_crop", edge > 0.09 && edge < 0.97 &&
                  color(redPreview, "red", at: edge - 0.09) && color(redPreview, "dark", at: min(0.99, edge + 0.08)))
        if let overlay = panel.visibleWindow,
           let file = runtime.promptScreenScreenshot(host.window(), name: "tab-switcher-two-previews", overlay: overlay) {
            images["tab-switcher"] = file
        }
        try check("capture", images["tab-switcher"] != nil)
        try check("held_once_without_fade", presentations.count == 1 && presentations[0].visible &&
                  presentations[0].elapsed >= 0.145 && presentations[0].elapsed < 0.7 && presentations[0].noAnimation)
        var sent = ProcessInfo.processInfo.systemUptime
        try key(runtime, 59, type: .flagsChanged)
        try await wait("hold released") { runtime.tabSwitcher == nil && host.activeItemId() == blue }
        try check("release_immediate", presentations.map(\.visible) == [true, false] &&
                  presentations.last?.noAnimation == true && (presentations.last?.timestamp ?? .infinity) - sent < 0.25)
        _ = try await hold(runtime)
        sent = ProcessInfo.processInfo.systemUptime
        try await escape(runtime)
        try check("escape_immediate", presentations.map(\.visible) == [true, false] &&
                  presentations.last?.noAnimation == true && host.activeItemId() == blue &&
                  (presentations.last?.timestamp ?? .infinity) - sent < 0.25)

        var eligible = [(red, "red"), (blue, "blue"), (green, "green")]
        for name in ["red", "blue", "green"] {
            let item = try await open(runtime, url: url(name) + "?additional")
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
        runtime.switchWorkspaceSpace(other)
        try await wait("left original space") { runtime.snapshot.shownSpaceId == other }
        runtime.switchWorkspaceSpace(originalSpace)
        try await wait("returned to original space") {
            runtime.snapshot.shownSpaceId == originalSpace && host.activeItemId() == eligible.last?.0
        }
        let afterSpace = try await hold(runtime)
        try check("five_previews_after_space_return", alternatives.allSatisfy { real(afterSpace, $0.0, $0.1) })
        try await escape(runtime)

        try await select(runtime, red)
        try await wait("red page favicon saved") { self.color(self.tab(runtime, red)?.favicon, "yellow", at: 0.5) }
        let initialIDs = Set(runtime.snapshot.spaces.flatMap { $0.today.map(\.id) })
        let duplicated = try adapter.session.queue.sync {
            try adapter.session.store?.duplicateItem(windowId: runtime.windowID, id: red)
        }
        guard let duplicated, let unloaded = duplicated.spaces.flatMap(\.today).first(where: {
            !initialIDs.contains($0.id) && $0.unloaded && $0.url == self.tab(runtime, red)?.url
        }) else { throw CheckFailure(condition: "unloaded duplicate") }
        runtime.show(duplicated)
        // An unloaded duplicate has no last-selected timestamp. Keep it in the five candidates
        // by closing the extra fixtures after the space-retention assertion.
        for item in eligible.dropFirst(3) { adapter.close(id: item.0, archive: false, animate: false) }
        try await wait("extra fixtures closed") { eligible.dropFirst(3).allSatisfy { self.tab(runtime, $0.0) == nil } }
        let faviconPanel = try await hold(runtime)
        try await wait("unloaded saved favicon visible") {
            let tile = faviconPanel.previewForCheck(item: unloaded.id)
            return tile?.size == NSSize(width: 22, height: 22) && self.color(tile?.image, "yellow", at: 0.5)
        }
        try check("saved_favicon", tab(runtime, unloaded.id) == nil && faviconPanel.previewForCheck(item: unloaded.id)?.fillsPreview == false)
        try await escape(runtime)

        host.checkNavigate("http://localhost:\(port)/switcher/blue?refreshed", disposition: "current")
        try await awaitPicture(runtime, red, "blue")
        try await select(runtime, green)
        let changed = try await hold(runtime)
        try check("navigation_refresh", real(changed, red, "blue"))
        try await escape(runtime)

        let slow = try await open(runtime, url: "about:blank")
        guard let slowLive = tab(runtime, slow)?.liveId else { throw CheckFailure(condition: "slow_tab") }
        host.checkNavigate(url("slow"), disposition: "current")
        try await wait("slow navigation pending") { self.tab(runtime, slow)?.isLoading == true }
        try await select(runtime, red)
        let fallback = try await hold(runtime)
        try check("slow_page_favicon", fallback.previewForCheck(item: slow)?.fillsPreview == false &&
                  fallback.previewForCheck(item: slow)?.size.width == 22 &&
                  fallback.previewForCheck(item: slow)?.image != nil &&
                  hasEvent(live: slowLive, source: "prehide", status: "skipped", reasons: ["navigation-pending", "no-paint"]))
        try await escape(runtime)

        let beforeAbort = tab(runtime, red)?.navigationCount
        host.checkNavigate(url("slow") + "?cancel", disposition: "current")
        try await wait("pending navigation invalidated old preview") {
            self.tab(runtime, red)?.isLoading == true && self.picture(runtime, red) == nil
        }
        tab(runtime, red)?.checkStopSwitcherNavigation()
        try await wait("pending navigation cancelled") { self.tab(runtime, red)?.isLoading == false }
        try await awaitPicture(runtime, red, "blue")
        let abortMark = events.count
        try await select(runtime, green)
        let aborted = try await hold(runtime)
        try await wait("painted original document after abort") { self.real(aborted, red, "blue") }
        try check("aborted_navigation", tab(runtime, red)?.navigationCount == beforeAbort &&
                  hasEvent(mark: abortMark, live: redLive, source: "prehide", status: "requested"))
        try await escape(runtime)

        try await select(runtime, red)
        let splitMade: Bool = await withCheckedContinuation { continuation in
            adapter.makeSplit(dragged: blue, target: red, side: .right) { continuation.resume(returning: $0) }
        }
        guard splitMade, let blueLive = tab(runtime, blue)?.liveId else { throw CheckFailure(condition: "make_split") }
        try await wait("split visible") { adapter.checkSplitFocus().panes.count == 2 && host.activeItemId() != nil }
        let active = host.activeItemId()
        let focusMark = events.count
        adapter.focusPane(backwards: false)
        try await wait("other split pane focused") {
            host.activeItemId() != active && adapter.checkSplitFocus().panes.count == 2
        }
        try check("split_focus_no_readback", !hasEvent(mark: focusMark, live: redLive, source: "prehide", status: "requested") &&
                  !hasEvent(mark: focusMark, live: blueLive, source: "prehide", status: "requested"))
        let leaveMark = events.count
        try await select(runtime, green)
        try await wait("both split readbacks requested") {
            self.hasEvent(mark: leaveMark, live: redLive, source: "prehide", status: "requested") &&
            self.hasEvent(mark: leaveMark, live: blueLive, source: "prehide", status: "requested")
        }
        try check("split_leave_both_readbacks", adapter.checkSplitFocus().panes.count < 2)

        runtime.openLittleWindow(url: url("red") + "?handoff")
        try await wait("Little Window document") {
            guard let popup = runtime.littleWindows.first,
                  let tab = (popup.popup.host?.tabs() as? [any ARTabAPI])?.first else { return false }
            return tab.title == "Switcher red" && !tab.isLoading && popup.window?.isVisible == true
        }
        guard let little = runtime.littleWindows.first,
              let littleTab = (little.popup.host?.tabs() as? [any ARTabAPI])?.first else { throw CheckFailure(condition: "little_window") }
        let handoffLive = littleTab.liveId
        let handoffCount = littleTab.navigationCount
        let handoffMark = events.count
        little.performOpenIn(spaceID: originalSpace)
        var handedItem: String?
        try await wait("Little Window handed off without reload") {
            let live = (host.tabs() as? [any ARTabAPI])?.first { $0.liveId == handoffLive }
            handedItem = live?.itemId
            return handedItem != nil && handedItem == host.activeItemId() && live?.navigationCount == 0 && handoffCount > 0 &&
                host.window().isKeyWindow
        }
        guard let handedItem else { throw CheckFailure(condition: "handoff item") }
        try await awaitPicture(runtime, handedItem, "red")
        try await select(runtime, green)
        let handoffPanel = try await hold(runtime)
        try check("little_window_handoff", real(handoffPanel, handedItem, "red") &&
                  hasEvent(mark: handoffMark, live: handoffLive, source: "prehide", status: "requested") &&
                  (hasEvent(mark: handoffMark, live: handoffLive, source: "prehide", status: "completed") ||
                   hasEvent(mark: handoffMark, live: handoffLive, source: "reserve", status: "completed")))
        try await escape(runtime)

        let diskBefore = try diskPreviewFiles()
        let privateToken = UUID().uuidString
        host.checkCreateIncognito()
        try await wait("private window foreground") {
            runtime.children.contains { $0.isPrivateWindow && $0.host?.window().isKeyWindow == true }
        }
        guard let child = runtime.children.first(where: { $0.isPrivateWindow && $0.host != nil }),
              let privateHost = child.host else { throw CheckFailure(condition: "private_window") }
        child.tabSwitcherScreenCheck = self
        observe(child)
        let privateBlank = try await open(child, url: "about:blank")
        let privateRed = try await open(child, url: url("red") + "?" + privateToken)
        try await awaitPicture(child, privateRed, "red")
        let privateBlue = try await open(child, url: url("blue") + "?" + privateToken)
        try await awaitPicture(child, privateBlue, "blue")
        _ = try await open(child, url: url("green") + "?" + privateToken)
        let privatePanel = try await hold(child)
        try check("private_previews", real(privatePanel, privateRed, "red") && real(privatePanel, privateBlue, "blue"))
        guard let privateAdapter = child.adapter, let privateLive = tab(child, privateRed)?.liveId else {
            throw CheckFailure(condition: "private_preview_owner")
        }
        let globe = privatePanel.previewForCheck(item: privateBlank)
        try check("private_globe", globe?.fillsPreview == false && globe?.size.width == 22 &&
                  globe?.image != nil && tab(child, privateBlank)?.favicon == nil)
        let diskDuring = try diskPreviewFiles()
        try await escape(child)
        privateHost.close()
        try await wait("private session closed") { child.host == nil && PrivateWorkspaces.liveCount == 0 }
        try check("private_close_releases", privateAdapter.switcherThumbnail(item: privateRed, live: privateLive) == nil)
        let diskAfter = try diskPreviewFiles()
        let rows = runtime.captureCheckRows()
        try check("private_memory_only", diskBefore == diskDuring && diskDuring == diskAfter && rows != nil &&
                  rows?.contains(where: { $0.contains(where: { $0.contains(privateToken) }) }) == false)
        try await wait("regular window foreground") { host.window().isKeyWindow }

        try await select(runtime, handedItem)
        let closeMark = events.count
        closeLive = handoffLive
        closeOnReadback = { [weak self, weak runtime] in
            DispatchQueue.main.async {
                guard let self, let runtime, let retiring = self.tab(runtime, handedItem),
                      !self.hasEvent(mark: closeMark, live: handoffLive, source: "prehide", status: "completed"),
                      !self.hasEvent(mark: closeMark, live: handoffLive, source: "prehide", status: "failed") else { return }
                self.trace("close while readback pending live=\(handoffLive)")
                retiring.close(withCommandId: "switcher-in-flight-close")
            }
        }
        try await select(runtime, green)
        try await wait("closed tab with readback pending") { self.tab(runtime, handedItem) == nil }
        try check("close_during_readback", hasEvent(mark: closeMark, live: handoffLive, source: "prehide", status: "requested") &&
                  !hasEvent(mark: closeMark, live: handoffLive, source: "prehide", status: "completed"))
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
