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
    let settings: SettingsModel
    let spaceID: String
    private var saved: Look?
    private var gestureStart: Look?
    private var revision = 0
    private var pendingReplies = 0

    init(settings: SettingsModel, space: SpaceSnapshot) {
        self.settings = settings
        spaceID = space.id
        saved = space.look
        look = space.look ?? Self.defaultLook
    }

    static let defaultLook = Look(colors: [color(x: 0.6, y: 0.5)], opacity: 0.45, grain: 0, glass: false, appearance: .auto)
    static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
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
    static func fieldY(_ y: Double) -> Double { clamp((y - 0.05) / 0.9) }
    static func fieldColor(x: Double, y: Double) -> LookColor { color(x: x, y: 0.05 + 0.9 * clamp(y)) }
    static func transparency(opacity: Double) -> Double { (1 - clamp(opacity)) * 100 }
    static func opacity(transparency: Double) -> Double { 1 - clamp(transparency / 100) }
    var transparency: Double { Self.transparency(opacity: look.opacity) }
    var transparencyLabel: String { "Transparency \(Int(transparency.rounded()))%" }
    static let presets: [[LookColor]] = (0..<9).map { [color(x: Double($0) / 9, y: 0.5)] }
        + (0..<9).map { [color(x: Double($0) / 9, y: 0.35), color(x: (Double($0) / 9 + 0.5).truncatingRemainder(dividingBy: 1), y: 0.65)] }

    func begin() {
        guard !editing else { return }
        gestureStart = look
        editing = true
    }
    func change(_ edit: (inout Look) -> Void) {
        edit(&look)
        settings.previewLook(id: spaceID, look: look, active: editing)
        if !editing { commit() }
    }
    func moveHandle(_ index: Int, dx: Double, dy: Double) {
        guard look.colors.indices.contains(index) else { return }
        begin()
        selected = index
        let start = gestureStart!.colors[index]
        change { $0.colors[index] = Self.fieldColor(x: start.x + dx, y: Self.fieldY(start.y) + dy) }
    }
    func end() {
        guard editing else { return }
        let changed = gestureStart != look
        editing = false
        gestureStart = nil
        if changed { commit() }
        else { settings.previewLook(id: spaceID, look: saved, active: pendingReplies > 0) }
    }
    func dismiss() {
        editing = false
        gestureStart = nil
        look = saved ?? Self.defaultLook
        selected = min(selected, look.colors.count - 1)
        settings.previewLook(id: spaceID, look: saved, active: pendingReplies > 0)
    }
    func add() {
        guard look.colors.count < 3 else { return }
        let hue = (look.colors[selected].x + 1.0 / 3).truncatingRemainder(dividingBy: 1)
        change { $0.colors.append(Self.color(x: hue, y: 0.5)) }
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
    func toggleGlass() { change { $0.glass.toggle() } }
    func setTransparency(_ value: Double) {
        change { $0.opacity = Self.opacity(transparency: value); $0.glass = false }
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
    private func write(_ value: Look?, ids: [String]) {
        revision += 1
        let submitted = revision
        pendingReplies = ids.count
        saved = value
        error = nil
        for id in ids {
            settings.adapter.setSpaceLook(id: id, look: value) { [self] result in
                settings.receive(result)
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
                if submitted == revision {
                    pendingReplies -= 1
                    settings.previewLook(id: spaceID, look: editing ? look : saved, active: editing || pendingReplies > 0)
                }
            }
        }
        if value == nil { look = Self.defaultLook; selected = 0 }
        settings.previewLook(id: spaceID, look: value, active: true)
    }
}
