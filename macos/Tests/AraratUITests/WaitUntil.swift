import Foundation
import Testing

@MainActor
func waitUntil(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    await Task.yield()
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(30)
    while !condition() && clock.now < deadline {
        let runLoopTurn = { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
        runLoopTurn()
        await Task.yield()
    }
    #expect(condition(), sourceLocation: sourceLocation)
}
