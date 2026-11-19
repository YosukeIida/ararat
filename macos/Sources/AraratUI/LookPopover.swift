import AppKit
import AraratKit
import SwiftUI

enum LookFieldColors {
    /// Why not a fixed light value with the dark one: light keeps tracking the system control background.
    static let field = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 42 / 255, green: 42 / 255, blue: 42 / 255, alpha: 1)
            : NSColor.controlBackgroundColor
    }
}

struct LookPopoverButton: NSViewRepresentable {
    let settings: SettingsModel
    let space: SpaceSnapshot
    func makeNSView(context: Context) -> LookPopoverAnchor { LookPopoverAnchor(settings: settings, space: space) }
    func updateNSView(_ button: LookPopoverAnchor, context: Context) {
        if button.space.id != space.id { button.popover.performClose(nil) }
        button.space = space
        button.needsDisplay = true
    }
}

/// The popover opens on this view, not on a control: Arc shows no focus ring when the popover
/// appears. Being first responder, Tab hands the key to SwiftUI's own focus walk, which is where
/// the popover's controls are.
@MainActor
final class LookPopoverFocusCatcher: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.initialFirstResponder = self
        window.makeFirstResponder(self)
    }
    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 48, let host = superview else { return super.keyDown(with: event) }
        window?.makeFirstResponder(host)
        host.keyDown(with: event)
    }
}

@MainActor
final class LookPopoverAnchor: NSButton, NSPopoverDelegate {
    let settings: SettingsModel
    var space: SpaceSnapshot
    let popover = NSPopover()
    private(set) var editor: LookEditorModel?
    private(set) var focusCatcher: LookPopoverFocusCatcher?
    init(settings: SettingsModel, space: SpaceSnapshot) {
        self.settings = settings
        self.space = space
        super.init(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
        isBordered = false
        title = ""
        target = self
        action = #selector(openLook(_:))
        setAccessibilityLabel("Edit space look")
        toolTip = "Edit space look"
        popover.behavior = .transient
        popover.delegate = self
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func draw(_ dirtyRect: NSRect) {
        let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 3, dy: 3))
        NSGraphicsContext.saveGraphicsState()
        ring.addClip()
        let colors = space.look?.colors.map { NSColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: 1) } ?? []
        if colors.count > 1 { NSGradient(colors: colors)?.draw(in: ring.bounds, angle: -90) }
        else { SpaceAccent.resolve(space.look).setFill(); ring.fill() }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        ring.lineWidth = 1
        ring.stroke()
        if window?.firstResponder === self { NSFocusRingPlacement.only.set(); ring.fill() }
    }
    func preparePopover() {
        let space = settings.snapshot.spaces.first { $0.id == self.space.id } ?? space
        let editor = LookEditorModel(settings: settings, space: space)
        self.editor = editor
        let host = NSHostingController(rootView: LookPopoverView(model: editor))
        let catcher = LookPopoverFocusCatcher(frame: .zero)
        host.view.addSubview(catcher)
        focusCatcher = catcher
        popover.contentViewController = host
    }
    @objc private func openLook(_ sender: Any?) {
        if popover.isShown { popover.performClose(nil); return }
        preparePopover()
        popover.show(relativeTo: bounds, of: self, preferredEdge: .minX)
    }
    func popoverWillClose(_ notification: Notification) { editor?.dismiss() }
    func popoverDidShow(_ notification: Notification) {
        guard let catcher = focusCatcher, let window = catcher.window else { return }
        window.initialFirstResponder = catcher
        if window.firstResponder !== catcher { window.makeFirstResponder(catcher) }
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { popover.performClose(nil) }
        super.viewWillMove(toWindow: newWindow)
    }
}

