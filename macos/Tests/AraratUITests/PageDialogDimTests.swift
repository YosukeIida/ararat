import AppKit
import AraratKit
import Testing

@Test @MainActor func pageDialogDimTracksEachPaneAndRemovesOnlyTheDismissedDialog() {
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    let dim = PageDialogDim()
    let left = NSRect(x: 0, y: 0, width: 400, height: 600)
    let right = NSRect(x: 400, y: 0, width: 400, height: 600)
    dim.update("left", container: container, frame: left, visible: true)
    dim.update("right", container: container, frame: right, visible: true)
    #expect(container.subviews.map(\.frame) == [left, right])
    let resized = NSRect(x: 0, y: 0, width: 480, height: 600)
    dim.update("left", container: container, frame: resized, visible: true)
    #expect(container.subviews.map(\.frame) == [resized, right])
    dim.update("left", container: nil, frame: .zero, visible: false)
    #expect(container.subviews.map(\.frame) == [right])
}

@Test @MainActor func pageDialogDimUsesTheMockOpacityInEachAppearance() {
    let container = NSView()
    let dim = PageDialogDim()
    container.appearance = NSAppearance(named: .aqua)
    dim.update("tab", container: container, frame: .zero, visible: true)
    let overlay = container.subviews.first
    #expect(abs((overlay?.layer?.backgroundColor?.alpha ?? 0) - 0.06) < 0.001)
    container.appearance = NSAppearance(named: .darkAqua)
    #expect(abs((overlay?.layer?.backgroundColor?.alpha ?? 0) - 0.25) < 0.001)
}
