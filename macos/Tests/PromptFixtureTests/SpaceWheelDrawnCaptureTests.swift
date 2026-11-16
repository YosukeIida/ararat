import AraratUI
import Testing
@testable import Ararat

private func drawnPixels(source: Int, target: Int, pitch: Int, width: Int, offset: Int) -> [UInt8] {
    let from = (target - source) * pitch
    return (0..<width).map { x in
        let incoming = x - offset
        let outgoing = x + from - offset
        if (0..<width).contains(incoming) { return SpaceWheelDrawnPattern.white(space: target, x: incoming) ? 255 : 0 }
        if (0..<width).contains(outgoing) { return SpaceWheelDrawnPattern.white(space: source, x: outgoing) ? 255 : 0 }
        return 127
    }
}

@Test
func capturedRowDecodesBothDirectionsAndRejectsUnrecognizedPixels() {
    for (source, target) in [(4, 3), (3, 4)] {
        let from = (target - source) * 260
        for part in [0, 10, 112, 210, 260] {
            let offset = from < 0 ? -part : part
            let pixels = drawnPixels(source: source, target: target, pitch: 260, width: 244, offset: offset)
            #expect(SpaceWheelDrawnPattern.offset(pixels: pixels, source: source, target: target, pitch: 260) == Double(offset))
        }
    }
    #expect(SpaceWheelDrawnPattern.offset(pixels: Array(repeating: 127, count: 244), source: 4, target: 3, pitch: 260) == nil)
}

@Test @MainActor
func drawnFrameGateRejectsTheMeasuredOldStartEvenWhenThePresentationGatePasses() {
    let step = SpaceWheelDrawnCapture.Switch(time: 0, source: 4, target: 3, pitch: 260)
    let old = [(0.0, -260), (0.12, -260), (0.1275, -112), (0.16, -62), (0.2, -20), (0.3, 0)].map { time, offset in
        SpaceWheelDrawnCapture.Frame(time: time, pixels: drawnPixels(source: 4, target: 3, pitch: 260, width: 244, offset: offset))
    }
    let verdict = SpaceWheelDrawnCapture.conditions(old, switches: [step])
    #expect(verdict["first_frame_full_offset"] == false)
    #expect(verdict["landed"] == true)
    let complete = [(0.0, -260), (0.12, -260), (0.1275, -250), (0.14, -220), (0.156, -190),
                    (0.173, -150), (0.19, -110), (0.207, -80), (0.224, -55), (0.24, -30),
                    (0.257, -15), (0.274, -5), (0.3, 0)].map { time, offset in
        SpaceWheelDrawnCapture.Frame(time: time, pixels: drawnPixels(source: 4, target: 3, pitch: 260, width: 244, offset: offset))
    }
    #expect(SpaceWheelDrawnCapture.conditions(complete, switches: [step]).values.allSatisfy { $0 })
}
