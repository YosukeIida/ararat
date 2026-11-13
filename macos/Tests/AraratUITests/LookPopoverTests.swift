import AppKit
import AraratKit
import SwiftUI
import SQLite3
import Testing
@testable import AraratUI
@testable import AraratHarness

@MainActor
private func lookValue<T: Sendable>(_ start: (@escaping WorkspaceAdapter.Completion<T>) -> Void) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in start { continuation.resume(with: $0) } }
}

@MainActor
private final class LookPreview { var look: Look? }

/// The translation a drag sends from a grabbed handle to a target field position (hue, radial y).
@MainActor
private func lookDrag(from grip: CGPoint, to x: Double, _ y: Double) -> CGSize {
    let target = LookEditorModel.fieldPoint(x: x, y: y)
    return CGSize(width: target.x - grip.x, height: target.y - grip.y)
}

@MainActor
private func lookGrip(_ colour: LookColor) -> CGPoint {
    LookEditorModel.fieldPoint(x: colour.x, y: LookEditorModel.fieldY(colour.y))
}

@MainActor
private final class LookFixture {
    let preview = LookPreview()
    let directory: URL
    let adapter: WorkspaceAdapter
    let settings: SettingsModel
    let editor: LookEditorModel
    let sidebar: SidebarView?
    init(sidebarPreview: Bool = false) async throws {
        _ = NSApplication.shared
        let adapter = WorkspaceAdapter(windowID: "look-editor")
        let directory = try testTemporaryDirectory()
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/AraratHarness/Fixtures/arc-sidebar-synthetic.json")
        let json = try String(contentsOf: fixture, encoding: .utf8)
        var snapshot = try await lookValue { adapter.open(path: directory.appendingPathComponent("look.sqlite").path, json: { json }, windowsJSON: { nil }, keyBindingsJSON: { nil }, linkRoutingJSON: { nil }, completion: $0) }
        if snapshot.spaces.count < 2 { snapshot = try await lookValue { adapter.createSpace(name: "Second", completion: $0) } }
        snapshot = try await lookValue { adapter.setSpaceLook(id: snapshot.spaces[0].id, look: nil, completion: $0) }
        let sidebar = sidebarPreview ? SidebarView(snapshot: snapshot) : nil
        sidebar?.showSpace(at: 0)
        let preview = self.preview
        let publish: (WorkspaceSnapshot) -> Void = { snapshot in
            if let sidebar { sidebar.applySelection(snapshot: snapshot) }
            else { preview.look = snapshot.spaces[0].look }
        }
        let settings = SettingsModel(snapshot: snapshot, adapter: adapter, publish: publish, resetWidth: {}, preview: { id, look, active in
            if let sidebar { sidebar.previewLook(spaceID: id, look: look, active: active) }
            else { preview.look = look }
        }, keyBindings: KeyBindingsModel(adapter: adapter), airTraffic: AirTrafficModel(adapter: adapter))
        self.adapter = adapter
        self.directory = directory
        self.settings = settings
        self.sidebar = sidebar
        editor = LookEditorModel(settings: settings, space: snapshot.spaces[0])
        sidebar?.onLookChanged = { [preview] from, to, fraction in preview.look = fraction < 0.5 ? from : to }
    }
    func stored() async throws -> WorkspaceSnapshot { try await lookValue { adapter.snapshot(completion: $0) } }
    func writes() async throws -> Int {
        _ = try await stored()
        var database: OpaquePointer?
        let path = directory.appendingPathComponent("look.sqlite").path
        try #require(sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        try #require(sqlite3_prepare_v2(database, "SELECT count(*) FROM journal WHERE kind = 'space'", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        try #require(sqlite3_step(statement) == SQLITE_ROW)
        return Int(sqlite3_column_int64(statement, 0))
    }
    func close() async throws {
        _ = try await lookValue { adapter.shutdown(completion: $0) }
        try FileManager.default.removeItem(at: directory)
    }
}

@Test @MainActor
func lookCoordinatesAndTransparencyKeepArcTermsAndRoundForDisplay() {
    for x in [0.0, 0.2, 0.5, 1.0] {
        let white = LookEditorModel.color(x: x, y: 0)
        let black = LookEditorModel.color(x: x, y: 1)
        #expect(white.red == 1 && white.green == 1 && white.blue == 1)
        #expect(black.red == 0 && black.green == 0 && black.blue == 0)
        let color = LookEditorModel.color(x: x, y: 0.5)
        #expect(color.x == x && color.y == 0.5)
        let maximum = max(color.red, color.green, color.blue), minimum = min(color.red, color.green, color.blue)
        #expect(abs((maximum + minimum) / 2 - 0.5) < 0.000001)
        #expect(abs((maximum - minimum) - 0.65) < 0.000001)
    }
    let red = LookEditorModel.color(x: 0, y: 0.5), green = LookEditorModel.color(x: 1.0 / 3, y: 0.5), blue = LookEditorModel.color(x: 2.0 / 3, y: 0.5)
    #expect(red.red > red.green && green.green > green.blue && blue.blue > blue.red)
    #expect(LookEditorModel.color(x: 0, y: 0.5).red == LookEditorModel.color(x: 1, y: 0.5).red)
    for x in [0.0, 0.5, 1.0] {
        let top = LookEditorModel.fieldColor(x: x, y: 0), bottom = LookEditorModel.fieldColor(x: x, y: 1)
        #expect(top.y == 0.05 && abs(bottom.y - 0.95) < 0.000001)
        #expect(min(top.red, top.green, top.blue) < 1)
        #expect(max(bottom.red, bottom.green, bottom.blue) > 0)
        #expect(abs(LookEditorModel.fieldY(top.y)) < 0.000001 && abs(LookEditorModel.fieldY(bottom.y) - 1) < 0.000001)
    }
    for percent in [0.0, 10, 55.55, 90, 100] {
        #expect(abs(LookEditorModel.transparency(opacity: LookEditorModel.opacity(transparency: percent)) - percent) < 0.000001)
    }
    #expect(LookEditorModel.opacity(transparency: 0) == 1)
    #expect(LookEditorModel.opacity(transparency: 100) == 0)
    #expect(LookEditorModel.transparency(opacity: 0) == 100)
    #expect(LookEditorModel.transparency(opacity: 1) == 0)
    #expect(LookEditorModel.color(x: -1, y: 2).x == 0)
    #expect(LookEditorModel.color(x: -1, y: 2).y == 1)
}

