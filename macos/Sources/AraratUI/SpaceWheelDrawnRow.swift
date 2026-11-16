import AppKit

public enum SpaceWheelDrawnPattern {
    public static func white(space: Int, x: Int) -> Bool {
        var value = UInt32(truncatingIfNeeded: space + 1) &* 0x9e3779b9 ^ UInt32(x / 2) &* 0x85ebca6b
        value ^= value >> 16
        value = value &* 0x7feb352d
        value ^= value >> 15
        return value & 1 != 0
    }

    public static func offset(pixels: [UInt8], source: Int, target: Int, pitch: Int) -> Double? {
        let from = (target - source) * pitch
        var best: (offset: Int, error: Double)?
        for offset in min(0, from)...max(0, from) {
            var count = 0
            var errors = 0
            for x in pixels.indices {
                let incoming = x - offset
                let outgoing = x + from - offset
                let expected: Bool
                if pixels.indices.contains(incoming) { expected = white(space: target, x: incoming) }
                else if pixels.indices.contains(outgoing) { expected = white(space: source, x: outgoing) }
                else { continue }
                count += 1
                if (pixels[x] >= 128) != expected { errors += 1 }
            }
            guard count >= pixels.count * 3 / 4, count > 0 else { continue }
            let error = Double(errors) / Double(count)
            if best == nil || error < best!.error { best = (offset, error) }
        }
        guard let best, best.error < 0.12 else { return nil }
        return Double(best.offset)
    }
}

@MainActor
final class SpaceWheelDrawnRow: NSView {
    var space = 0 { didSet { needsDisplay = true } }
    private(set) var drawCount = 0
    private(set) var lastDrawnSpace: Int?
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        drawCount += 1
        lastDrawnSpace = space
        for x in stride(from: 0, to: Int(bounds.width), by: 2) {
            (SpaceWheelDrawnPattern.white(space: space, x: x) ? NSColor.white : NSColor.black).setFill()
            NSRect(x: CGFloat(x), y: 0, width: 2, height: bounds.height).fill()
        }
    }
}
