import AppKit

public enum SpaceAccent {
    public static let teal = NSColor(srgbRed: 47 / 255, green: 111 / 255, blue: 115 / 255, alpha: 1)
    public static let privateColor = NSColor(srgbRed: 110 / 255, green: 110 / 255, blue: 120 / 255, alpha: 1)

    public static func resolve(_ look: Look?, privateWindow: Bool = false, fallback: NSColor = teal) -> NSColor {
        if privateWindow { return privateColor }
        guard let color = look?.colors.first else { return fallback }
        return NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
    }

    public static func foreground(on accent: NSColor) -> NSColor {
        guard let rgb = accent.usingColorSpace(.sRGB) else { return .white }
        func linear(_ channel: CGFloat) -> CGFloat {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
        return luminance > 0.179 ? .black : .white
    }
}

extension WorkspaceSnapshot {
    public var shownLook: Look? { spaces.first { $0.id == shownSpaceId }?.look }
}