// The polar field: hue around the circle, the radial coordinate in from the rim (0) to the centre
// (1), and the same mapping back; a point past the rim keeps its hue at the maximum radius. The
// handle radius runs 0…108 pt over stored y 0.95…0.05, so a mid lightness sits half way out.
@Test @MainActor
func thePolarFieldMapsHuesAndRadiiBothWays() {
    let centre = LookEditorModel.fieldCentre
    #expect(LookEditorModel.fieldCanvasSize == CGSize(width: 264, height: 232))
    #expect(centre == CGPoint(x: 132, y: 116))
    #expect(LookEditorModel.fieldMaxRadius == 108)
    #expect(LookEditorModel.fieldPoint(x: 0, y: 0) == CGPoint(x: 240, y: 116))
    #expect(abs(LookEditorModel.fieldPoint(x: 0.25, y: 0).x - 132) < 0.000001)
    #expect(abs(LookEditorModel.fieldPoint(x: 0.25, y: 0).y - 224) < 0.000001)
    #expect(LookEditorModel.fieldPoint(x: 0.5, y: 1) == centre)
    #expect(abs(LookEditorModel.fieldPoint(x: 0.5, y: 0).x - 24) < 0.000001)
    #expect(abs(LookEditorModel.fieldPoint(x: 0.5, y: 0).y - 116) < 0.000001)
    for (x, y) in [(0.0, 0.0), (0.13, 0.3), (0.5, 0.6), (0.79, 0.95), (0.999, 0.5)] {
        let back = LookEditorModel.fieldPosition(LookEditorModel.fieldPoint(x: x, y: y))
        #expect(abs(back.x - LookEditorModel.wrapped(x)) < 0.000001)
        #expect(abs(back.y - y) < 0.000001)
    }
    // Past the rim: the hue stays, the radius clamps to the maximum, the field coordinate to 0.
    let far = LookEditorModel.fieldPosition(CGPoint(x: centre.x + 400, y: centre.y - 400))
    #expect(abs(far.x - 0.875) < 0.000001)
    #expect(far.y == 0)
    #expect(abs(LookEditorModel.radius(of: 0.95)) < 0.000001)
    #expect(LookEditorModel.radius(of: 0.05) == 108)
    #expect(abs(LookEditorModel.storedY(radius: 54) - 0.5) < 0.000001)
    #expect(LookEditorModel.fieldY(radius: 108) == 0 && LookEditorModel.fieldY(radius: 216) == 0)
    // The centre has no hue of its own; it answers the first one instead of a NaN.
    #expect(LookEditorModel.fieldPosition(centre) == (x: 0, y: 1))
}

@Test @MainActor
func aPressWithoutMovementDoesNotMoveTheGroupOrWrite() async throws {
    // The grab offset: a press that does not move (including the off-centre press a click makes) maps
    // back to the handle's own position, so nothing changes and nothing is written.
    let fixture = try await LookFixture()
    let editor = fixture.editor
    editor.change { $0.colors = [LookEditorModel.fieldColor(x: 0.2, y: 0.5), LookEditorModel.fieldColor(x: 0.4, y: 0.3)] }
    let count = try await fixture.writes()
    let before = editor.look
    editor.movePoint(0, translatedBy: .zero)
    #expect(editor.look == before && !editor.editing)
    editor.end()
    #expect(try await fixture.writes() == count)
    try await fixture.close()
}

@Test @MainActor
func aPressOnAHandleSelectsItWithoutMovingTheGroup() async throws {
    // The handle's gesture starts on the press with the pointer's translation (the grab offset); a
    // press with no movement selects that handle and edits nothing. The view sends this same call on
    // mouse-down, and `picker_input` in the look check drags the field for real.
    let fixture = try await LookFixture()
    let editor = fixture.editor
    let look = Look(colors: [LookEditorModel.fieldColor(x: 0.2, y: 0.5), LookEditorModel.fieldColor(x: 0.6, y: 0.3)],
                    opacity: 1, grain: 0, glass: false, appearance: .light)
    editor.change { $0 = look }
    editor.selected = 1
    let count = try await fixture.writes()
    #expect(editor.selected == 1)
    editor.movePoint(0, translatedBy: .zero)
    #expect(editor.selected == 0)
    #expect(editor.look == look && !editor.editing)
    editor.end()
    #expect(try await fixture.writes() == count)
    try await fixture.close()
}

