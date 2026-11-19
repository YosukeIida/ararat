import AppKit
@testable import AraratKit
import Testing
@testable import AraratUI

@Test @MainActor
func sidebarRowReportsLoadingAndAudioAndSpeakerDoesNotSelect() {
    _ = NSApplication.shared
    func row(_ kind: RowKind) -> Row {
        Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: "item", title: "Item", url: nil, depth: 0, kind: kind, unloaded: false, lastSelectedAt: nil)
    }
    func state(_ loading: Bool, _ audible: Bool, _ muted: Bool) -> EngineAdapter.RowState {
        EngineAdapter.RowState(loading: loading, audible: audible, muted: muted, canGoBack: false, canGoForward: false)
    }
    var selections = 0
    var mutes: [Bool] = []
    let view = SidebarRowView(row: row(.tab), selected: false) { _ in selections += 1 }
    view.onMute = { _, value in mutes.append(value) }
    view.status = state(true, true, false)
    #expect(view.loadingVisible)
    #expect(view.audioLabel == "Mute Tab")
    #expect((view.accessibilityValue() as? String)?.contains("Loading") == true)
    #expect((view.accessibilityValue() as? String)?.contains("Playing audio") == true)
    #expect(view.accessibilityCustomActions()?.contains { $0.name == "Mute Tab" } == true)
    view.pressAudioForCheck()
    #expect(mutes == [true] && selections == 0)
    view.status = state(false, false, true)
    #expect(!view.loadingVisible && view.audioLabel == "Unmute Tab")
    #expect((view.accessibilityValue() as? String)?.contains("Muted") == true)
    view.pressAudioForCheck()
    #expect(mutes == [true, false] && selections == 0)
    for kind in [RowKind.folder, .split] {
        view.update(row: row(kind), selected: false)
        view.status = state(true, true, false)
        #expect(!view.loadingVisible && view.audioLabel == nil)
    }
    let favorite = FavoriteTile(row: row(.tab)) { _ in }
    #expect(favorite.glyphLabel.stringValue == "I")
    #expect(!favorite.subviews.contains { $0 is NSProgressIndicator })
    view.update(row: row(.tab), selected: false)
    view.crashed = true
    #expect(!view.loadingVisible)
}
