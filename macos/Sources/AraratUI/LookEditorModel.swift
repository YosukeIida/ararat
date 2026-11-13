import AppKit
import AraratKit
import SwiftUI

/// One of the mock's chips: a base colour (its hue and HSL lightness) that sets the shared radius
/// and, with the page's harmony, the other handles' hues.
struct LookChip: Equatable {
    let name: String
    let hue: Double        // degrees, as the mock's PAGES list them
    let saturation: Double
    let value: Double
    var lightness: Double { value * (1 - saturation / 2) }
    /// The hue as the stored x (0…1) and the stored y the chip's colour takes (0.05 white … 0.95 black).
    var x: Double { hue / 360 }
    var y: Double { min(0.95, max(0.05, 1 - lightness)) }
}

@MainActor
final class LookEditorModel: ObservableObject {
    @Published private(set) var look: Look
    @Published var selected = 0
    @Published var chipPage = 0
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
    /// The inscribed circle. The dots fill it, centres on an 8 pt half-pitch lattice (no dot at the
    /// centre) out to 114 pt; the handles reach 100 pt, so a dragged 32 pt handle stays inside the
    /// circle (100 + 16 = 116) and the dots always reach the handle range.
    static let fieldDotDiscRadius: CGFloat = 116
    static let fieldDotPitch: CGFloat = 8
    static let fieldDotSize: CGFloat = 4
    static let fieldMaxRadius: CGFloat = 100
    static var fieldCentre: CGPoint { CGPoint(x: fieldCanvasSize.width / 2, y: fieldCanvasSize.height / 2) }
    /// The dots' centres in field coordinates.
    static func dotCentres() -> [CGPoint] {
        let disc = fieldDotDiscRadius
        let count = Int(disc / fieldDotPitch)
        var points: [CGPoint] = []
        for row in (-count)..<count {
            let dy = (CGFloat(row) + 0.5) * fieldDotPitch
            for column in (-count)..<count {
                let dx = (CGFloat(column) + 0.5) * fieldDotPitch
                if hypot(dx, dy) <= disc - fieldDotSize / 2 {
                    points.append(CGPoint(x: fieldCentre.x + dx, y: fieldCentre.y + dy))
                }
            }
        }
        return points
    }
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
    static func handleLabel(index: Int, count: Int) -> String { "Colour \(index + 1) of \(count)" }
    static func handleValue(_ color: LookColor) -> String {
        let hue = Int((wrapped(color.x) * 360).rounded()) % 360
        let lightness = Int(((1 - color.y) * 100).rounded())
        return "Hue \(hue) degrees, lightness \(lightness) percent"
    }
    /// The mock's chips (common.py :76-77 and the F-LookStates board): nine base colours per page.
    /// The chip keeps the current handle count and applies its page's harmony around the selected
    /// handle; its colour's HSL lightness sets the shared radius.
    static let chipPages: [[LookChip]] = [
        [
            LookChip(name: "White", hue: 0, saturation: 0.06, value: 1),
            LookChip(name: "Pink", hue: 340, saturation: 0.4, value: 1),
            LookChip(name: "Mauve", hue: 290, saturation: 0.45, value: 1),
            LookChip(name: "Red", hue: 0, saturation: 1, value: 0.9),
            LookChip(name: "Orange", hue: 28, saturation: 1, value: 1),
            LookChip(name: "Yellow", hue: 52, saturation: 0.85, value: 1),
            LookChip(name: "Green", hue: 130, saturation: 1, value: 0.7),
            LookChip(name: "Sky", hue: 205, saturation: 0.5, value: 1),
            LookChip(name: "Slate", hue: 220, saturation: 1, value: 0.35),
        ],
        [
            LookChip(name: "Teal", hue: 180, saturation: 1, value: 0.6),
            LookChip(name: "Blue", hue: 225, saturation: 1, value: 0.85),
            LookChip(name: "Indigo", hue: 250, saturation: 1, value: 0.7),
            LookChip(name: "Violet", hue: 275, saturation: 0.8, value: 1),
            LookChip(name: "Magenta", hue: 310, saturation: 1, value: 0.9),
            LookChip(name: "Rose", hue: 350, saturation: 0.6, value: 1),
            LookChip(name: "Amber", hue: 42, saturation: 1, value: 1),
            LookChip(name: "Lime", hue: 90, saturation: 0.8, value: 1),
            LookChip(name: "Sand", hue: 40, saturation: 0.25, value: 1),
        ],
    ]
    /// The page's harmony offsets for one, two and three handles: page 1 split, page 2 analogous.
    static let harmonies: [[[Double]]] = [
        [[0], [0, 180], [0, -150, 150]],
        [[0], [0, 40], [0, -40, 40]],
    ]
    static func chipColour(_ chip: LookChip) -> LookColor { fieldColor(x: chip.x, y: fieldY(chip.y)) }
    /// A chip's swatch colours: its own colour, or the three analogous hues the mock draws for page 2.
    static func chipSwatch(_ page: Int, _ chip: LookChip) -> [LookColor] {
        (page == 1 ? harmonies[1][2] : [0]).map { fieldColor(x: chip.x + $0 / 360, y: fieldY(chip.y)) }
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
            // No motion is decided on the translation itself, before any geometry: a handle on the
            // centre (or a stored hue of exactly 1.0) does not round-trip to its own hue, so a
            // geometry-based test would read a press as a turn to red.
            guard translation != .zero else { return }
            begin()
        }
        selected = index
        guard let start = gestureStart, start.colors.indices.contains(index) else { return }
        let base = start.colors[index]
        let baseY = Self.fieldY(base.y)
        var position: (x: Double, y: Double)
        if translation == .zero {
            // Back at the grab point: the start, exactly (the centre and hue 1.0 included).
            position = (base.x, baseY)
        } else {
            let grip = Self.fieldPoint(x: base.x, y: baseY)
            position = Self.fieldPosition(CGPoint(x: grip.x + translation.width, y: grip.y + translation.height))
            // A near-return to the grab point restores the start exactly, so it writes nothing.
            if abs(position.x - base.x) < 0.000000001 && abs(position.y - baseY) < 0.000000001 { position = (base.x, baseY) }
        }
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
    /// Applies one chip: the current handle count stays, the selected handle takes the chip's hue and
    /// lightness (so the shared radius comes from the chip), and the other handles take the page's
    /// harmony offsets in handle order. One write, on release, through begin()/end().
    func applyChip(page: Int, index: Int) {
        guard Self.chipPages.indices.contains(page), Self.chipPages[page].indices.contains(index) else { return }
        let chip = Self.chipPages[page][index]
        let offsets = Self.harmonies[page][max(0, min(2, look.colors.count - 1))]
        let anchor = look.colors.indices.contains(selected) ? selected : 0
        begin()
        change { look in
            var next = 1
            for i in look.colors.indices {
                let offset: Double
                if i == anchor || offsets.count == 1 { offset = 0 }
                else { offset = next < offsets.count ? offsets[next] : 0; next += 1 }
                look.colors[i] = Self.fieldColor(x: chip.x + offset / 360, y: Self.fieldY(chip.y))
            }
        }
        end()
    }
    /// Whether the selected handle sits on the chip's own hue and lightness (the mock marks a chip
    /// as chosen by its base point, whatever the other handles are doing).
    func isChipApplied(_ chip: LookChip) -> Bool {
        guard look.colors.indices.contains(selected) else { return false }
        let colour = look.colors[selected]
        return abs(colour.x - chip.x) < 0.0005 && abs(colour.y - chip.y) < 0.0005
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