@Test @MainActor
func theGroupTurnWrapsPastRed() async throws {
    let fixture = try await LookFixture()
    let editor = fixture.editor
    // The check's own case: 0.4 / 0.9 + 0.25 -> 0.65 / 0.15, not 0.65 / 1.0.
    editor.change { $0.colors = [LookEditorModel.fieldColor(x: 0.4, y: 0.5), LookEditorModel.fieldColor(x: 0.9, y: 0.5)] }
    let count = try await fixture.writes()
    let grip = lookGrip(editor.look.colors[0])
    editor.movePoint(0, translatedBy: lookDrag(from: grip, to: 0.65, 0.5))
    #expect(abs(editor.look.colors[0].x - 0.65) < 0.000001)
    #expect(abs(editor.look.colors[1].x - 0.15) < 0.000001)
    editor.end()
    #expect(try await fixture.writes() == count + 1)
    // Turning forward across the seam and backward from red both continue the group.
    editor.change { $0.colors = [LookEditorModel.fieldColor(x: 0.99, y: 0.5), LookEditorModel.fieldColor(x: 0.1, y: 0.5)] }
    editor.turnColours(by: LookEditorModel.hueKeyStep)
    #expect(abs(editor.look.colors[0].x - (0.99 + 5.0 / 360 - 1)) < 0.000001)
    #expect(abs(editor.look.colors[1].x - (0.1 + 5.0 / 360)) < 0.000001)
    editor.change { $0.colors = [LookEditorModel.fieldColor(x: 0, y: 0.5), LookEditorModel.fieldColor(x: 0.5, y: 0.5), LookEditorModel.fieldColor(x: 0.99, y: 0.5)] }
    for _ in 0..<3 { editor.turnColours(by: -LookEditorModel.hueKeyStep) }
    #expect(abs(editor.look.colors[0].x - (1 - 15.0 / 360)) < 0.000001)
    #expect(abs(editor.look.colors[2].x - (0.99 - 15.0 / 360)) < 0.000001)
    // Three handles dragged across the seam keep their offsets.
    editor.change { $0.colors = [LookEditorModel.fieldColor(x: 0.2, y: 0.5), LookEditorModel.fieldColor(x: 0.6, y: 0.5), LookEditorModel.fieldColor(x: 0.9, y: 0.5)] }
    let middleGrip = lookGrip(editor.look.colors[1])
    editor.movePoint(1, translatedBy: lookDrag(from: middleGrip, to: 0.75, 0.5))
    #expect(abs(editor.look.colors[0].x - 0.35) < 0.000001)
    #expect(abs(editor.look.colors[1].x - 0.75) < 0.000001)
    #expect(abs(editor.look.colors[2].x - 0.05) < 0.000001)
    editor.end()
    try await fixture.close()
}

@Test @MainActor
func thePolarGroupTurnsAsOneSharesOneRadiusAndClampsAtTheRim() async throws {
    let fixture = try await LookFixture(sidebarPreview: true)
    let editor = fixture.editor
    let first = LookEditorModel.fieldColor(x: 0.2, y: 0.5)
    let second = LookEditorModel.fieldColor(x: 0.7, y: 0.5)
    editor.change { $0.colors = [first, second] }
    let count = try await fixture.writes()
    // A quarter turn outward: both hues move by the same angle and both take the dragged radius.
    let grip = lookGrip(first)
    editor.movePoint(0, translatedBy: lookDrag(from: grip, to: 0.45, 0.25))
    #expect(editor.selected == 0 && editor.editing)
    #expect(editor.look.colors.count == 2)
    #expect(abs(editor.look.colors[0].x - 0.45) < 0.000001)
    #expect(abs(editor.look.colors[1].x - 0.95) < 0.000001)
    let shared = LookEditorModel.storedY(radius: 0.75 * Double(LookEditorModel.fieldMaxRadius))
    #expect(abs(shared - 0.275) < 0.000001)
    #expect(editor.look.colors.allSatisfy { abs($0.y - shared) < 0.000001 })
    let expected = LookEditorModel.fieldColor(x: 0.45, y: 0.25)
    #expect(abs(editor.look.colors[0].red - expected.red) < 0.000001 && abs(editor.look.colors[0].blue - expected.blue) < 0.000001)
    // Repeated events of one gesture do not accumulate: the second event is still based on the start.
    editor.movePoint(0, translatedBy: lookDrag(from: grip, to: 0.45, 0.25))
    #expect(abs(editor.look.colors[1].x - 0.95) < 0.000001)
    #expect(fixture.sidebar?.lookPreviewForCheck == editor.look)
    #expect(try await fixture.writes() == count)
    // Dragging past the edge keeps the hue at the maximum radius (stored y 0.05), one write on release.
    editor.movePoint(0, translatedBy: lookDrag(from: grip, to: 0, 0))
    #expect(editor.look.colors.allSatisfy { $0.y == 0.05 })
    #expect(abs(editor.look.colors[0].x) < 0.000001)
    #expect(abs(LookEditorModel.wrapped(editor.look.colors[1].x - editor.look.colors[0].x) - 0.5) < 0.000001)
    let dragged = editor.look
    editor.end()
    #expect(!editor.editing)
    #expect(try await fixture.writes() == count + 1)
    #expect(try await fixture.stored().spaces[0].look == dragged)
    #expect(fixture.sidebar?.lookPreviewForCheck == nil)
    try await fixture.close()
}

@Test @MainActor
func thePickerStepsTurnAndResizeTheWholeGroup() async throws {
    let fixture = try await LookFixture()
    let editor = fixture.editor
    editor.change { $0.colors = [LookEditorModel.fieldColor(x: 0.2, y: 0.5), LookEditorModel.fieldColor(x: 0.6, y: 0.5)] }
    let count = try await fixture.writes()
    editor.turnColours(by: LookEditorModel.hueKeyStep)
    #expect(abs(editor.look.colors[0].x - (0.2 + 5.0 / 360)) < 0.000001)
    #expect(abs(editor.look.colors[1].x - (0.6 + 5.0 / 360)) < 0.000001)
    #expect(editor.look.colors.allSatisfy { abs($0.y - 0.5) < 0.000001 })
    editor.stepRadius(LookEditorModel.radiusKeyStep)
    #expect(abs(LookEditorModel.radius(of: editor.look.colors[0].y) - 60) < 0.000001)
    #expect(abs(editor.look.colors[0].y - editor.look.colors[1].y) < 0.000001)
    #expect(try await fixture.writes() == count + 2)
    for _ in 0..<30 { editor.stepRadius(LookEditorModel.radiusKeyStep) }
    #expect(editor.look.colors.allSatisfy { abs($0.y - 0.05) < 0.000001 })
    for _ in 0..<30 { editor.stepRadius(-LookEditorModel.radiusKeyStep) }
    #expect(editor.look.colors.allSatisfy { abs($0.y - 0.95) < 0.000001 })
    #expect(LookEditorModel.handleLabel(index: 0, count: 2) == "Colour 1 of 2")
    #expect(LookEditorModel.handleLabel(index: 2, count: 3) == "Colour 3 of 3")
    #expect(LookEditorModel.handleValue(LookEditorModel.color(x: 220.0 / 360, y: 0.5)) == "Hue 220 degrees, lightness 50 percent")
    #expect(LookEditorModel.handleValue(LookEditorModel.color(x: 0.999, y: 0.05)) == "Hue 0 degrees, lightness 95 percent")
    try await fixture.close()
}