struct LookPopoverView: View {
    /// The popover content's designed width; the space-name check asserts the popped-up
    /// content matches it (and that the open animation has finished).
    static let width: CGFloat = 288
    static let contentPadding: CGFloat = 11
    @ObservedObject var model: LookEditorModel
    @State private var dragging: Int?
    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .top) {
                field.padding(.top, 12)
                HStack(spacing: 4) {
                    mode("Auto", .auto, "sparkles")
                    mode("Light", .light, "sun.max")
                    mode("Dark", .dark, "moon")
                    Spacer(minLength: 0)
                    Menu {
                        Button("Use for All Spaces") { model.useForAll() }
                        Button("Reset Look") { model.reset() }
                    } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                    .menuStyle(.borderlessButton).fixedSize().background(LookTrackProbe(model: model, target: .menu)).accessibilityLabel("Look options")
                }.padding(.horizontal, 5)
            }
            HStack {
                Button { model.remove() } label: { Image(systemName: "minus") }.disabled(model.look.colors.count == 1).accessibilityLabel("Remove selected colour")
                Button { model.add() } label: { Image(systemName: "plus") }.disabled(model.look.colors.count == 3).accessibilityLabel("Add colour")
                Spacer()
                Text("\(model.look.colors.count) of 3 colours").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 3) {
                Button { model.chipPage = max(0, model.chipPage - 1) } label: { Image(systemName: "chevron.left") }.disabled(model.chipPage == 0).accessibilityLabel("Previous presets")
                ForEach(0..<9) { index in
                    let chip = LookEditorModel.chipPages[model.chipPage][index]
                    Button { model.applyChip(page: model.chipPage, index: index) } label: {
                        Circle().fill(LinearGradient(colors: LookEditorModel.chipSwatch(model.chipPage, chip).map(Self.swatch),
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 20, height: 20).overlay(Circle().strokeBorder(.primary.opacity(0.15)))
                    }.accessibilityLabel("\(model.chipPage == 0 ? "Split" : "Analogous") preset \(index + 1)")
                        .accessibilityValue(model.isChipApplied(chip) ? "Selected" : "Not selected")
                }
                Button { model.chipPage = min(1, model.chipPage + 1) } label: { Image(systemName: "chevron.right") }.disabled(model.chipPage == 1).accessibilityLabel("Next presets")
            }.buttonStyle(.plain)
            TransparencyControl(model: model)
            GrainControl(model: model)
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).accessibilityLabel("Look error: " + error) }
        }.padding(11).frame(width: Self.width).buttonStyle(.borderless)
    }
    private func mode(_ label: String, _ mode: Appearance, _ symbol: String) -> some View {
        Button { model.change { $0.appearance = mode } } label: {
            Label(label, systemImage: symbol).font(.caption).padding(.horizontal, 5).frame(height: 24)
                .background(model.look.appearance == mode ? Color.accentColor.opacity(0.25) : Color(nsColor: .windowBackgroundColor), in: Capsule())
        }.accessibilityLabel(label + " appearance").accessibilityValue(model.look.appearance == mode ? "Selected" : "Not selected")
    }
    static func swatch(_ color: LookColor) -> Color { Color(red: color.red, green: color.green, blue: color.blue) }
    /// The polar field: hue around the circle, lightness along the radius (white at the rim, black at
    /// the centre, the mock's ramp), dots on an 8 pt lattice inside the 116 pt inscribed circle, one spoke
    /// and one handle per colour. The handles share one radius and turn together.
    private var field: some View {
        ZStack {
            Canvas { context, size in
                let centre = LookEditorModel.fieldCentre
                var spokes = Path()
                for color in model.look.colors {
                    spokes.move(to: centre)
                    spokes.addLine(to: LookEditorModel.fieldPoint(x: color.x, y: LookEditorModel.fieldY(color.y)))
                }
                context.stroke(spokes, with: .color(.primary.opacity(0.3)), lineWidth: 1)
                let half = LookEditorModel.fieldDotSize / 2
                for point in LookEditorModel.dotCentres() {
                    let position = LookEditorModel.fieldPosition(point)
                    context.fill(Path(ellipseIn: CGRect(x: point.x - half, y: point.y - half,
                                                        width: LookEditorModel.fieldDotSize, height: LookEditorModel.fieldDotSize)),
                                 with: .color(Self.swatch(LookEditorModel.fieldColor(x: position.x, y: position.y))))
                }
            }.accessibilityHidden(true)
            ForEach(model.look.colors.indices, id: \.self) { index in
                let color = model.look.colors[index]
                let big = dragging == index
                Circle().fill(Self.swatch(color)).overlay(Circle().strokeBorder(.white, lineWidth: big ? 3 : 2))
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
                    .frame(width: big ? 32 : 24, height: big ? 32 : 24)
                    .position(LookEditorModel.fieldPoint(x: color.x, y: LookEditorModel.fieldY(color.y)))
                    .onTapGesture { model.selected = index }
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("lookField")).onChanged { value in
                        dragging = index
                        model.movePoint(index, translatedBy: value.translation)
                    }.onEnded { _ in dragging = nil; model.end() })
                    .accessibilityElement()
                    .accessibilityLabel(LookEditorModel.handleLabel(index: index, count: model.look.colors.count))
                    .accessibilityValue(LookEditorModel.handleValue(color))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { model.selected = index }
                    .accessibilityAdjustableAction { direction in
                        model.selected = index
                        model.turnColours(by: direction == .increment ? LookEditorModel.hueKeyStep : -LookEditorModel.hueKeyStep)
                    }
                    .accessibilityAction(named: "Lighter") { model.selected = index; model.stepRadius(LookEditorModel.radiusKeyStep) }
                    .accessibilityAction(named: "Darker") { model.selected = index; model.stepRadius(-LookEditorModel.radiusKeyStep) }
                    .focusable()
                    .onMoveCommand { direction in
                        model.selected = index
                        if direction == .right { model.turnColours(by: LookEditorModel.hueKeyStep) }
                        if direction == .left { model.turnColours(by: -LookEditorModel.hueKeyStep) }
                        if direction == .up { model.stepRadius(LookEditorModel.radiusKeyStep) }
                        if direction == .down { model.stepRadius(-LookEditorModel.radiusKeyStep) }
                    }
            }
        }.coordinateSpace(name: "lookField").frame(width: LookEditorModel.fieldCanvasSize.width, height: LookEditorModel.fieldCanvasSize.height)
            .background(LookFieldProbe(model: model))
            .background(Color(nsColor: LookFieldColors.field), in: RoundedRectangle(cornerRadius: 8))
    }
}

