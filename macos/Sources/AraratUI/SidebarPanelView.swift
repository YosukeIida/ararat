import AppKit
import AraratKit

@MainActor
final class SidebarPanelView: NSView {
    static let defaultDarkBackground = NSColor(srgbRed: 22.0 / 255, green: 15.0 / 255, blue: 31.0 / 255, alpha: 1)
    let vibrancy = NSVisualEffectView()
    let coating = NSView()
    let gradient = CAGradientLayer()
    let grain = CALayer()
    private var glass: NSView?
    private var source: Look?
    private var destination: Look?
    private var fraction = 0.0
    private var drawnColors: [NSColor] = []
    var reduceTransparency: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
    var systemAppearance: () -> NSAppearance = { NSApp.effectiveAppearance }
    /// False while the window is not the active one: the space's colour and grain are dropped, the vibrancy and Glass stay.
    var active = true {
        didSet {
            guard active != oldValue else { return }
            renderLook()
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        vibrancy.material = .sidebar
        vibrancy.blendingMode = .behindWindow
        addSubview(vibrancy)
        coating.wantsLayer = true
        coating.layer?.addSublayer(gradient)
        coating.layer?.addSublayer(grain)
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        gradient.locations = [0, 0.5, 1]
        for layer in [gradient, grain] { layer.actions = ["bounds": NSNull(), "position": NSNull()] }
        updateGrainScale()
        addSubview(coating)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(accessibilityChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        updateLook(nil, nil, fraction: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit === coating || hit === vibrancy || hit === glass { return self }
        return hit
    }

    override func layout() {
        super.layout()
        vibrancy.frame = bounds
        glass?.frame = bounds
        coating.frame = bounds
        gradient.frame = coating.bounds
        grain.frame = coating.bounds
        if #available(macOS 26.0, *), let glass = glass as? NSGlassEffectView {
            glass.cornerRadius = layer?.cornerRadius ?? 0
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateGrainScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateGrainScale()
    }

    private func updateGrainScale() {
        let scale = window?.backingScaleFactor ?? 1
        grain.contentsScale = scale
        grain.backgroundColor = NSColor(patternImage: LookGrainTile.tile(pointSize: LookGrainTile.pointSize, scale: scale)).cgColor
    }

    func updateLook(_ source: Look?, _ destination: Look?, fraction: Double) {
        self.source = source
        self.destination = destination
        self.fraction = min(1, max(0, fraction))
        renderLook()
    }

    func setCheckReduceTransparency(_ reduced: Bool) {
        reduceTransparency = { reduced }
        renderLook()
    }

    /// The colour layer's first drawn colour, for the checks' wait conditions.
    var checkDrawnColor: NSColor? { coating.isHidden ? nil : drawnColors.first }

    @objc nonisolated private func accessibilityChanged() {
        Task { @MainActor [weak self] in self?.renderLook() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        renderLook()
    }

    private func renderLook() {
        let chosen = fraction < 0.5 ? source : destination
        let hasLook = (source != nil && fraction < 1) || (destination != nil && fraction > 0)
        let mode = chosen?.appearance ?? .auto
        let backgroundAppearance = mode == .auto ? systemAppearance() : NSAppearance(named: mode == .dark ? .darkAqua : .aqua)!
        let base = Self.windowColor(in: backgroundAppearance)
        let unthemed = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? Self.defaultDarkBackground : NSColor.clear
        let reduced = reduceTransparency()
        let colors = [0.0, 0.5, 1.0].map { position in
            Self.mix(source == nil ? unthemed : Self.sample(source, at: position),
                     destination == nil ? unthemed : Self.sample(destination, at: position),
                     fraction: fraction, base: nil)
        }
        drawnColors = colors
        let dark: Bool
        switch mode {
        case .dark: dark = true
        case .light: dark = false
        case .auto:
            let composed = Self.mix(source == nil ? unthemed : Self.average(source),
                                    destination == nil ? unthemed : Self.average(destination),
                                    fraction: fraction, base: base)
            dark = Self.usesLightText(composed)
        }
        // Why not force Auto's backdrop appearance: its vibrancy must keep following the system.
        vibrancy.appearance = mode == .auto ? nil : backgroundAppearance
        // While inactive the colour layer is hidden, so the text must follow the backdrop that is drawn (the
        // vibrancy's or Glass's appearance) rather than the Look's colour; for Auto that is the system's.
        let textAppearance = !hasLook ? nil : !active ? vibrancy.appearance : NSAppearance(named: dark ? .darkAqua : .aqua)
        for view in subviews where view !== vibrancy && view !== coating && view !== glass {
            if view.appearance != textAppearance { view.appearance = textAppearance }
        }
        let useGlass = chosen?.glass == true && !reduced
        if #available(macOS 26.0, *) {
            if useGlass && glass == nil {
                let effect = NSGlassEffectView()
                effect.style = .regular
                effect.contentView = NSView()
                addSubview(effect, positioned: .above, relativeTo: vibrancy)
                glass = effect
                needsLayout = true
            }
            glass?.isHidden = !useGlass
            glass?.appearance = mode == .auto ? nil : backgroundAppearance
            vibrancy.isHidden = useGlass
        } else { vibrancy.isHidden = false }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if colors.dropFirst().allSatisfy({ $0 == colors[0] }) {
            gradient.colors = nil
            gradient.backgroundColor = colors[0].cgColor
        } else {
            gradient.backgroundColor = nil
            gradient.colors = colors.map(\.cgColor)
        }
        grain.opacity = Float(((source?.grain ?? 0) * (1 - fraction) + (destination?.grain ?? 0) * fraction))
        coating.isHidden = hasLook ? !active : unthemed.alphaComponent == 0
        CATransaction.commit()
    }

    static func windowColor(in appearance: NSAppearance) -> NSColor {
        var color = NSColor.white
        appearance.performAsCurrentDrawingAppearance { color = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)! }
        return color
    }

    static func average(_ look: Look?) -> NSColor {
        mix(sample(look, at: 0.25), sample(look, at: 0.75), fraction: 0.5, base: nil)
    }

    static func sample(_ look: Look?, at position: Double) -> NSColor {
        guard let look, !look.colors.isEmpty else { return .clear }
        let location = min(1, max(0, position)) * Double(look.colors.count - 1)
        let index = min(look.colors.count - 1, Int(location))
        let next = min(look.colors.count - 1, index + 1)
        let t = location - Double(index)
        let a = look.colors[index], b = look.colors[next]
        return NSColor(srgbRed: a.red + (b.red - a.red) * t, green: a.green + (b.green - a.green) * t,
                       blue: a.blue + (b.blue - a.blue) * t, alpha: look.opacity)
    }

    static func mix(_ a: NSColor, _ b: NSColor, fraction: Double, base: NSColor?) -> NSColor {
        let a = a.usingColorSpace(.sRGB)!, b = b.usingColorSpace(.sRGB)!
        let alpha = a.alphaComponent * (1 - fraction) + b.alphaComponent * fraction
        let under = base?.usingColorSpace(.sRGB)
        let outputAlpha = under == nil ? alpha : 1
        func channel(_ av: CGFloat, _ bv: CGFloat, _ background: CGFloat) -> CGFloat {
            let value = av * a.alphaComponent * (1 - fraction) + bv * b.alphaComponent * fraction + background * (1 - alpha)
            return outputAlpha > 0 ? value / outputAlpha : 0
        }
        return NSColor(srgbRed: channel(a.redComponent, b.redComponent, under?.redComponent ?? 0),
                       green: channel(a.greenComponent, b.greenComponent, under?.greenComponent ?? 0),
                       blue: channel(a.blueComponent, b.blueComponent, under?.blueComponent ?? 0), alpha: outputAlpha)
    }

    static func usesLightText(_ color: NSColor) -> Bool {
        let c = color.usingColorSpace(.sRGB)!
        func linear(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent) < 0.179
    }
}
