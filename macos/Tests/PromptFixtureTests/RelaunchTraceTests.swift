import Foundation
import Testing
@testable import Ararat

@Test func relaunchTraceKeepsLastTraceAndBoundedTail() {
    let trace = RelaunchTrace()
    trace.append(Data("ararat-trace: phase=1\n".utf8))
    trace.append(Data(repeating: 65, count: 5000))
    let (tail, line) = trace.snapshot()
    #expect(tail.utf8.count == 4096)
    #expect(line == "ararat-trace: phase=1")
    trace.append(Data("\nararat-trace: phase=".utf8))
    trace.append(Data("2\n".utf8))
    #expect(trace.snapshot().1 == "ararat-trace: phase=2")
}
