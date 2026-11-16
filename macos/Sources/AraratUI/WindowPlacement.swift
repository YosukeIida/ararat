import AppKit

public enum WindowPlacement {
    public static func valid(_ frame: NSRect) -> Bool {
        [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite) && frame.width > 0 && frame.height > 0
    }

    public static func clamped(_ frame: NSRect, screens: [NSRect], main: NSRect?) -> NSRect {
        guard valid(frame) else { return frame }
        let intersecting = screens.filter { $0.intersects(frame) }.max { lhs, rhs in
            let left = lhs.intersection(frame), right = rhs.intersection(frame)
            return left.width * left.height < right.width * right.height
        }
        guard let screen = intersecting ?? main ?? screens.first else { return frame }
        let width = min(frame.width, screen.width), height = min(frame.height, screen.height)
        return NSRect(x: min(max(frame.minX, screen.minX), screen.maxX - width),
                      y: min(max(frame.minY, screen.minY), screen.maxY - height), width: width, height: height)
    }
}
