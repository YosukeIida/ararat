import AppKit
import AraratEngineAPI
import AraratKit
import AraratUI
import ObjectiveC.runtime
import Testing
@testable import Ararat

@MainActor private final class TodayCheckHost: NSObject {}

@Test @MainActor
func todayCheckAnswersLeaveBeforeWaitingForTheCoreSnapshot() throws {
    _ = NSApplication.shared
    class_addProtocol(TodayCheckHost.self, objc_getProtocol("ARWindowHostAPI")!)
    let host = TodayCheckHost() as! any ARWindowHostAPI
    let runtime = Runtime(windowID: "today-check")
    runtime.sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: nil, selectedId: nil, spaces: []))
    let check = SidebarCheck()
    check.phase = 5
    var answers: [Bool] = []
    var traces: [String] = []
    var waits: [String] = []
    for screen in [false, true] {
        runtime.todayTickPhase(host, screen: screen, check: check, note: { waits.append($0) },
            trace: { traces.append($0) }, step: { _ in Issue.record("Advanced before close settled") },
            finish: { Issue.record("Finished before close settled") }, capture: { _ in false },
            click: { _, _ in false }, row: { _ in nil }, answerDialog: { answers.append($0); return true })
    }
    #expect(answers == [false])
    #expect(traces == ["dialog=clear-after-stay answer=leave"])
    #expect(waits == ["wait=clear-core-snapshot"])
    #expect(check.conditions.isEmpty)
}
