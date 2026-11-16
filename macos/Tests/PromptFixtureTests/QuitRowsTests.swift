import Foundation
import Testing
@testable import Ararat

private let quitWindow: [String: Any] = [
    "id": "w", "shown_space": "s", "selected": "t", "history": ["t"], "space_history": ["s"],
    "changed_at": 100, "frame": NSNull(), "sidebar_width": NSNull(), "sidebar_hidden": false,
]

private func quitRows(_ window: [String: Any]) throws -> [[String]] {
    let body = try JSONSerialization.data(withJSONObject: window, options: [.sortedKeys])
    return [["item", "t", "unchanged"], ["last_selected", "t", "100"],
            ["window", "w", String(decoding: body, as: UTF8.self)]]
}

@Test(arguments: ["frame", "sidebar_width", "sidebar_hidden"])
func quitRowsAllowOnlyPresentationSaves(_ field: String) throws {
    let before = try quitRows(quitWindow)
    var window = quitWindow
    let values: [String: Any] = ["frame": ["x": 0, "y": 450, "width": 800, "height": 600],
                                 "sidebar_width": 240, "sidebar_hidden": true]
    window[field] = values[field]
    window["changed_at"] = 200
    #expect(quitRowsUnchanged(before, try quitRows(window)))
    #expect(quitRowsUnchanged(before, before))
}

@Test(arguments: ["id", "shown_space", "selected", "history", "space_history", "changed_at", "future_field"])
func quitRowsRejectOtherWindowWrites(_ field: String) throws {
    let before = try quitRows(quitWindow)
    var window = quitWindow
    window[field] = "changed"
    #expect(!quitRowsUnchanged(before, try quitRows(window)))
    if field != "changed_at" {
        window["frame"] = ["x": 0, "y": 450, "width": 800, "height": 600]
        window["changed_at"] = 200
        #expect(!quitRowsUnchanged(before, try quitRows(window)))
    }
}

@Test func quitRowsKeepEveryOtherRowStrict() throws {
    let before = try quitRows(quitWindow)
    var window = quitWindow
    window["sidebar_width"] = 240
    window["changed_at"] = 200
    let saved = try quitRows(window)
    for index in before.indices {
        var after = saved
        after[index][1] = "different-id"
        #expect(!quitRowsUnchanged(before, after))
        #expect(!quitRowsUnchanged(before, Array(saved.enumerated().filter { $0.offset != index }.map(\.element))))
    }
    for index in 0...1 {
        var after = saved
        after[index][2] = "changed"
        #expect(!quitRowsUnchanged(before, after))
    }
    #expect(!quitRowsUnchanged(before, saved + [["journal", "1", "write"]]))
    #expect(!quitRowsUnchanged(before, nil))
    #expect(!quitRowsUnchanged(nil, saved))
    #expect(!quitRowsUnchanged([["window", "w", "invalid"]], [["window", "w", "{}"]]))
    #expect(!quitRowsUnchanged([["window"]], [["window"]]))
}
