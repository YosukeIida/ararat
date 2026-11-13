import AppKit
import AraratKit
import SwiftUI

@MainActor
final class LookEditorModel: ObservableObject {
    @Published private(set) var look: Look
    @Published var selected = 0
    @Published var presetPage = 0
    @Published private(set) var editing = false
    @Published private(set) var error: String?
    weak var checkTrackView: NSView?
    weak var checkGrainView: NSView?
    weak var checkMenuView: NSView?
    weak var checkFieldView: NSView?
    var checkTransparencyTag: String?
    var alignmentHaptic: () -> Void = { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    let settings: SettingsModel
    let spaceID: String
    private let contextGeneration: Int
    private let previewOwner = UUID()
    private var saved: Look?
    private var gestureStart: Look?
    private var revision = 0
    private var pendingReplies = 0

    init(settings: SettingsModel, space: SpaceSnapshot) {
        self.settings = settings
        contextGeneration = settings.contextGeneration
        spaceID = space.id
        saved = space.look
        look = space.look ?? Self.defaultLook
    }

    static let defaultLook = Look(colors: [color(x: 0.6, y: 0.5)], opacity: 0.45, grain: 0.05, glass: false, appearance: .auto)
    static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
    static func wrapped(_ value: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: 1)
        return remainder < 0 ? remainder + 1 : remainder
    }
    static func color(x: Double, y: Double) -> LookColor {
        let hue = clamp(x), lightness = 1 - clamp(y), saturation = 0.65
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let section = hue * 6
        let secondary = chroma * (1 - abs(section.truncatingRemainder(dividingBy: 2) - 1))
        let components: (Double, Double, Double)
        switch section {
        case ..<1: components = (chroma, secondary, 0)
        case ..<2: components = (secondary, chroma, 0)
        case ..<3: components = (0, chroma, secondary)
        case ..<4: components = (0, secondary, chroma)
        case ..<5: components = (secondary, 0, chroma)
        default: components = (chroma, 0, secondary)
        }
        let offset = lightness - chroma / 2
        return LookColor(red: components.0 + offset, green: components.1 + offset, blue: components.2 + offset, x: hue, y: clamp(y))
    }
    /// The field's radial coordinate for a stored y: 0 at the rim, 1 at the centre. Stored y keeps
    /// Arc's sense (0.05 white, 0.95 black), so lightness grows along the radius as the mock draws it.
    static func fieldY(_ y: Double) -> Double { clamp((y - 0.05) / 0.9) }
    /// The field's colour: `x` is a hue that wraps (a turn past red continues at 0), `y` the radial
    /// coordinate (0 rim, 1 centre).
    static func fieldColor(x: Double, y: Double) -> LookColor { color(x: wrapped(x), y: 0.05 + 0.9 * clamp(y)) }
    static let fieldCanvasSize = CGSize(width: 264, height: 232)
    /// The furthest a handle sits from the centre; the dots reach the inscribed circle (116 pt) a
    /// little further, as the mock's do (RMAX 141 of R1 150, at this field's scale).
    static let fieldMaxRadius: CGFloat = 108
    static var fieldCentre: CGPoint { CGPoint(x: fieldCanvasSize.width / 2, y: fieldCanvasSize.height / 2) }
    /// The radial field coordinate of a handle radius in points.
    static func fieldY(radius: Double) -> Double { 1 - clamp(radius / Double(fieldMaxRadius)) }
    /// The stored y of a handle radius; the inverse of `radius(of:)`.
    static func storedY(radius: Double) -> Double { 0.05 + 0.9 * fieldY(radius: radius) }
    /// A colour's handle radius in points.
    static func radius(of y: Double) -> Double { (1 - fieldY(y)) * Double(fieldMaxRadius) }
    /// Where a hue (across the circle) and a radial field coordinate (0 rim, 1 centre) sit in the field.
    static func fieldPoint(x: Double, y: Double) -> CGPoint {
        let radius = CGFloat(1 - clamp(y)) * fieldMaxRadius
        let angle = 2 * Double.pi * x
        let centre = fieldCentre
        return CGPoint(x: centre.x + radius * CGFloat(cos(angle)), y: centre.y + radius * CGFloat(sin(angle)))
    }
    /// The hue and radial coordinate of a point in the field, the inverse of `fieldPoint`: a point
    /// past the rim keeps its hue at the rim's radius.
    static func fieldPosition(_ point: CGPoint) -> (x: Double, y: Double) {
        let centre = fieldCentre
        let dx = Double(point.x - centre.x), dy = Double(point.y - centre.y)
        let distance = min(hypot(dx, dy), Double(fieldMaxRadius))
        let hue = dx == 0 && dy == 0 ? 0 : wrapped(atan2(dy, dx) / (2 * .pi))
        return (hue, 1 - distance / Double(fieldMaxRadius))
    }
    // The one harmony the code has: + adds a handle a third of the hue wheel on, on the group's radius.
    static let addStep = 1.0 / 3
    // The picker's steps: 5 degrees per arrow key and 6 pt of radius (a twentieth of a turn and a
    // twentieth of the radius), as the mock's keyboard moves them.
    static let hueKeyStep = 5.0 / 360
    static let radiusKeyStep: Double = 6
    static func transparency(opacity: Double) -> Double { (1 - clamp(opacity)) * 100 }
    static func opacity(transparency: Double) -> Double { 1 - clamp(transparency / 100) }
    var transparency: Double { Self.transparency(opacity: look.opacity) }
    var transparencyLabel: String { "Transparency \(Int(transparency.rounded()))%" }
    static let presets: [[LookColor]] = (0..<9).map { [color(x: Double($0) / 9, y: 0.5)] }
        + (0..<9).map { [color(x: Double($0) / 9, y: 0.5), color(x: wrapped((Double($0) + 1) / 9), y: 0.5)] }
    static func handleLabel(index: Int, count: Int) -> String { "Colour \(index + 1) of \(count)" }
    static func handleValue(_ color: LookColor) -> String {
        let hue = Int((wrapped(color.x) * 360).rounded()) % 360
        let lightness = Int(((1 - color.y) * 100).rounded())
        return "Hue \(hue) degrees, lightness \(lightness) percent"
    }

