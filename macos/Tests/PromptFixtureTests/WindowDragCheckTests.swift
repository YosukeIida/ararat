import CoreGraphics
import Testing
@testable import Ararat

@Test @MainActor
func windowDragCheckEventsCarryBothDeltasInCGCoordinates() throws {
    let start = CGPoint(x: 120, y: 200)
    let midway = CGPoint(x: 124.2, y: 202.8)
    let end = CGPoint(x: 180, y: 240)
    for (point, previous, dx, dy) in [(midway, start, Int64(4), Int64(3)),
                                       (end, midway, 56, 37),
                                       (start, end, -60, -40)] {
        let event = try #require(WindowDragCheckState.mouseEvent(.leftMouseDragged, at: point, from: previous))
        #expect(event.location == point)
        #expect(event.getIntegerValueField(.mouseEventDeltaX) == dx)
        #expect(event.getIntegerValueField(.mouseEventDeltaY) == dy)
        #expect(event.getIntegerValueField(.mouseEventClickState) == 1)
    }
}

@Test @MainActor
func windowDragCheckStationaryEventsHaveNoDelta() throws {
    for type: CGEventType in [.mouseMoved, .leftMouseDown, .leftMouseUp] {
        let event = try #require(WindowDragCheckState.mouseEvent(type, at: CGPoint(x: 180, y: 240)))
        #expect(event.getIntegerValueField(.mouseEventDeltaX) == 0)
        #expect(event.getIntegerValueField(.mouseEventDeltaY) == 0)
    }
}