@Test @MainActor
func thePresetPagesAreNineSolidsAndNineAdjacentHuePairs() {
    #expect(LookEditorModel.presets.count == 18)
    for index in 0..<9 {
        let solid = LookEditorModel.presets[index]
        #expect(solid.count == 1)
        #expect(abs(solid[0].x - Double(index) / 9) < 0.000001)
        #expect(solid[0].y == 0.5)
        // Page 2 is analogous: two hues 40 degrees apart on the one radius, page 1's split is untouched.
        let pair = LookEditorModel.presets[index + 9]
        #expect(pair.count == 2)
        #expect(abs(pair[0].x - Double(index) / 9) < 0.000001)
        // 40 degrees is exactly a ninth of the wheel: the second hue is the next preset step on.
        #expect(abs(pair[1].x - LookEditorModel.wrapped(Double(index + 1) / 9)) < 0.000001)
        #expect(pair.allSatisfy { $0.y == 0.5 })
        #expect(LookEditorModel.radius(of: pair[0].y) == LookEditorModel.radius(of: pair[1].y))
    }
    // 40 degrees is a ninth of the wheel, so each pair sits one preset step apart.
    #expect(abs(LookEditorModel.presets[10][1].x - 2.0 / 9) < 0.000001)
    #expect(LookEditorModel.presets[17][1].x == 0)
}

@Test @MainActor
func lookDragPreviewsWithoutWritingAndCommitsExactlyOnce() async throws {
    let fixture = try await LookFixture(sidebarPreview: true)
    let editor = fixture.editor
    let count = try await fixture.writes()
    #expect(editor.look == LookEditorModel.defaultLook)
    #expect(try await fixture.stored().spaces[0].look == nil)
    #expect(try await fixture.writes() == count)
    editor.begin()
    editor.end()
    #expect(try await fixture.writes() == count)
    let grip = lookGrip(editor.look.colors[0])
    editor.movePoint(0, translatedBy: lookDrag(from: grip, to: 0.7, 0.5))
    editor.movePoint(0, translatedBy: lookDrag(from: grip, to: 0.6, 0.5))
    editor.end()
    #expect(try await fixture.writes() == count)
    #expect(fixture.preview.look == nil)
    for frame in 1...20 {
        let step = Double(frame) / 20
        editor.movePoint(0, translatedBy: lookDrag(from: grip, to: 0.6 + 0.2 * step, 0.5 - 0.1 * step))
    }
    #expect(editor.editing)
    #expect(try await fixture.writes() == count)
    #expect(try await fixture.stored().spaces[0].look == nil)
    #expect(fixture.preview.look == editor.look)
    #expect(fixture.settings.snapshot.spaces[0].look == nil)
    let final = editor.look
    editor.end()
    editor.end()
    #expect(try await fixture.writes() == count + 1)
    #expect(try await fixture.stored().spaces[0].look == final)
    #expect(fixture.settings.snapshot.spaces[0].look == final)
    editor.movePoint(0, translatedBy: lookDrag(from: lookGrip(editor.look.colors[0]), to: 0.2, 0.7))
    editor.dismiss()
    #expect(editor.look == final && !editor.editing)
    #expect(fixture.preview.look == final)
    #expect(try await fixture.stored().spaces[0].look == final)
    #expect(try await fixture.writes() == count + 1)
    try await fixture.close()
}

@Test @MainActor
func lookHandleLimitsPresetsModesAndResetReachTheCore() async throws {
    let fixture = try await LookFixture()
    let model = fixture.editor
    let initial = try await fixture.writes()
    model.remove()
    #expect(try await fixture.writes() == initial)
    model.add()
    #expect(model.look.colors.count == 2 && model.selected == 1)
    #expect(abs(model.look.colors[1].x - (0.6 + 1.0 / 3)) < 0.000001)
    #expect(model.look.colors[1].y == 0.5)
    model.add()
    model.add()
    #expect(model.look.colors.count == 3)
    #expect(try await fixture.writes() == initial + 2)
    model.remove()
    model.remove()
    model.remove()
    #expect(model.look.colors.count == 1 && model.selected == 0)
    #expect(try await fixture.writes() == initial + 4)
    #expect(LookEditorModel.presets.count == 18)
    for index in 0..<18 {
        model.preset(index)
        #expect(model.look.colors.count == (index < 9 ? 1 : 2))
        #expect(try await fixture.stored().spaces[0].look?.colors == LookEditorModel.presets[index])
    }
    for mode: Appearance in [.light, .dark, .auto] {
        model.change { $0.appearance = mode }
        #expect(try await fixture.stored().spaces[0].look?.appearance == mode)
    }
    model.reset()
    #expect(try await fixture.stored().spaces[0].look == nil)
    #expect(fixture.preview.look == nil)
    #expect(model.look == LookEditorModel.defaultLook)
    try await fixture.close()
}

