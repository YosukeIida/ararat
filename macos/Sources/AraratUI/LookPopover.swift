import AppKit
import AraratKit
import SwiftUI

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

@MainActor
final class LookPopoverAnchor: NSButton, NSPopoverDelegate {
    let settings: SettingsModel
    var space: SpaceSnapshot
    let popover = NSPopover()
    private(set) var editor: LookEditorModel?
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
        let colors = space.look?.colors.map { NSColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: 1) } ?? [.controlAccentColor]
        if colors.count > 1 { NSGradient(colors: colors)?.draw(in: ring.bounds, angle: -90) }
        else { colors[0].setFill(); ring.fill() }
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
        popover.contentViewController = NSHostingController(rootView: LookPopoverView(model: editor))
    }
    @objc private func openLook(_ sender: Any?) {
        if popover.isShown { popover.performClose(nil); return }
        preparePopover()
        popover.show(relativeTo: bounds, of: self, preferredEdge: .minX)
    }
    func popoverWillClose(_ notification: Notification) { editor?.dismiss() }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { popover.performClose(nil) }
        super.viewWillMove(toWindow: newWindow)
    }
}

struct LookPopoverView: View {
    @ObservedObject var model: LookEditorModel
    @State private var transparencyEditing = false
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
                    } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Look options")
                }.padding(.horizontal, 5)
            }
            HStack {
                Button { model.remove() } label: { Image(systemName: "minus") }.disabled(model.look.colors.count == 1).accessibilityLabel("Remove selected colour")
                Button { model.add() } label: { Image(systemName: "plus") }.disabled(model.look.colors.count == 3).accessibilityLabel("Add colour")
                Spacer()
                Text("\(model.look.colors.count) of 3 colours").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 3) {
                Button { model.presetPage = max(0, model.presetPage - 1) } label: { Image(systemName: "chevron.left") }.disabled(model.presetPage == 0).accessibilityLabel("Previous presets")
                ForEach(0..<9) { index in
                    let preset = model.presetPage * 9 + index
                    Button { model.preset(preset) } label: {
                        Circle().fill(LinearGradient(colors: LookEditorModel.presets[preset].map(Self.swatch), startPoint: .top, endPoint: .bottom))
                            .frame(width: 20, height: 20).overlay(Circle().strokeBorder(.primary.opacity(0.15)))
                    }.accessibilityLabel("\(model.presetPage == 0 ? "Solid colour" : "Gradient") preset \(index + 1)").accessibilityValue(model.look.colors == LookEditorModel.presets[preset] ? "Selected" : "Not selected")
                }
                Button { model.presetPage = min(1, model.presetPage + 1) } label: { Image(systemName: "chevron.right") }.disabled(model.presetPage == 1).accessibilityLabel("Next presets")
            }.buttonStyle(.plain)
            VStack(spacing: 3) {
                HStack {
                    Text("Transparency").font(.caption)
                    Spacer()
                    if transparencyEditing { Text(model.transparencyLabel).font(.caption).monospacedDigit() }
                }.frame(height: 16)
                HStack(spacing: 8) {
                    Slider(value: Binding(get: { model.transparency }, set: { model.setTransparency($0) }), in: 0...100, onEditingChanged: { editing in
                        transparencyEditing = editing
                        if editing { model.begin() } else { model.end() }
                    }).accessibilityLabel("Transparency").accessibilityValue("\(Int(model.transparency.rounded())) percent")
                    Button { model.toggleGlass() } label: {
                        Circle().fill(.ultraThinMaterial).frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(model.look.glass ? Color.accentColor : .secondary, lineWidth: model.look.glass ? 2 : 1))
                    }.buttonStyle(.plain).help("Glass").accessibilityLabel("Glass").accessibilityValue(model.look.glass ? "On" : "Off").accessibilityAddTraits(model.look.glass ? [.isSelected] : [])
                }
            }
            Slider(value: Binding(get: { model.look.grain }, set: { value in model.change { $0.grain = value } }), in: 0...1, onEditingChanged: { editing in
                if editing { model.begin() } else { model.end() }
            }) { Text("Grain").font(.caption) }.accessibilityLabel("Grain").accessibilityValue("\(Int((model.look.grain * 100).rounded())) percent")
            HStack { Button("Reset Look") { model.reset() }; Spacer() }.font(.caption)
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).accessibilityLabel("Look error: " + error) }
        }.padding(11).frame(width: 288).buttonStyle(.borderless)
    }
    private func mode(_ label: String, _ mode: Appearance, _ symbol: String) -> some View {
        Button { model.change { $0.appearance = mode } } label: {
            Label(label, systemImage: symbol).font(.caption).padding(.horizontal, 5).frame(height: 24)
                .background(model.look.appearance == mode ? Color.accentColor.opacity(0.25) : Color(nsColor: .windowBackgroundColor), in: Capsule())
        }.accessibilityLabel(label + " appearance").accessibilityValue(model.look.appearance == mode ? "Selected" : "Not selected")
    }
    static func swatch(_ color: LookColor) -> Color { Color(red: color.red, green: color.green, blue: color.blue) }
    private var field: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                let active = model.look.colors[model.selected]
                for row in 0...14 {
                    for column in 0...20 {
                        let x = Double(column) / 20, y = Double(row) / 14
                        let point = CGPoint(x: 15 + x * (size.width - 30), y: 15 + y * (size.height - 30))
                        let distance = hypot((x - active.x) * size.width, (y - active.y) * size.height)
                        let radius = 2 + max(0, 1 - distance / 48) * 3
                        context.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)), with: .color(Self.swatch(LookEditorModel.fieldColor(x: x, y: y))))
                    }
                }
            }.accessibilityHidden(true)
            ForEach(model.look.colors.indices, id: \.self) { index in
                let color = model.look.colors[index]
                Circle().fill(Self.swatch(color)).overlay(Circle().strokeBorder(.white, lineWidth: 3))
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
                    .frame(width: 30, height: 30)
                    .position(x: 15 + color.x * 236, y: 15 + LookEditorModel.fieldY(color.y) * 167)
                    .onTapGesture { model.selected = index }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("lookField")).onChanged { value in
                        model.moveHandle(index, dx: value.translation.width / 236, dy: value.translation.height / 167)
                    }.onEnded { _ in model.end() })
                    .accessibilityElement().accessibilityLabel("Colour handle \(index + 1)")
                    .accessibilityValue("Hue \(Int((color.x * 360).rounded())) degrees, lightness \(Int(((1 - color.y) * 100).rounded())) percent")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { model.selected = index }
                    .accessibilityAdjustableAction { direction in
                        let x = color.x + (direction == .increment ? 0.02 : -0.02)
                        model.change { $0.colors[index] = LookEditorModel.color(x: x, y: color.y) }
                    }
                    .accessibilityAction(named: "Lighter") { model.change { $0.colors[index] = LookEditorModel.color(x: color.x, y: color.y - 0.02) } }
                    .accessibilityAction(named: "Darker") { model.change { $0.colors[index] = LookEditorModel.color(x: color.x, y: color.y + 0.02) } }
            }
        }.coordinateSpace(name: "lookField").frame(width: 266, height: 197).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
}
