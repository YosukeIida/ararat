import AppKit
import ApplicationServices
import AraratEngineAPI
import AraratUI

@MainActor
enum PasswordsRealAuthCheck {
    static let passwordVariable = "ARARAT_CHECK_VM_PASSWORD"
    private static var password: String?

    static func readPassword() {
        guard let value = getenv(passwordVariable) else { return }
        password = String(validatingCString: value)
        if unsetenv(passwordVariable) != 0 { fail("could not remove the VM password from the environment") }
    }

    static func takePassword() -> String? {
        defer { password = nil }
        return password.flatMap { $0.isEmpty ? nil : $0 }
    }
}

extension Runtime {
    func settingsPasswordsRealAuthTick(_ probe: SettingsCheckProbe, check: SettingsScreenCheck,
                                       note: (String) -> Void, step: (Int) -> Void,
                                       end: (String, Bool) -> Void, finish: () -> Void) {
        let website = "https://passwords-real-auth.test/"
        let fixture = "Fixture-real-auth-123"
        guard probe.isVisible, probe.paneID == "passwords",
              let profile = (root ?? self).settings?.passwordsProfile,
              let handle = passwordsHandle(profile: profile) else {
            note("waiting for the Passwords pane and scratch profile")
            return
        }
        func hidden() -> Bool {
            !handle.checkHadBiometricsAvailable && !handle.showsFillAuthentication
                && probe.marker("row-password-fill")?.isEmpty != false
        }
        func unlock(using password: String?, next: Int) {
            let before = PasswordsAuthPrompt.windowIDs()
            check.passwordsAuthPrompt = nil
            step(next)
            Task.detached {
                let result = PasswordsAuthPrompt.interact(excluding: before, password: password)
                // Why not a MainActor task: the authorization dialog can hold the outer run loop open.
                let runLoop = CFRunLoopGetMain()
                CFRunLoopPerformBlock(runLoop, RunLoop.Mode.common.rawValue as CFString) {
                    MainActor.assumeIsolated { check.passwordsAuthPrompt = result }
                }
                CFRunLoopWakeUp(runLoop)
            }
            probe.unlockPasswords()
        }
        switch check.phase {
        case 2:
            guard probe.passwordsLocked, probe.marker("passwords-unlock")?.isEmpty == false else { return }
            guard !handle.checkUsesFakeAuthentication else { end("fake_auth_off", false); return }
            check.report("fake_auth_off", true)
            guard handle.checkTouchIDWasActivated != true else { end("touch_id_hook_off", false); return }
            check.report("touch_id_hook_off", true)
            guard hidden() else { end("fill_switch_hidden", false); return }
            check.report("fill_switch_hidden", true)
            if let added = check.conditions["fixtures"] {
                guard added else { finish(); return }
                unlock(using: nil, next: 3)
                return
            }
            guard !check.passwordSnapshotPending else { return }
            check.passwordSnapshotPending = true
            handle.snapshot { state, rows in
                check.passwordSnapshotPending = false
                guard state != .loading else { return }
                let added = state == .ready && rows.isEmpty && Array(fixture.utf16).withUnsafeBufferPointer {
                    handle.addWebsite(website, username: "fixture", password: $0.baseAddress!, length: UInt($0.count))
                }
                check.report("fixtures", added)
            }
        case 3:
            guard let prompt = check.passwordsAuthPrompt else { note("waiting for the system prompt"); return }
            check.details["system_prompt"] = prompt.details
            guard prompt.found else { end("system_prompt_shown", false); return }
            check.report("system_prompt_shown", true)
            if let image = prompt.image { check.images["system-prompt"] = image }
            check.report("capture", prompt.image != nil)
            guard prompt.actionError == nil else { end("cancel_keeps_locked", false); return }
            guard !probe.passwordsAuthenticationPending else { note("waiting for Cancel to complete"); return }
            let locked = probe.passwordsLocked && probe.passwordsAuthenticationFailed && !probe.passwordIsRevealed
                && probe.passwordWebsites == nil && probe.marker("passwords-revealed")?.isEmpty != false
            guard locked else { end("cancel_keeps_locked", false); return }
            check.report("cancel_keeps_locked", true)
            guard hidden() else { end("fill_switch_hidden", false); return }
            guard let password = PasswordsRealAuthCheck.takePassword() else {
                check.unverified["password_unlocks"] = "\(PasswordsRealAuthCheck.passwordVariable) is missing or empty"
                finish()
                return
            }
            unlock(using: password, next: 4)
        case 4:
            guard let prompt = check.passwordsAuthPrompt else { note("waiting for password submission"); return }
            check.details["password_prompt"] = prompt.details
            if let refusal = prompt.inputRefusal {
                check.unverified["password_unlocks"] = refusal
                finish()
                return
            }
            guard prompt.found, prompt.actionError == nil else { end("password_unlocks", false); return }
            guard !probe.passwordsAuthenticationPending else { note("waiting for login authorization"); return }
            guard !probe.passwordsAuthenticationFailed else { end("password_unlocks", false); return }
            guard probe.passwordWebsites == [website] else { note("waiting for the unlocked fixture"); return }
            step(5)
            probe.revealPassword(for: website)
        case 5:
            guard !probe.passwordsAuthenticationPending else { note("waiting for reveal using the recent authorization"); return }
            check.report("password_unlocks", probe.isShowingRevealedPassword(for: website, matching: fixture))
            check.report("fill_switch_hidden", hidden())
            finish()
        default:
            break
        }
    }
}