@Test @MainActor
func lookSlidersWriteOnReleaseAndGlassClearsWhenTransparencyMoves() async throws {
    let fixture = try await LookFixture()
    let editor = fixture.editor
    let count = try await fixture.writes()
    var ticks = 0
    var interaction = TransparencyInteraction(haptic: { ticks += 1 })
    interaction.drag(0.896, model: editor)
    #expect(interaction.label(editor) == "Transparency 90%")
    interaction.drag(1.03, model: editor)
    #expect(interaction.label(editor) == "100% · Liquid Glass ›")
    interaction.drag(1.07, model: editor)
    interaction.drag(1.08, model: editor)
    #expect(interaction.label(editor) == "Liquid Glass")
    #expect(ticks == 1 && editor.look.glass && editor.look.opacity == 0)
    #expect(try await fixture.writes() == count)
    editor.end()
    #expect(try await fixture.writes() == count + 1)
    #expect(try await fixture.stored().spaces[0].look?.glass == true)
    interaction.drag(1.03, model: editor)
    #expect(!editor.look.glass && editor.look.opacity == 0)
    editor.end()
    let left = try await fixture.stored().spaces[0].look
    #expect(left?.glass == false && left?.opacity == 0)
    interaction.drag(1.07, model: editor)
    #expect(ticks == 2)
    editor.end()
    TransparencyInteraction.adjust(.decrement, model: editor)
    #expect(!editor.look.glass && editor.look.opacity == 0)
    TransparencyInteraction.adjust(.increment, model: editor)
    #expect(editor.look.glass && editor.look.opacity == 0)
    for _ in 0..<25 { GrainInteraction.adjust(1, model: editor) }
    #expect(editor.look.grain == 1)
    GrainInteraction.adjust(-1, model: editor)
    #expect(editor.look.grain == 0.95)
    for _ in 0..<25 { GrainInteraction.adjust(-1, model: editor) }
    #expect(editor.look.grain == 0)
    let before = try await fixture.writes()
    editor.begin()
    for value in 0...10 { editor.change { $0.grain = Double(value) / 10 } }
    #expect(try await fixture.writes() == before)
    editor.end()
    #expect(try await fixture.writes() == before + 1)
    #expect(try await fixture.stored().spaces[0].look?.grain == 1)
    try await fixture.close()
}

@Test @MainActor
func lookUseForAllWritesEverySpaceAndKeepsTheSelection() async throws {
    let fixture = try await LookFixture()
    fixture.editor.preset(12)
    let before = try await fixture.stored()
    let count = try await fixture.writes()
    fixture.editor.useForAll()
    let after = try await fixture.stored()
    #expect(try await fixture.writes() == count + before.spaces.count)
    #expect(after.spaces.allSatisfy { $0.look == fixture.editor.look })
    #expect(after.shownSpaceId == before.shownSpaceId && after.selectedId == before.selectedId)
    try await fixture.close()
}

@Test @MainActor
func lookCoreErrorsAreVisibleAndRestoreTheLastPersistedLook() async throws {
    let fixture = try await LookFixture()
    fixture.editor.change { $0.grain = 2 }
    _ = try await fixture.stored()
    #expect(fixture.editor.error != nil && fixture.settings.error != nil)
    #expect(fixture.editor.look == LookEditorModel.defaultLook)
    #expect(fixture.preview.look == nil)
    try await fixture.close()
}

@Test @MainActor
func lookPopoverHostsOffscreenAndDropsAnUnfinishedGestureOnClose() async throws {
    let fixture = try await LookFixture()
    let anchor = LookPopoverAnchor(settings: fixture.settings, space: fixture.settings.snapshot.spaces[0])
    anchor.preparePopover()
    let editor = try #require(anchor.editor)
    let controller = try #require(anchor.popover.contentViewController)
    let host = controller.view
    host.layoutSubtreeIfNeeded()
    await Task.yield()
    #expect(abs(host.fittingSize.width - 288) < 1)
    #expect(!anchor.popover.isShown && host.window?.isVisible != true)
    let count = try await fixture.writes()
    editor.movePoint(0, translatedBy: lookDrag(from: lookGrip(editor.look.colors[0]), to: 0.3, 0.3))
    anchor.popoverWillClose(Notification(name: NSPopover.willCloseNotification, object: anchor.popover))
    #expect(!editor.editing)
    #expect(try await fixture.writes() == count)
    #expect(fixture.preview.look == nil)
    anchor.popover.contentViewController = nil
    try await fixture.close()
}

@Test @MainActor
func settingsPaletteInsertionBeforeOrAfterStoredIconKeepsTheNewGrapheme() {
    #expect(SettingsModel.iconDraft("😀🔬", stored: "🔬") == "😀")
    #expect(SettingsModel.iconDraft("🔬😀", stored: "🔬") == "😀")
    #expect(SettingsModel.iconDraft("👨‍👩‍👧‍👦🔬", stored: "🔬") == "👨‍👩‍👧‍👦")
    #expect(SettingsModel.iconDraft("🔬🔬", stored: "🔬") == "🔬")
    #expect(SettingsModel.iconDraft("👩‍💻😀", stored: "👩") == "😀")
}

@Test @MainActor
func selectedRowCloseKeycapResolvesAgainstTheRealHarnessMenu() throws {
    _ = NSApplication.shared
    let oldMenu = NSApp.mainMenu
    defer { NSApp.mainMenu = oldMenu }
    let harness = HarnessDelegate(adapter: WorkspaceAdapter(windowID: "close-keycap"))
    NSApp.mainMenu = harness.makeMenu()
    let row = SidebarRowView(row: Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: "row", title: "Tab", url: nil, depth: 0, kind: .tab, unloaded: false, lastSelectedAt: nil), selected: true, action: { _ in })
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 200), styleMask: [], backing: .buffered, defer: false)
    window.contentView = row
    defer { window.contentView = nil }
    let tooltip = SidebarTooltip()
    tooltip.modifierFlags = { [] }
    var now = 0.0
    tooltip.clock = { now }
    tooltip.capture(in: row)
    tooltip.update(target: row.closeButton, point: NSPoint(x: 20, y: 20))
    now = 1.6
    tooltip.update(target: row.closeButton, point: NSPoint(x: 20, y: 20))
    #expect(tooltip.keycaps.map(\.stringValue) == ["⌘", "W"])
    #expect(!window.isVisible)
}

