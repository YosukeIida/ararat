import Testing
@testable import Ararat

// U27i M1: with Ararat in the background no window is key, and the root's own window may have
// closed; a menu command or the global shortcut must still act on a window that is usable.
@Test @MainActor
func aCommandFindsAUsableWindowWhenNoWindowIsKey() {
    let root = Runtime()
    let child = Runtime()
    child.root = root
    root.children = [child]
    #expect(Runtime.commandWindow(key: nil, regular: [child], root: root) === child)
    // The key window wins even when another window is usable.
    let other = Runtime()
    other.root = root
    #expect(Runtime.commandWindow(key: other, regular: [child], root: root) === other)
    // With no browser window open at all, the root is the last resort (U27h's limit).
    #expect(Runtime.commandWindow(key: nil, regular: [], root: root) === root)
}