enum PasswordsAuthPrompt {
    enum Submission {
        case submitted
        case writeRefused(AXError)
        case failed(String)
    }

    struct Result {
        var found = false
        var owner = ""
        var title = ""
        var image: String?
        var actionError: String?
        var inputRefusal: String?

        mutating func recordSubmission(_ submission: Submission, waitForClose: () -> Bool) -> Bool {
            switch submission {
            case .submitted:
                if waitForClose() { return true }
                actionError = "Password submission was refused: the authorization window stayed open after AXPress"
            case .writeRefused(let error):
                inputRefusal = "AXValue write to AXSecureTextField returned AXError \(error.rawValue)"
            case .failed(let error):
                actionError = error
            }
            return false
        }

        var details: [String: String] {
            var values = ["owner": owner, "title": title]
            values["action_error"] = actionError
            values["input_refusal"] = inputRefusal
            return values
        }
    }

    private static func windows() -> [[String: Any]] {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
    }

    static func windowIDs() -> Set<CGWindowID> {
        Set(windows().compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
    }

    static func interact(excluding before: Set<CGWindowID>, password: String?) -> Result {
        var result = Result()
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        var previous: CGWindowID?
        while clock.now < deadline {
            defer { if !result.found { Thread.sleep(forTimeInterval: 0.1) } }
            let candidates = windows().filter {
                guard let id = $0[kCGWindowNumber as String] as? CGWindowID, !before.contains(id),
                      let owner = ($0[kCGWindowOwnerName as String] as? String)?.lowercased(),
                      let bounds = $0[kCGWindowBounds as String] as? NSDictionary,
                      let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
                return ["securityagent", "coreautha", "coreauthui", "authorizationhost"].contains(owner)
                    && frame.width >= 200 && frame.height >= 100
            }
            guard candidates.count == 1, let window = candidates.first,
                  let id = window[kCGWindowNumber as String] as? CGWindowID,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else {
                previous = nil
                continue
            }
            guard previous == id else { previous = id; continue }
            result.found = true
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.5)
            let (axWindows, status) = attribute(app, kAXWindowsAttribute)
            let dialog = (axWindows as? [AXUIElement])?
                .first(where: { matchesFrame($0, frame) })
            if let password {
                let submission = dialog.map { submit(password, in: $0) }
                    ?? .failed("AXWindows did not expose the authorization window (AXError \(status.rawValue))")
                if result.recordSubmission(submission, waitForClose: { waitForWindowToClose(id) }) { return result }
            } else {
                result.owner = window[kCGWindowOwnerName as String] as? String ?? ""
                result.title = window[kCGWindowName as String] as? String ?? ""
                result.image = capture(id)
            }
            if windowIDs().contains(id) {
                if let error = cancel(dialog, pid: pid, windowID: id) {
                    result.actionError = result.actionError.map { $0 + "; " + error } ?? error
                }
            } else if password == nil {
                result.actionError = "The authorization window closed before Cancel was sent"
            }
            return result
        }
        result.actionError = "No unique new system authorization window in CGWindowList within 10 seconds"
        return result
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> (CFTypeRef?, AXError) {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return (value, status)
    }

    private static func matchesFrame(_ window: AXUIElement, _ frame: CGRect) -> Bool {
        guard let position = attribute(window, kAXPositionAttribute).0, CFGetTypeID(position) == AXValueGetTypeID(),
              let dimensions = attribute(window, kAXSizeAttribute).0, CFGetTypeID(dimensions) == AXValueGetTypeID() else { return false }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(dimensions as! AXValue, .cgSize, &size) else { return false }
        return abs(frame.minX - origin.x) <= 2 && abs(frame.minY - origin.y) <= 2
            && abs(frame.width - size.width) <= 2 && abs(frame.height - size.height) <= 2
    }

    private static func button(_ window: AXUIElement, _ name: String) -> (AXUIElement?, AXError) {
        let (value, status) = attribute(window, name)
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return (nil, status) }
        return ((value as! AXUIElement), status)
    }

