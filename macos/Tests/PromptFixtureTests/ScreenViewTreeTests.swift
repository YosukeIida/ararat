import AppKit
import XCTest
@testable import Ararat

@MainActor
final class ScreenViewTreeTests: XCTestCase {
    func testCaptureIncludesAccessibilityAndInheritedVisibility() async throws {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 160))
        let parent = NSView(frame: NSRect(x: 12, y: 14, width: 100, height: 80))
        let button = NSButton(frame: NSRect(x: 3, y: 5, width: 32, height: 24))
        button.setAccessibilityLabel("Library")
        button.setAccessibilityRole(.button)
        root.addSubview(parent)
        parent.addSubview(button)
        parent.isHidden = true

        let tree = ScreenViewTree.Node(root)
        let child = try XCTUnwrap(tree.children.first?.children.first)
        XCTAssertEqual(child.role, "AXButton")
        XCTAssertEqual(child.label, "Library")
        XCTAssertEqual(child.frame, ["x": 15, "y": 19, "width": 32, "height": 24])
        XCTAssertTrue(child.hidden)
    }
}
