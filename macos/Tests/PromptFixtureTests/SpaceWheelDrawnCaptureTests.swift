import AraratUI
import Testing
import CoreMedia
import CoreVideo
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
func drawnFrameGateRejectsPartialStartsAndAcceptsContinuousMotion() {
    let step = SpaceWheelDrawnCapture.Switch(time: 0, source: 4, target: 3, pitch: 260)
    let partial = [(0.0, -260), (0.09, -260), (0.11, -100), (0.15, -60), (0.2, -20), (0.3, 0)].map { time, offset in
        SpaceWheelDrawnCapture.Frame(time: time, pixels: drawnPixels(source: 4, target: 3, pitch: 260, width: 244, offset: offset))
    }
    let verdict = SpaceWheelDrawnCapture.conditions(partial, switches: [step])
    #expect(verdict["first_frame_full_offset"] == false)
    #expect(verdict["landed"] == true)
    let complete = [(0.0, -260), (0.09, -260), (0.1, -250), (0.1167, -220), (0.1334, -190),
                    (0.15, -150), (0.1667, -110), (0.1834, -80), (0.2, -55), (0.2167, -30),
                    (0.2334, -15), (0.25, -5), (0.3, 0)].map { time, offset in
        SpaceWheelDrawnCapture.Frame(time: time, pixels: drawnPixels(source: 4, target: 3, pitch: 260, width: 244, offset: offset))
    }
    #expect(SpaceWheelDrawnCapture.conditions(complete, switches: [step]).values.allSatisfy { $0 })
}


@Test @MainActor
func drawnFrameLatencyRejectsALateContinuousStartIncludingItsStillFrames() {
    let step = SpaceWheelDrawnCapture.Switch(time: 0, source: 4, target: 3, pitch: 260)
    func curve(firstMotion: Double) -> [SpaceWheelDrawnCapture.Frame] {
        let offsets = [-250, -220, -190, -150, -110, -80, -55, -30, -15, -5, 0]
        let still = SpaceWheelDrawnCapture.Frame(time: 0, pixels: drawnPixels(source: 4, target: 3, pitch: 260, width: 244, offset: -260))
        return [still] + offsets.enumerated().map { index, offset in
            SpaceWheelDrawnCapture.Frame(time: firstMotion + Double(index) / 60,
                pixels: drawnPixels(source: 4, target: 3, pitch: 260, width: 244, offset: offset))
        }
    }
    let late = SpaceWheelDrawnCapture.conditions(curve(firstMotion: 0.1275), switches: [step])
    #expect(late.values.contains(false))
    #expect(late["first_motion_within_120ms"] == false)
    #expect(late.filter { $0.key != "first_motion_within_120ms" }.values.allSatisfy { $0 })
    #expect(SpaceWheelDrawnCapture.conditions(curve(firstMotion: 0.120), switches: [step]).values.allSatisfy { $0 })
    #expect(SpaceWheelDrawnCapture.conditions(curve(firstMotion: 0.100), switches: [step]).values.allSatisfy { $0 })
}

@Test
func drawnFrameTimesUseTheSamplesPresentationTimeInTheHostClock() throws {
    var buffer: CVPixelBuffer?
    #expect(CVPixelBufferCreate(nil, 8, 1, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
    let pixels = try #require(buffer)
    CVPixelBufferLockBaseAddress(pixels, [])
    if let base = CVPixelBufferGetBaseAddress(pixels) {
        base.initializeMemory(as: UInt8.self, repeating: 0, count: CVPixelBufferGetBytesPerRow(pixels))
    }
    CVPixelBufferUnlockBaseAddress(pixels, [])
    var description: CMVideoFormatDescription?
    #expect(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels, formatDescriptionOut: &description) == noErr)
    var timing = CMSampleTimingInfo(duration: .invalid,
        presentationTimeStamp: CMTime(value: 123456789, timescale: 1000000), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    #expect(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixels,
        formatDescription: try #require(description), sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
    let capture = SpaceWheelDrawnCapture(width: 8)
    capture.record(try #require(sample), clock: CMClockGetHostTimeClock())
    let frame = try #require(capture.samples().first)
    #expect(abs(frame.time - 123.456789) < 0.000001)
    #expect(abs(frame.time - SpaceWheelDrawnCapture.hostTime()) > 1)
}