    private static func elements(_ element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
        guard depth < 8 else { return [] }
        let children = attribute(element, kAXChildrenAttribute).0 as? [AXUIElement] ?? []
        return [element] + children.flatMap { elements($0, depth: depth + 1) }
    }

    private static func submit(_ password: String, in dialog: AXUIElement) -> Submission {
        let controls = elements(dialog)
        let isUnlockPrompt = controls.contains { control in
            guard attribute(control, kAXRoleAttribute).0 as? String == kAXStaticTextRole else { return false }
            return [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute].contains { name in
                (attribute(control, name).0 as? String)?.localizedCaseInsensitiveContains("unlock saved passwords") == true
            }
        }
        guard isUnlockPrompt else { return .failed("AX did not expose the saved-password unlock message") }
        let fields = controls.filter { attribute($0, kAXSubroleAttribute).0 as? String == "AXSecureTextField" }
        guard fields.count == 1, let field = fields.first else {
            return .failed("AXChildren exposed \(fields.count) secure text fields")
        }
        let (submit, status) = button(dialog, kAXDefaultButtonAttribute)
        guard let submit else { return .failed("AXDefaultButton unavailable (AXError \(status.rawValue))") }
        let set = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, password as CFString)
        guard set == .success else { return .writeRefused(set) }
        let press = AXUIElementPerformAction(submit, kAXPressAction as CFString)
        return press == .success ? .submitted : .failed("AXPress on AXDefaultButton returned AXError \(press.rawValue)")
    }

    private static func waitForWindowToClose(_ id: CGWindowID) -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(4)
        repeat {
            if !windowIDs().contains(id) { return true }
            Thread.sleep(forTimeInterval: 0.1)
        } while clock.now < deadline
        return false
    }

    static func escapeCancellationError(after refusal: String, windowClosed: Bool) -> String? {
        windowClosed ? nil : refusal + "; the authorization window stayed open after process-directed Escape"
    }

    private static func cancel(_ dialog: AXUIElement?, pid: pid_t, windowID: CGWindowID) -> String? {
        var refusal = "AXWindows did not expose the authorization window"
        if let dialog {
            let (cancel, status) = button(dialog, kAXCancelButtonAttribute)
            refusal = "AXCancelButton unavailable (AXError \(status.rawValue))"
            if let cancel {
                let press = AXUIElementPerformAction(cancel, kAXPressAction as CFString)
                if press == .success { return nil }
                refusal = "AXPress on AXCancelButton returned AXError \(press.rawValue)"
            }
        }
        guard CGPreflightPostEventAccess(),
              let down = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false) else {
            return refusal + "; process-directed Escape unavailable"
        }
        down.postToPid(pid)
        up.postToPid(pid)
        return escapeCancellationError(after: refusal, windowClosed: waitForWindowToClose(windowID))
    }

    private static func capture(_ id: CGWindowID) -> String? {
        guard let temporary = ProcessInfo.processInfo.environment["TMPDIR"] else { return nil }
        let path = (temporary as NSString).appendingPathComponent("ararat-passwords-real-auth-system-prompt-\(UUID().uuidString).png")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-o", "-l\(id)", path]
        do { try task.run(); task.waitUntilExit() } catch { return nil }
        guard task.terminationStatus == 0, FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }
}
