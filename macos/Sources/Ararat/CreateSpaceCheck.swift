import AppKit
import AraratEngineAPI
import AraratKit
import AraratUI

/// P4 item 6: Create a Space in the app (not the harness). The owner's host run left the page up
/// with the button greyed after Return; the harness had always called `applyCreatedSpace`, so
/// only this path was broken. The check types a name through the page's own submit path, presses
/// Return twice (the second must be refused), and then injects a core error to see the failure
/// screen re-enable the button.
@MainActor
final class CreateSpaceCheckState {
    static let names = ["seed", "opened", "typed", "one_request", "landed", "page_closed",
                        "shown_space", "dock_cell", "failure_shown", "failure_reenabled", "no_duplicate"]
    static let screens = ["capture_created", "capture_failure"]

    var conditions: [String: Bool] = [:]
    var images: [String: String] = [:]
    var details: [String: Any] = [:]
    var waitName = ""
    var waitTicks = 0
    var capturing = false
    var before: (count: Int, shown: String)?
    var newSpace = ""
    var submits = (first: false, second: false)

    func mark(_ name: String, _ value: Bool = true) {
        conditions[name] = value
        FileHandle.standardError.write(Data("ararat-trace: create-space \(name)=\(value)\n".utf8))
    }

    func wait(_ name: String, _ value: String) {
        if waitName != name || waitTicks % 20 == 0 {
            FileHandle.standardError.write(Data("ararat-trace: create-space wait=\(name) current=\(value)\n".utf8))
        }
        if waitName != name { waitTicks = 0; waitName = name }
        waitTicks += 1
    }

    static func conditionNames(screen: Bool) -> [String] {
        names + (screen ? screens : [])
    }

    func diagnostics(screen: Bool) -> [String: Any] {
        let names = Self.conditionNames(screen: screen)
        return ["conditions": Dictionary(uniqueKeysWithValues: names.map { ($0, conditions[$0] == true) }),
                "failed_conditions": names.filter { conditions[$0] != true },
                "images": images, "details": details, "wait": waitName,
                "unverified": ["The owner's Return on the real keyboard (the check drives the page's submit path)",
                               "A core failure that is not injected"]]
    }
}

extension Runtime {
    func createSpaceCheckTick(_ host: any ARWindowHostAPI, screen: Bool) {
        if createSpaceCheck == nil { createSpaceCheck = CreateSpaceCheckState() }
        guard let check = createSpaceCheck, let sidebar, let container else { return }
        let window = host.window()
        func wait(_ name: String) {
            let page = sidebar.checkCreateSpace
            check.wait(name, "phase=\(browserCheckPhase) page=\(page.open) submitting=\(page.submitting) button=\(page.buttonEnabled) error=\(page.error) spaces=\(snapshot.spaces.count) shown=\(snapshot.shownSpaceId ?? "nil") key=\(window.isKeyWindow)")
        }
        func capture(_ name: String) -> Bool {
            guard screen else { return true }
            check.capturing = true; defer { check.capturing = false }
            guard let path = promptScreenScreenshot(window, name: "create-space-\(name)", withoutShadow: true) else { return false }
            check.images[name] = path
            return true
        }
        func finish() {
            let result = check.diagnostics(screen: screen)
            finishBrowserCheck(ok: (result["failed_conditions"] as? [String] ?? ["invalid"]).isEmpty, values: result)
        }
        switch browserCheckPhase {
        case 0:
            guard window.isVisible, window.isKeyWindow, let space = snapshot.spaces.first(where: { $0.id == snapshot.shownSpaceId }),
                  !sidebar.checkCreateSpace.open else { wait("key window and shown space"); return }
            check.mark("seed", !space.today.isEmpty)
            check.before = (snapshot.spaces.count, space.id)
            sidebar.showCreateSpace()
            browserCheckPhase = 1
        case 1:
            let page = sidebar.checkCreateSpace
            guard page.open else { wait("create page"); return }
            check.mark("opened")
            sidebar.checkTypeSpaceName("Research")
            guard sidebar.checkCreateSpace.name == "Research", sidebar.checkCreateSpace.buttonEnabled else { wait("typed name"); return }
            check.mark("typed")
            check.submits.first = sidebar.checkSubmitSpaceName()
            check.submits.second = sidebar.checkSubmitSpaceName()
            check.mark("one_request", check.submits.first && !check.submits.second)
            browserCheckPhase = 2
        case 2:
            let page = sidebar.checkCreateSpace
            guard let before = check.before, snapshot.spaces.count == before.count + 1,
                  let created = snapshot.spaces.last, created.id != before.shown,
                  snapshot.shownSpaceId == created.id, !page.open else { wait("created space"); return }
            check.newSpace = created.id
            check.mark("landed")
            check.mark("page_closed", !page.open && !page.submitting)
            check.mark("shown_space", snapshot.shownSpaceId == created.id)
            check.details["created"] = ["id": created.id, "title": created.title, "spaces": snapshot.spaces.count]
            check.mark("dock_cell", sidebar.checkDockShowsSpace(created.id))
            if screen { check.mark("capture_created", capture("created")) }
            check.details["submits"] = ["first": check.submits.first, "second": check.submits.second]
            // The failure path: the injected refusal is refused by the core, so it must not add
            // a space either.
            createSpaceFailureInjections = 1
            sidebar.showCreateSpace()
            browserCheckPhase = 3
        case 3:
            guard sidebar.checkCreateSpace.open else { wait("second create page"); return }
            sidebar.checkTypeSpaceName("Second")
            _ = sidebar.checkSubmitSpaceName()
            browserCheckPhase = 4
        case 4:
            let page = sidebar.checkCreateSpace
            let expected = Self.createSpaceFailureMessage
            guard page.errorShown else { wait("failure message"); return }
            check.mark("failure_shown", page.error == expected && !page.submitting)
            check.mark("failure_reenabled", page.buttonEnabled && page.open)
            check.mark("no_duplicate", check.before.map { snapshot.spaces.count == $0.count + 1 } == true)
            check.details["failure"] = ["error": page.error, "open": page.open, "submitting": page.submitting,
                                        "button": page.buttonEnabled, "spaces": snapshot.spaces.count]
            if screen { check.mark("capture_failure", capture("failure")) }
            container.selectionChanged()
            finish()
        default:
            break
        }
    }
}