@MainActor
struct TransparencyInteraction {
    var detent = false
    var previousPosition: Double?
    var haptic: () -> Void = { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    mutating func drag(_ position: Double, model: LookEditorModel) {
        model.begin()
        let canSnap = model.look.glass || (previousPosition.map { $0 >= 1 && $0 != position } ?? (model.transparency >= 100))
        let glass = position > 1.06 && canSnap
        detent = position > 1 && !glass
        previousPosition = position
        if glass && !model.look.glass { haptic() }
        model.setTransparency(min(100, max(0, position * 100)), glass: glass)
    }
    func label(_ model: LookEditorModel) -> String {
        if model.look.glass { return "Liquid Glass" }
        return detent ? "100% · Liquid Glass ›" : model.transparencyLabel
    }
    static func adjust(_ direction: AccessibilityAdjustmentDirection, model: LookEditorModel) {
        switch direction {
        case .increment:
            if !model.look.glass { model.setTransparency(model.transparency.rounded() + 1, glass: model.transparency.rounded() >= 100) }
        case .decrement:
            if model.look.glass { model.setTransparency(100) }
            else { model.setTransparency(model.transparency.rounded() - 1) }
        @unknown default: break
        }
    }
}

struct TransparencyControl: View {
    @ObservedObject var model: LookEditorModel
    @FocusState private var keyboardFocused: Bool
    @State private var interaction = TransparencyInteraction()
    @State private var dragging = false
    var body: some View {
        VStack(spacing: 3) {
            HStack {
                Text("Transparency").font(.caption)
                Spacer()
                if dragging { Text(model.checkTransparencyTag ?? interaction.label(model)).font(.caption).monospacedDigit() }
            }.frame(height: 16)
            GeometryReader { geometry in
                let width = max(1, geometry.size.width - 32)
                let thumb = model.look.glass ? width + 24 : width * model.transparency / 100
                ZStack(alignment: .leading) {
                    Canvas { context, size in
                        var path = Path()
                        let amplitude = model.look.glass ? 0 : 4 * (1 - model.transparency / 100)
                        path.move(to: CGPoint(x: 0, y: size.height / 2))
                        let segments = 12
                        for i in 0..<segments {
                            let x = width * CGFloat(i) / CGFloat(segments)
                            let next = width * CGFloat(i + 1) / CGFloat(segments)
                            let y = size.height / 2
                            let sign: CGFloat = i.isMultiple(of: 2) ? 1 : -1
                            path.addCurve(to: CGPoint(x: next, y: y), control1: CGPoint(x: x + (next-x)/3, y: y + amplitude * sign), control2: CGPoint(x: x + 2*(next-x)/3, y: y + amplitude * sign))
                        }
                        context.stroke(path, with: .color(.secondary), lineWidth: 2)
                    }.frame(width: width).accessibilityHidden(true)
                    Circle().fill(.ultraThinMaterial).overlay(Circle().strokeBorder(interaction.detent || model.look.glass ? Color.accentColor : .secondary, lineWidth: 2))
                        .frame(width: 20, height: 20).offset(x: width + 14)
                    Circle().fill(Color.primary).frame(width: 12, height: 12).offset(x: thumb - 6)
                }.frame(width: geometry.size.width, height: 30, alignment: .leading)
                    .background(LookTrackProbe(model: model, target: .transparency, focus: { keyboardFocused = true }, focused: { keyboardFocused })).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        dragging = true
                        interaction.haptic = model.alignmentHaptic
                        interaction.drag(value.location.x / width, model: model)
                        model.checkTransparencyTag = interaction.label(model)
                    }.onEnded { _ in dragging = false; model.checkTransparencyTag = nil; interaction.detent = false; interaction.previousPosition = nil; model.end() })
            }.frame(height: 30)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel("Transparency")
        .accessibilityValue(model.look.glass ? "Liquid Glass" : "\(Int(model.transparency.rounded())) percent")
        .accessibilityAdjustableAction { TransparencyInteraction.adjust($0, model: model) }
        .focusable().focused($keyboardFocused).onMoveCommand { direction in
            if direction == .right || direction == .up { TransparencyInteraction.adjust(.increment, model: model) }
            if direction == .left || direction == .down { TransparencyInteraction.adjust(.decrement, model: model) }
        }
    }
}