@Test @MainActor
func harnessLaunchOptionsAreInitializedWithoutRunningMain() throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("owned.sqlite").path
    let options = HarnessOptions(checkOnly: true, headless: true, databasePath: path, fixturePath: "fixture.json")
    let harness = HarnessDelegate(adapter: WorkspaceAdapter(windowID: "options"), options: options)
    #expect(harness.options.checkOnly && harness.options.headless)
    #expect(harness.options.databasePath == path && harness.options.fixturePath == "fixture.json")
    try Data("keep".utf8).write(to: URL(fileURLWithPath: path))
    #expect(harness.options.removeTemporaryDatabase())
    #expect(FileManager.default.fileExists(atPath: path))
}

@Test @MainActor
func palettePickBeforeStoredIconCommitsThroughTheHostedField() async throws {
    _ = NSApplication.shared
    var committed = "🔬"
    let host = NSHostingView(rootView: SettingsField(value: "🔬", label: "Space icon", characterPalette: true) { committed = $0 })
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.contentView = nil }
    func fields(_ view: NSView) -> [NSTextField] { (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields) }
    try await waitUntil { host.layoutSubtreeIfNeeded(); return !fields(host).isEmpty }
    let field = try #require(fields(host).first)
    field.stringValue = "😀🔬"
    field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
    try await waitUntil { committed == "😀" }
    #expect(!window.isVisible)
}

@Test @MainActor
func importedLookKeepsItsRGBAndPositionsUntilAHandleMoves() async throws {
    let fixture = try await LookFixture()
    let imported = Look(colors: [LookColor(red: 0.1, green: 0.2, blue: 0.3, x: 0.9, y: 0.8)], opacity: 0.31, grain: 0.2, glass: true, appearance: .dark)
    let snapshot = try await lookValue { fixture.adapter.setSpaceLook(id: fixture.editor.spaceID, look: imported, completion: $0) }
    fixture.settings.update(snapshot: snapshot)
    let editor = LookEditorModel(settings: fixture.settings, space: snapshot.spaces[0])
    #expect(editor.look == imported)
    editor.change { $0.appearance = .light }
    #expect(try await fixture.stored().spaces[0].look?.colors == imported.colors)
    editor.movePoint(0, translatedBy: lookDrag(from: lookGrip(imported.colors[0]), to: 0.8, 0.1))
    editor.end()
    let stored = try #require(try await fixture.stored().spaces[0].look)
    #expect(abs(stored.colors[0].x - 0.8) < 0.000001 && abs(stored.colors[0].y - 0.14) < 0.000001)
    let expected = LookEditorModel.fieldColor(x: 0.8, y: 0.1)
    #expect(abs(stored.colors[0].red - expected.red) < 0.000001 && abs(stored.colors[0].green - expected.green) < 0.000001
        && abs(stored.colors[0].blue - expected.blue) < 0.000001)
    #expect(stored.opacity == imported.opacity && stored.grain == imported.grain && stored.glass == imported.glass)
    try await fixture.close()
}

@Test @MainActor
func anEarlierWriteReplyKeepsTheNextDragPreviewWithoutPersistingIt() async throws {
    let fixture = try await LookFixture()
    let editor = fixture.editor
    let initial = try await fixture.writes()
    editor.change { $0.grain = 0.3 }
    let submitted = editor.look
    editor.movePoint(0, translatedBy: lookDrag(from: lookGrip(editor.look.colors[0]), to: 0.5, 0.6))
    let preview = editor.look
    #expect(try await fixture.stored().spaces[0].look == submitted)
    #expect(fixture.preview.look == preview)
    #expect(try await fixture.writes() == initial + 1)
    editor.end()
    #expect(try await fixture.stored().spaces[0].look == preview)
    #expect(try await fixture.writes() == initial + 2)
    try await fixture.close()
}


@Test @MainActor
func lookOnlyPreviewKeepsRowsAndScrollPresentationAndSurvivesCommittedPublishes() async throws {
    let fixture = try await LookFixture(sidebarPreview: true)
    let sidebar = try #require(fixture.sidebar)
    let snapshot = try await fixture.stored()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 720), styleMask: [], backing: .buffered, defer: false)
    window.contentView = sidebar
    defer { sidebar.finishScrollPresentation(); window.contentView = nil }
    sidebar.layoutSubtreeIfNeeded()
    let panel = SidebarPanelView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
    var received: Look?
    sidebar.onLookChanged = { from, to, fraction in
        panel.updateLook(from, to, fraction: fraction)
        received = fraction < 0.5 ? from : to
    }
    let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: -100, wheel3: 0))
    event.timestamp = 100_000_000_000
    sidebar.scrollWheel(with: try #require(NSEvent(cgEvent: event)))
    let sampling = try #require(sidebar.lookSampling)
    #expect(sidebar.spaceShown == 1)
    func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
    let row = try #require(descendants(sidebar).compactMap { $0 as? SidebarRowView }.first)
    let title = try #require(descendants(row).compactMap { $0 as? NSTextField }.first)
    let dockButtons = descendants(sidebar).compactMap { $0 as? SpaceDockView }.flatMap(\.subviews)
    title.stringValue = "Preview must not reload this row"
    row.needsLayout = true
    let superview = row.superview
    let editor = LookEditorModel(settings: fixture.settings, space: snapshot.spaces[1])
    editor.begin()
    editor.change { $0.colors = [LookEditorModel.color(x: 0.2, y: 0.4)] }
    #expect(sidebar.lookSampling === sampling)
    #expect(descendants(sidebar).compactMap { $0 as? SpaceDockView }.flatMap(\.subviews).elementsEqual(dockButtons, by: { $0 === $1 }))
    #expect(row.superview === superview && row.needsLayout)
    #expect(title.stringValue == "Preview must not reload this row")
    #expect(received == editor.look)
    let color = try #require(panel.gradient.backgroundColor)
    #expect(abs(color.alpha - editor.look.opacity) < 0.000001)
    sidebar.applySelection(snapshot: snapshot)
    #expect(received == editor.look)
    editor.dismiss()
    #expect(received == snapshot.spaces[1].look)
    sidebar.applySelection(snapshot: snapshot)
    #expect(received == snapshot.spaces[1].look)
    #expect(!window.isVisible)
    try await fixture.close()
}

