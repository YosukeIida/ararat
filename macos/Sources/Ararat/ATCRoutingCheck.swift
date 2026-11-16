import AppKit
import AraratEngineAPI
import AraratKit

@MainActor
final class ATCRoutingCheck {
    static let names = ["cold_launch", "default_little_window", "equals_little_window", "one_window_per_link",
                        "cross_profile", "today_top", "last_selected", "reuse_space_window", "deleted_target",
                        "most_recent", "profile_most_recent", "external_transition", "private_ignored", "all_closed", "reopen", "second_launch"]
    static let coldURL = "https://atc-space.test/cold"
    var conditions: [String: Bool] = [:]
    var phase = 0
    var lastTrace = ""
    var started = Date()
    var targetID = ""
    var process: Process?
    var privateRows: [String: [String]] = [:]

    static func seed(_ session: WorkspaceSession, window: String) throws {
        try session.queue.sync {
            guard let store = session.store else { throw NSError(domain: "ATC.seed", code: 1) }
            _ = try store.addRule(windowId: window, rule: Rule(id: "atc-space", conditions: [UrlCondition(style: .contains, text: "atc-space.test")], destination: .space(.space("named")), profile: .named("Profile 1")))
            _ = try store.addRule(windowId: window, rule: Rule(id: "atc-little", conditions: [UrlCondition(style: .equals, text: "https://atc-little.test/")], destination: .littleWindow(.named("Profile 1")), profile: .named("Profile 1")))
            _ = try store.addRule(windowId: window, rule: Rule(id: "atc-recent", conditions: [UrlCondition(style: .contains, text: "atc-rule-recent.test")], destination: .space(.mostRecent), profile: .named("Profile 1")))
        }
    }