@MainActor
struct GrainInteraction {
    static func adjust(_ amount: Double, model: LookEditorModel) {
        model.change { $0.grain = min(1, max(0, (amount > 0 ? floor($0.grain * 20 + 1e-9) + 1 : ceil($0.grain * 20 - 1e-9) - 1) / 20)) }
    }
    var previous: Double?
    var continuous = 0.0
    mutating func drag(_ value: Double?, model: LookEditorModel) {
        guard let value else { return }
        model.begin()
        defer { previous = value }
        guard let previous else { continuous = model.look.grain; return }
        var delta = value - previous
        if delta > 0.5 { delta -= 1 }
        if delta < -0.5 { delta += 1 }
        guard delta != 0 else { return }
        continuous = min(1, max(0, continuous + delta))
        let grain = (continuous * 20).rounded() / 20
        if grain != model.look.grain { model.change { $0.grain = grain } }
    }
    static func value(at point: CGPoint, size: CGSize) -> Double? {
        let dx = point.x - size.width / 2, dy = size.height / 2 - point.y
        guard hypot(dx, dy) >= 6 else { return nil }
        let angle = atan2(dx, dy)
        return (angle < 0 ? angle + 2 * .pi : angle) / (2 * .pi)
    }
}

struct LookTrackProbe: NSViewRepresentable {
    enum Target { case transparency, grain, menu }
    let model: LookEditorModel
    var target: Target = .transparency
    var focus: (() -> Void)?
    var focused: (() -> Bool)?
    func makeNSView(context: Context) -> LookTrackProbeView {
        let view = LookTrackProbeView()
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ view: LookTrackProbeView, context: Context) {
        view.focus = focus
        view.focused = focused
        switch target {
        case .transparency: model.checkTrackView = view
        case .grain: model.checkGrainView = view
        case .menu: model.checkMenuView = view
        }
    }
}

/// The polar field's frame, so a check can aim at a handle without the accessibility tree.
struct LookFieldProbe: NSViewRepresentable {
    let model: LookEditorModel
    func makeNSView(context: Context) -> LookTrackProbeView {
        let view = LookTrackProbeView()
        model.checkFieldView = view
        return view
    }
    func updateNSView(_ view: LookTrackProbeView, context: Context) { model.checkFieldView = view }
}

final class LookTrackProbeView: NSView {
    var focus: (() -> Void)?
    var focused: (() -> Bool)?
    var controlHasFocus: Bool {
        guard let responder = window?.firstResponder else { return false }
        return !(responder is LookTrackProbeView) && focused?() == true
    }
    func requestControlFocus() -> Bool {
        guard window != nil, let focus else { return false }
        focus()
        return true
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
}

struct GrainControl: View {
    @ObservedObject var model: LookEditorModel
    @FocusState private var keyboardFocused: Bool
    @State private var interaction = GrainInteraction()
    var body: some View {
        HStack {
            GeometryReader { geometry in
                ZStack {
                    Circle().stroke(.secondary.opacity(0.4), lineWidth: 2)
                    Circle().fill(Color(nsColor: .controlBackgroundColor)).padding(5)
                    Circle().fill(Color.primary).frame(width: 4, height: 4)
                        .offset(y: -12).rotationEffect(.degrees(model.look.grain * 360))
                }.contentShape(Circle()).gesture(DragGesture(minimumDistance: 0).onChanged { event in
                    interaction.drag(GrainInteraction.value(at: event.location, size: geometry.size), model: model)
                }.onEnded { _ in interaction.previous = nil; model.end() })
            }.frame(width: 36, height: 36).background(LookTrackProbe(model: model, target: .grain, focus: { keyboardFocused = true }, focused: { keyboardFocused }))
            Text("Grain \(Int((model.look.grain * 100).rounded()))%").font(.caption)
            Spacer()
        }.accessibilityElement(children: .ignore).accessibilityLabel("Grain")
            .accessibilityValue("\(Int((model.look.grain * 100).rounded())) percent")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: GrainInteraction.adjust(1, model: model)
                case .decrement: GrainInteraction.adjust(-1, model: model)
                @unknown default: break
                }
            }.focusable().focused($keyboardFocused).onMoveCommand { direction in
                if direction == .right || direction == .up { GrainInteraction.adjust(1, model: model) }
                if direction == .left || direction == .down { GrainInteraction.adjust(-1, model: model) }
            }
    }
}