@Test @MainActor
func settingsTabCountExcludesPinnedRows() async throws {
    let fixture = try await LookFixture()
    let space = try #require(fixture.settings.snapshot.spaces.first)
    #expect(space.pinned.contains { $0.kind == .tab || $0.kind == .split })
    #expect(fixture.settings.tabCount(space) == space.today.filter { $0.kind == .tab || $0.kind == .split }.count)
    try await fixture.close()
}

@Test @MainActor
func submittedLookSurvivesAnOlderPublishUntilTheLatestReply() async throws {
    let fixture = try await LookFixture(sidebarPreview: true)
    let old = fixture.settings.snapshot
    fixture.editor.begin()
    fixture.editor.setTransparency(20)
    fixture.editor.end()
    let first = fixture.editor.look
    fixture.sidebar?.applySelection(snapshot: old)
    #expect(fixture.preview.look == first)
    fixture.editor.change { $0.grain = 0.8 }
    let latest = fixture.editor.look
    fixture.sidebar?.applySelection(snapshot: old)
    #expect(fixture.preview.look == latest)
    fixture.editor.dismiss()
    fixture.sidebar?.applySelection(snapshot: old)
    #expect(fixture.preview.look == latest)
    _ = try await fixture.stored()
    #expect(fixture.preview.look == latest)
    fixture.sidebar?.applySelection(snapshot: old)
    #expect(fixture.preview.look == nil)
    try await fixture.close()
}

@Test
func lookFieldBackgroundResolvesByAppearance() throws {
    func sRGB(_ color: NSColor, appearance: NSAppearance) -> NSColor? {
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) }
        return resolved
    }
    let darkAppearance = try #require(NSAppearance(named: .darkAqua))
    let dark = try #require(sRGB(LookFieldColors.field, appearance: darkAppearance))
    for value in [dark.redComponent, dark.greenComponent, dark.blueComponent] {
        #expect(abs(value - 42.0 / 255) < 0.0001)
    }
    let lightAppearance = try #require(NSAppearance(named: .aqua))
    let light = try #require(sRGB(LookFieldColors.field, appearance: lightAppearance))
    let control = try #require(sRGB(.controlBackgroundColor, appearance: lightAppearance))
    #expect(light.redComponent == control.redComponent && light.greenComponent == control.greenComponent && light.blueComponent == control.blueComponent)
}

@Test @MainActor
func lookAdjustmentsWriteGridValuesAndEnterGlass() async throws {
    let fixture = try await LookFixture()
    let editor = fixture.editor
    editor.setTransparency(99)
    var writes = try await fixture.writes()
    TransparencyInteraction.adjust(.increment, model: editor)
    var stored = try await fixture.stored().spaces[0].look
    #expect(try await fixture.writes() == writes + 1)
    #expect(stored?.glass == false && stored?.opacity == 0)
    writes += 1
    TransparencyInteraction.adjust(.increment, model: editor)
    stored = try await fixture.stored().spaces[0].look
    #expect(try await fixture.writes() == writes + 1)
    #expect(stored?.glass == true && stored?.opacity == 0)
    writes += 1
    TransparencyInteraction.adjust(.decrement, model: editor)
    stored = try await fixture.stored().spaces[0].look
    #expect(try await fixture.writes() == writes + 1)
    #expect(stored?.glass == false && stored?.opacity == 0)
    editor.setTransparency(99.6)
    TransparencyInteraction.adjust(.increment, model: editor)
    #expect(try await fixture.stored().spaces[0].look?.glass == true)
    editor.setTransparency(55.3)
    TransparencyInteraction.adjust(.decrement, model: editor)
    #expect(abs(editor.transparency - 54) < 0.00001)
    editor.change { $0.grain = 0.07 }
    writes = try await fixture.writes()
    GrainInteraction.adjust(-1, model: editor)
    #expect(try await fixture.writes() == writes + 1)
    #expect(try await fixture.stored().spaces[0].look?.grain == 0.05)
    editor.change { $0.grain = 0.07 }
    GrainInteraction.adjust(1, model: editor)
    #expect(try await fixture.stored().spaces[0].look?.grain == 0.1)
    try await fixture.close()
}

@Test @MainActor
func grainDragPreservesClicksAndWrapsAndClamps() async throws {
    let fixture = try await LookFixture()
    let editor = fixture.editor
    let size = CGSize(width: 100, height: 100)
    #expect(GrainInteraction.value(at: CGPoint(x: 50, y: 0), size: size) == 0)
    #expect(GrainInteraction.value(at: CGPoint(x: 100, y: 50), size: size) == 0.25)
    #expect(GrainInteraction.value(at: CGPoint(x: 50, y: 100), size: size) == 0.5)
    editor.change { $0.grain = 0.07 }
    let count = try await fixture.writes()
    var knob = GrainInteraction()
    knob.drag(0.9, model: editor)
    knob.drag(0.9, model: editor)
    editor.end()
    #expect(try await fixture.writes() == count)
    #expect(editor.look.grain == 0.07)
    knob.previous = nil
    knob.drag(0.9, model: editor)
    knob.drag(0.1, model: editor)
    #expect(editor.look.grain == 0.25)
    knob.drag(0.45, model: editor)
    knob.drag(0.8, model: editor)
    knob.drag(0.1, model: editor)
    #expect(editor.look.grain == 1)
    knob.drag(0.8, model: editor)
    knob.drag(0.45, model: editor)
    knob.drag(0.1, model: editor)
    knob.drag(0.8, model: editor)
    #expect(editor.look.grain == 0)
    editor.end()
    #expect(try await fixture.writes() == count + 1)
    try await fixture.close()
}