    func tick(_ owner: Runtime) {
        owner.browserCheckPhase = phase
        owner.browserCheckAttempts += 1
        func finish(_ error: String? = nil) {
            let names = Self.names + (CommandLine.arguments.contains("--ararat-atc-launchservices") ? ["launchservices"] : [])
            var values: [String: Any] = ["conditions": conditions, "failed_conditions": names.filter { conditions[$0] != true }, "phase": phase]
            if let process, !process.isRunning { values["forward_exit"] = process.terminationStatus }
            if let error { values["error"] = error }
            owner.finishBrowserCheck(ok: error == nil && names.allSatisfy { conditions[$0] == true }, values: values)
        }
        guard Date().timeIntervalSince(started) < 100 else { finish("ATC timeout"); return }
        guard let session = owner.adapter?.session else { return }
        func current(_ window: Runtime) -> WorkspaceSnapshot? {
            session.queue.sync { session.store?.snapshot(windowId: window.windowID) }
        }
        let windows = owner.windowTree.filter { !$0.isPrivateWindow && $0.hasUsableHost }
        // Relying on Chromium's Show would leave exit-check popups hidden.
        for controller in owner.windowTree.flatMap(\.littleWindows) {
            if let window = controller.window, !window.isVisible { window.makeKeyAndOrderFront(nil) }
        }
        let little = owner.windowTree.flatMap(\.littleWindows).filter { $0.popup.host?.window().isVisible == true }
        let windowStates = windows.map { window in
            let snapshot = current(window)
            return "\(window.windowID):space=\(snapshot?.shownSpaceId ?? "nil"):selected=\(snapshot?.selectedId ?? "nil"):active=\(window.host?.activeItemId() ?? "nil"):top=\(snapshot?.spaces.first { $0.id == snapshot?.shownSpaceId }?.today.first?.url ?? "nil")"
        }
        let hosts = owner.windowTree.map { "\($0.windowID):private=\($0.isPrivateWindow):host=\($0.host != nil):closing=\($0.hostClosing)" }
        let forward = process.map { $0.isRunning ? "running" : "exit=\($0.terminationStatus):reason=\($0.terminationReason.rawValue)" } ?? "none"
        let state = "phase=\(phase) queue=\(owner.externalURLs.map(\.url)) opening=\(owner.openingExternalURL) little=\(little.count) windows=\(windowStates) hosts=\(hosts) forward=\(forward)"
        if state != lastTrace {
            lastTrace = state
            FileHandle.standardError.write(Data("ararat-trace: atc-routing \(state)\n".utf8))
        }
        func target(_ url: String, space: String = "named") -> Runtime? {
            windows.first { window in
                guard let snapshot = current(window), snapshot.shownSpaceId == space,
                      let row = snapshot.spaces.first(where: { $0.id == space })?.today.first else { return false }
                return row.url == url && snapshot.selectedId == row.id && window.host?.activeItemId() == row.id
            }
        }
        func deliver(_ strings: [String]) {
            FileHandle.standardError.write(Data("ararat-trace: atc-deliver phase=\(phase) delegate=\(String(describing: NSApp.delegate)) urls=\(strings)\n".utf8))
            NSApp.delegate?.application?(NSApp, open: strings.compactMap(URL.init(string:)))
        }
        func next() { phase += 1 }
        do {
            switch phase {
            case 0:
                guard CommandLine.arguments.contains(Self.coldURL) else { finish("Launch with \(Self.coldURL)"); return }
                guard let window = target(Self.coldURL) else { return }
                targetID = window.windowID
                conditions["cold_launch"] = true
                deliver(["https://atc-default.test/"])
                next()
            case 1:
                guard little.count == 1 else { return }
                conditions["default_little_window"] = little[0].profileName == "Default"
                guard let tab = (little[0].popup.host?.tabs() as? [any ARTabAPI])?.first else { return }
                let navigation = tab.checkNavigationState()
                guard (navigation["pending_url"] as? String ?? navigation["committed_url"] as? String) == "https://atc-default.test/",
                      let external = navigation["auto_toplevel"] as? Bool else { return }
                conditions["external_transition"] = external
                deliver(["https://atc-little.test/", "https://atc-little.test/"])
                next()
            case 2:
                guard little.count == 3, !owner.openingExternalURL else { return }
                conditions["equals_little_window"] = little.suffix(2).allSatisfy { $0.profileName == "Profile 1" }
                conditions["one_window_per_link"] = true
                owner.host?.window().makeKeyAndOrderFront(nil)
                deliver(["https://atc-rule-recent.test/", "https://atc-space.test/first", "https://atc-space.test/last"])
                next()
            case 3:
                guard let window = target("https://atc-space.test/last"), !owner.openingExternalURL,
                      let snapshot = current(window), let space = snapshot.spaces.first(where: { $0.id == "named" }) else { return }
                conditions["cross_profile"] = window.host?.profileDirectory() == "Profile 1"
                conditions["profile_most_recent"] = space.today.contains { $0.url == "https://atc-rule-recent.test/" }
                conditions["today_top"] = space.today.prefix(2).compactMap(\.url) == ["https://atc-space.test/last", "https://atc-space.test/first"]
                conditions["last_selected"] = window.host?.window().isKeyWindow == true
                conditions["reuse_space_window"] = window.windowID == targetID
                try session.queue.sync {
                    let store = session.store!
                    _ = try store.createSpace(windowId: owner.windowID, name: "Deleted", spaceId: "atc-deleted")
                    _ = try store.addRule(windowId: owner.windowID, rule: Rule(id: "atc-deleted", conditions: [UrlCondition(style: .contains, text: "atc-deleted.test")], destination: .space(.space("atc-deleted")), profile: .default))
                    _ = try store.liveDeleteSpace(windowId: owner.windowID, spaceId: "atc-deleted")
                }
                deliver(["https://atc-deleted.test/"])
                next()
            case 4:
                guard let fallback = target("https://atc-deleted.test/", space: "default"), !owner.openingExternalURL else { return }
                conditions["deleted_target"] = fallback.host?.profileDirectory() == "Default"
                _ = try session.queue.sync { try session.store!.setDefaultDestination(windowId: owner.windowID, destination: .space(.mostRecent)) }
                windows.first { $0.windowID == targetID }?.host?.window().makeKeyAndOrderFront(nil)
                deliver(["https://atc-recent.test/"])
                next()
            case 5:
                guard let window = target("https://atc-recent.test/") else { return }
                conditions["most_recent"] = window.windowID == targetID
                window.host?.checkNewIncognitoWindow()
                next()
            case 6:
                guard let privateWindow = owner.windowTree.first(where: { $0.isPrivateWindow && $0.hasUsableHost }) else { return }
                privateWindow.host?.window().makeKeyAndOrderFront(nil)
                guard privateWindow.host?.window().isKeyWindow == true else { return }
                privateRows = Dictionary(uniqueKeysWithValues: owner.windowTree.filter(\.isPrivateWindow).map { ($0.windowID, $0.snapshot.spaces.flatMap(\.today).map(\.id)) })
                deliver(["https://atc-private-key.test/", "https://atc-little.test/"])
                next()
            case 7:
                guard target("https://atc-private-key.test/") != nil, little.count == 4, !owner.openingExternalURL else { return }
                let after = Dictionary(uniqueKeysWithValues: owner.windowTree.filter(\.isPrivateWindow).map { ($0.windowID, $0.snapshot.spaces.flatMap(\.today).map(\.id)) })
                conditions["private_ignored"] = !privateRows.isEmpty && privateRows == after
                    && little.last?.profileName == "Profile 1" && little.last?.popup.host?.window().isKeyWindow == true
                for controller in little { controller.close() }
                for window in owner.windowTree { window.host?.close() }
                next()
            case 8:
                guard owner.windowTree.allSatisfy({ $0.host == nil }) else { return }
                conditions["all_closed"] = true
                deliver(["https://atc-no-window.test/reopen"])
                next()
            case 9:
                guard target("https://atc-no-window.test/reopen") != nil, !owner.openingExternalURL else { return }
                conditions["reopen"] = true
                let child = Process()
                child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
                child.arguments = CommandLine.arguments.filter { $0.hasPrefix("--user-data-dir=") || $0 == "--use-mock-keychain" } + ["https://atc-space.test/second"]
                child.standardOutput = FileHandle.nullDevice
                child.standardError = FileHandle.standardError
                try child.run()
                process = child
                next()
            case 10:
                guard target("https://atc-space.test/second") != nil, process?.isRunning == false else { return }
                // A forwarded second launch exits with CHROME_RESULT_CODE_NORMAL_EXIT_PROCESS_NOTIFIED (26), not 0.
                conditions["second_launch"] = process?.terminationReason == .exit && process?.terminationStatus == 26
                guard CommandLine.arguments.contains("--ararat-atc-launchservices") else { finish(); return }
                let child = Process()
                child.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                let bundle = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
                child.arguments = ["-a", bundle, "https://atc-space.test/launchservices"]
                try child.run()
                process = child
                next()
            case 11:
                guard target("https://atc-space.test/launchservices") != nil, process?.isRunning == false else { return }
                conditions["launchservices"] = process?.terminationStatus == 0
                finish()
            default: finish("Unexpected phase")
            }
        } catch { finish(String(describing: error)) }
    }
}
