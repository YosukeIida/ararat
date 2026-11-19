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
        return luminance(rgb) > 0.179 ? .black : .white
    }

    public static func visible(_ accent: NSColor, on backdrop: NSColor) -> NSColor {
        let fallback = foreground(on: backdrop)
        guard let rgb = accent.usingColorSpace(.sRGB), let base = backdrop.usingColorSpace(.sRGB) else { return fallback }
        let target: CGFloat = fallback == .black ? 0 : 1
        let background = luminance(base) + 0.05
        let alpha = rgb.alphaComponent

        func color(towardTarget fraction: CGFloat) -> NSColor {
            NSColor(srgbRed: rgb.redComponent + (target - rgb.redComponent) * fraction,
                    green: rgb.greenComponent + (target - rgb.greenComponent) * fraction,
                    blue: rgb.blueComponent + (target - rgb.blueComponent) * fraction, alpha: alpha)
        }

        func hasContrast(_ color: NSColor) -> Bool {
            let rendered = NSColor(srgbRed: color.redComponent * alpha + base.redComponent * (1 - alpha),
                                   green: color.greenComponent * alpha + base.greenComponent * (1 - alpha),
                                   blue: color.blueComponent * alpha + base.blueComponent * (1 - alpha), alpha: 1)
            let foreground = luminance(rendered) + 0.05
            return max(foreground, background) / min(foreground, background) >= 3
        }

        if hasContrast(rgb) { return accent }
        guard hasContrast(color(towardTarget: 1)) else { return fallback }
        var lower: CGFloat = 0
        var upper: CGFloat = 1
        for _ in 0..<12 {
            let middle = (lower + upper) / 2
            if hasContrast(color(towardTarget: middle)) { upper = middle }
            else { lower = middle }
        }
        return color(towardTarget: upper)
    }

    private static func luminance(_ rgb: NSColor) -> CGFloat {
        func linear(_ channel: CGFloat) -> CGFloat {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
    }
}

extension WorkspaceSnapshot {
    public var shownLook: Look? { spaces.first { $0.id == shownSpaceId }?.look }
}