@Test @MainActor
func socketRequiresTheHundredPercentDetentFirst() async throws {
    let fixture = try await LookFixture()
    let editor = fixture.editor
    editor.setTransparency(30)
    var interaction = TransparencyInteraction(haptic: {})
    interaction.drag(1.1, model: editor)
    interaction.drag(1.1, model: editor)
    #expect(editor.transparency == 100 && !editor.look.glass && interaction.detent)
    editor.end()
    #expect(try await fixture.stored().spaces[0].look?.glass == false)
    interaction.previousPosition = nil
    interaction.drag(1.1, model: editor)
    #expect(editor.look.glass)
    editor.end()
    editor.setTransparency(30)
    interaction.previousPosition = nil
    interaction.drag(1.1, model: editor)
    interaction.drag(1.11, model: editor)
    #expect(editor.look.glass)
    editor.end()
    try await fixture.close()
}

@Test @MainActor
func grainCentreDragAndAdjustmentsAtLimitsDoNotWrite() async throws {
    let fixture = try await LookFixture()
    let editor = fixture.editor
    editor.change { $0.grain = 0.7 }
    var writes = try await fixture.writes()
    let size = CGSize(width: 36, height: 36)
    var knob = GrainInteraction()
    knob.drag(GrainInteraction.value(at: CGPoint(x: 18, y: 18), size: size), model: editor)
    knob.drag(GrainInteraction.value(at: CGPoint(x: 17, y: 18), size: size), model: editor)
    editor.end()
    #expect(knob.previous == nil && editor.look.grain == 0.7)
    #expect(try await fixture.writes() == writes)
    #expect(GrainInteraction.value(at: CGPoint(x: 12, y: 18), size: size) == 0.75)
    editor.setTransparency(0)
    writes = try await fixture.writes()
    TransparencyInteraction.adjust(.decrement, model: editor)
    #expect(try await fixture.writes() == writes)
    editor.change { $0.grain = 1 }
    writes = try await fixture.writes()
    GrainInteraction.adjust(1, model: editor)
    #expect(try await fixture.writes() == writes)
    try await fixture.close()
}

@Test @MainActor
func lookCheckHapticSeamCountsAlignmentFeedback() async throws {
    let fixture = try await LookFixture()
    var count = 0
    fixture.editor.alignmentHaptic = { count += 1 }
    var interaction = TransparencyInteraction(haptic: fixture.editor.alignmentHaptic)
    interaction.drag(1.03, model: fixture.editor)
    interaction.drag(1.09, model: fixture.editor)
    interaction.drag(1.1, model: fixture.editor)
    #expect(count == 1)
    fixture.editor.end()
    try await fixture.close()
}

@Test @MainActor
func lookTrackProbeMeasuresTheActualTrackWithoutAccessibility() async throws {
    let fixture = try await LookFixture()
    let host = NSHostingView(rootView: LookPopoverView(model: fixture.editor))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 288, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    let track = try #require(fixture.editor.checkTrackView)
    #expect(track.window === window)
    #expect(track.bounds.width == 266 && track.bounds.height == 30)
    #expect(track.hitTest(NSPoint(x: 10, y: 10)) == nil)
    #expect(!track.isAccessibilityElement())
    let field = try #require(fixture.editor.checkFieldView)
    #expect(field.window === window)
    #expect(field.bounds.width == 264 && field.bounds.height == 232)
    #expect(field.hitTest(NSPoint(x: 10, y: 10)) == nil)
    #expect(!field.isAccessibilityElement())
    window.contentView = nil
    try await fixture.close()
}

@Test @MainActor
func lookCheckFocusProbesRouteArrowKeysToTheControls() async throws {
    let fixture = try await LookFixture()
    let host = NSHostingView(rootView: LookPopoverView(model: fixture.editor))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 288, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    let track = try #require(fixture.editor.checkTrackView)
    let grain = try #require(fixture.editor.checkGrainView)
    #expect(!track.acceptsFirstResponder && !grain.acceptsFirstResponder)
    #expect(fixture.editor.checkMenuView != nil)
    func arrow(_ code: UInt16) throws {
        let character = String(UnicodeScalar(code == 126 ? NSUpArrowFunctionKey : NSDownArrowFunctionKey)!)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code))
        window.sendEvent(event)
    }
    let focusView = try #require(track as? LookTrackProbeView)
    #expect(focusView.requestControlFocus())
    #expect(window.firstResponder !== focusView)
    #expect(!focusView.controlHasFocus)
    try await waitUntil { focusView.controlHasFocus }
    try arrow(126)
    #expect(abs(fixture.editor.transparency - 56) < 0.001)
    fixture.editor.setTransparency(100)
    try arrow(126)
    #expect(fixture.editor.look.glass)
    try arrow(125)
    #expect(!fixture.editor.look.glass && fixture.editor.look.opacity == 0)
    let grainFocus = try #require(grain as? LookTrackProbeView)
    #expect(grainFocus.requestControlFocus())
    #expect(window.firstResponder !== grainFocus)
    #expect(!grainFocus.controlHasFocus)
    try await waitUntil { grainFocus.controlHasFocus }
    try arrow(126)
    #expect(abs(fixture.editor.look.grain - 0.1) < 0.001)
    let returnFocus = try #require(track as? LookTrackProbeView)
    #expect(returnFocus.requestControlFocus())
    #expect(window.firstResponder !== returnFocus)
    #expect(!returnFocus.controlHasFocus)
    try await waitUntil { returnFocus.controlHasFocus }
    try arrow(126)
    #expect(fixture.editor.look.glass)
    window.contentView = nil
    try await fixture.close()
}