@MainActor
public final class LookCheckProbe {
    private let popover: NSPopover
    var popoverForCheck: NSPopover { popover }
    private let model: () -> LookEditorModel?
    public private(set) var haptics = 0

    init(_ anchor: LookPopoverAnchor) {
        popover = anchor.popover
        model = { [weak anchor] in anchor?.editor }
        if !anchor.popover.isShown { anchor.performClick(nil) }
        model()?.alignmentHaptic = { [weak self] in self?.haptics += 1 }
    }

    // D13: the sidebar hosts its own popover anchored to the space name row; the check reads
    // the same views through it.
    init(popover: NSPopover, editor: @escaping () -> LookEditorModel?) {
        self.popover = popover
        model = editor
        model()?.alignmentHaptic = { [weak self] in self?.haptics += 1 }
    }

    public var window: NSWindow? { popover.contentViewController?.view.window }
    /// The popover content's size, so a check can tell a finished popover from one that is
    /// still in its open animation (the size it settles at is the designed one).
    public var contentSize: NSSize? { popover.contentViewController?.view.frame.size }
    public static let designedContentWidth: CGFloat = LookPopoverView.width
    public var look: Look? { model()?.look }
    public var editing: Bool { model()?.editing == true }
    public var transparencyTag: String? { model()?.checkTransparencyTag }
    private func frame(_ view: NSView?) -> NSRect? {
        guard let view, let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
    public var trackFrame: NSRect? { frame(model()?.checkTrackView) }
    public var menuFrame: NSRect? { frame(model()?.checkMenuView) }
    public var fieldFrame: NSRect? { frame(model()?.checkFieldView) }
    /// The screen point of a stored colour's handle centre.
    public func fieldPoint(x: Double, y: Double) -> NSPoint? {
        guard let frame = fieldFrame else { return nil }
        let point = LookEditorModel.fieldPoint(x: x, y: LookEditorModel.fieldY(y))
        return NSPoint(x: frame.minX + point.x, y: frame.maxY - point.y)
    }
    /// The screen point of a hue at a handle radius in points (0 at the centre, the maximum at the rim).
    public func fieldPoint(hue: Double, radius: Double) -> NSPoint? {
        fieldPoint(x: hue, y: LookCheckProbe.storedY(radius: radius))
    }
    public static func storedY(radius: Double) -> Double { LookEditorModel.storedY(radius: radius) }
    public static func colour(x: Double, y: Double) -> LookColor { LookEditorModel.color(x: x, y: y) }
    private func focusView(_ label: String) -> LookTrackProbeView? {
        (label == "Transparency" ? model()?.checkTrackView : model()?.checkGrainView) as? LookTrackProbeView
    }
    public func focus(_ label: String) -> Bool {
        focusView(label)?.requestControlFocus() == true
    }
    public func hasFocus(_ label: String) -> Bool { focusView(label)?.controlHasFocus == true }
    /// Sets the whole look through the editor's own commit path, for a check that needs a fixed
    /// probe (the grain measurement) rather than a gesture.
    public func setLook(_ edit: (inout Look) -> Void) {
        model()?.end()
        model()?.change(edit)
    }
}

extension SettingsWindowController {
    public func openLookForCheck() -> LookCheckProbe? {
        guard let root = window?.contentView else { return nil }
        root.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> LookPopoverAnchor? {
            if let anchor = view as? LookPopoverAnchor { return anchor }
            for child in view.subviews { if let anchor = find(child) { return anchor } }
            return nil
        }
        guard let anchor = find(root), anchor.window != nil else { return nil }
        return LookCheckProbe(anchor)
    }
}

extension LookCheckProbe {
    /// Closes the popover a check opened.
    public func closePopover() { popoverForCheck.performClose(nil) }
}