    func begin() {
        guard !editing else { return }
        gestureStart = look
        editing = true
    }
    func change(_ edit: (inout Look) -> Void) {
        var updated = look
        edit(&updated)
        guard updated != look else { return }
        look = updated
        preview(look, active: editing)
        if !editing { commit() }
    }
    /// A drag of one handle. The handle follows the pointer by the gesture's translation from where it
    /// was grabbed, so a press that does not move changes nothing (the tap selects it instead); the
    /// whole group turns by the same angle and takes the dragged handle's radius, so the one to three
    /// handles always share one radius and turn together (the approved F-LookStates behaviour). Edits
    /// are based on the gesture's start, so repeated drag events do not accumulate.
    func movePoint(_ index: Int, translatedBy translation: CGSize) {
        guard look.colors.indices.contains(index) else { return }
        if gestureStart == nil {
            selected = index
            let grip = Self.fieldPoint(x: look.colors[index].x, y: Self.fieldY(look.colors[index].y))
            let position = Self.fieldPosition(CGPoint(x: grip.x + translation.width, y: grip.y + translation.height))
            guard abs(position.x - look.colors[index].x) > 0.000000001
                || abs(position.y - Self.fieldY(look.colors[index].y)) > 0.000000001
            else { return }
            begin()
        }
        selected = index
        guard let start = gestureStart, start.colors.indices.contains(index) else { return }
        let base = start.colors[index]
        let grip = Self.fieldPoint(x: base.x, y: Self.fieldY(base.y))
        var position = Self.fieldPosition(CGPoint(x: grip.x + translation.width, y: grip.y + translation.height))
        // A drag that ends where it was grabbed restores the start exactly, so it writes nothing.
        let baseY = Self.fieldY(base.y)
        if abs(position.x - base.x) < 0.000000001 && abs(position.y - baseY) < 0.000000001 { position = (base.x, baseY) }
        let delta = position.x - base.x
        let radius = Self.clamp(position.y)
        let hues = start.colors.map(\.x)
        change { look in
            for i in look.colors.indices {
                let hue = i < hues.count ? hues[i] + delta : look.colors[i].x
                look.colors[i] = Self.fieldColor(x: hue, y: radius)
            }
        }
    }
    /// Turns every handle by the same step (the keyboard and VoiceOver hue adjustment).
    func turnColours(by delta: Double) {
        change { look in
            for i in look.colors.indices { look.colors[i] = Self.fieldColor(x: look.colors[i].x + delta, y: Self.fieldY(look.colors[i].y)) }
        }
    }
    /// Moves every handle to one radial field coordinate (0 rim, 1 centre), the group's shared radius.
    func setSharedRadius(_ fieldY: Double) {
        change { look in
            for i in look.colors.indices { look.colors[i] = Self.fieldColor(x: look.colors[i].x, y: fieldY) }
        }
    }
    func stepRadius(_ delta: Double) {
        guard look.colors.indices.contains(selected) else { return }
        let radius = Self.radius(of: look.colors[selected].y) + delta
        setSharedRadius(Self.fieldY(radius: radius))
    }
    func end() {
        guard editing else { return }
        let changed = gestureStart != look
        editing = false
        gestureStart = nil
        if changed { commit() }
        else { preview(saved, active: pendingReplies > 0) }
    }
    func dismiss() {
        editing = false
        gestureStart = nil
        look = saved ?? Self.defaultLook
        selected = min(selected, look.colors.count - 1)
        preview(saved, active: pendingReplies > 0)
    }
    func add() {
        guard look.colors.count < 3 else { return }
        let base = look.colors[selected]
        let hue = Self.wrapped(base.x + Self.addStep)
        change { $0.colors.append(Self.color(x: hue, y: base.y)) }
        selected = look.colors.count - 1
    }
    func remove() {
        guard look.colors.count > 1 else { return }
        let index = selected
        selected = max(0, selected - 1)
        change { $0.colors.remove(at: index) }
    }
    func preset(_ index: Int) {
        guard Self.presets.indices.contains(index) else { return }
        selected = 0
        change { $0.colors = Self.presets[index] }
    }
    func setTransparency(_ value: Double, glass: Bool = false) {
        change { $0.opacity = glass ? 0 : Self.opacity(transparency: value); $0.glass = glass }
    }
    func reset() {
        editing = false
        gestureStart = nil
        write(nil, ids: [spaceID])
    }
    func useForAll() {
        editing = false
        gestureStart = nil
        write(look, ids: settings.snapshot.spaces.map(\.id))
    }
    private func commit() { write(look, ids: [spaceID]) }
    private func preview(_ look: Look?, active: Bool) {
        settings.previewLook(id: spaceID, look: look, active: active, owner: previewOwner, generation: contextGeneration)
    }
    private func write(_ value: Look?, ids: [String]) {
        guard settings.contextGeneration == contextGeneration else { return }
        revision += 1
        let submitted = revision
        pendingReplies = ids.count
        saved = value
        error = nil
        for id in ids {
            let completion = settings.editCompletion()
            settings.adapter.setSpaceLook(id: id, look: value) { [self] result in
                completion(result)
                guard settings.contextGeneration == contextGeneration else { return }
                if case .failure = result {
                    error = settings.error
                    if submitted == revision {
                        saved = settings.snapshot.spaces.first { $0.id == spaceID }?.look
                        if !editing {
                            look = saved ?? Self.defaultLook
                            selected = min(selected, look.colors.count - 1)
                        }
                    }
                }
                if submitted == revision && settings.ownsLookPreview(id: spaceID, owner: previewOwner, generation: contextGeneration) {
                    pendingReplies -= 1
                    preview(editing ? look : saved, active: editing || pendingReplies > 0)
                }
            }
        }
        if value == nil { look = Self.defaultLook; selected = 0 }
        preview(value, active: true)
    }
}
