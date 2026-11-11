import AppKit
import AraratKit
import Testing

@Test @MainActor func permissionDimTracksEachPaneAndRemovesOnlyTheDismissedSheet() {
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    let dim = PermissionDim()
    let left = NSRect(x: 0, y: 0, width: 400, height: 600)
    let right = NSRect(x: 400, y: 0, width: 400, height: 600)
    dim.update("left", container: container, frame: left, visible: true)
    dim.update("right", container: container, frame: right, visible: true)
    #expect(container.subviews.map(\.frame) == [left, right])
    let resized = NSRect(x: 0, y: 0, width: 480, height: 600)
    dim.update("left", container: container, frame: resized, visible: true)
    #expect(container.subviews.map(\.frame) == [resized, right])
    dim.update("left", container: container, frame: .zero, visible: false)
    #expect(container.subviews.map(\.frame) == [right])
}
