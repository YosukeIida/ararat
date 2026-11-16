import AraratEngineAPI
import Foundation
import ObjectiveC.runtime
import Testing
@testable import Ararat

@MainActor private final class PageOnlyBaselineTab: NSObject {
    @objc dynamic var itemId: String?
    @objc dynamic var url = "https://example.test/new"
    @objc dynamic var title = "New"
    @objc dynamic var isLoading = false
    @objc dynamic var navigationCount: UInt = 1
}

@MainActor private final class PageOnlyBaselineHost: NSObject {
    var entries: [PageOnlyBaselineTab] = []
    @objc func tabs() -> [Any] { entries }
}

@Test @MainActor
func pageOnlyBaselineWaitsForEveryRegularTabsStoredMetadata() {
    class_addProtocol(PageOnlyBaselineHost.self, objc_getProtocol("ARWindowHostAPI")!)
    class_addProtocol(PageOnlyBaselineTab.self, objc_getProtocol("ARTabAPI")!)
    let runtime = Runtime(), child = Runtime()
    runtime.children = [child]
    let host = PageOnlyBaselineHost(), childHost = PageOnlyBaselineHost()
    runtime.host = host as! any ARWindowHostAPI
    child.host = childHost as! any ARWindowHostAPI
    let rootTab = PageOnlyBaselineTab(), childTab = PageOnlyBaselineTab()
    rootTab.itemId = "root"; childTab.itemId = "child"
    host.entries = [rootTab]; childHost.entries = [childTab]
    let matching = #"{"kind":{"Tab":{"url":"https://example.test/new","saved_title":"New"}}}"#
    let lagging = #"{"kind":{"Tab":{"url":"https://example.test/old","saved_title":"Old"}}}"#
    let before = [["item", "root", matching], ["item", "child", lagging]]
    #expect(!runtime.setPageOnlyBaseline(before))
    #expect(runtime.quitBefore == nil)
    let after = [["item", "root", matching], ["item", "child", matching]]
    childHost.entries = []
    #expect(!runtime.setPageOnlyBaseline(after))
    childHost.entries = [childTab]
    childTab.isLoading = true
    #expect(!runtime.setPageOnlyBaseline(after))
    #expect(runtime.quitBefore == nil)
    childTab.isLoading = false
    #expect(runtime.setPageOnlyBaseline(after))
    #expect(runtime.quitBefore == after)
    #expect(!pageOnlyRowsUnchanged(before, after))
}

@Test func pageOnlyDiffNamesMetadataChangesWithoutExposingTheirValues() {
    let before = [["item", "t", #"{"kind":{"Tab":{"url":"https://example.test/old","saved_title":"Old private title"}}}"#]]
    let after = [["item", "t", #"{"kind":{"Tab":{"url":"https://example.test/new","saved_title":"New private title"}}}"#]]
    let diff = pageOnlyTraceDiff(before, after)
    #expect(diff.count == 1)
    #expect(diff.first?["fields"] as? [String] == ["kind"])
    #expect(diff.first?["tab_fields"] as? [String] == ["url", "saved_title"])
    #expect(Set(diff.first?.keys.map { $0 } ?? []) == Set(["kind", "id", "fields", "tab_fields"]))
    #expect(pageOnlyTraceDiff(before, before).isEmpty)
    #expect(!pageOnlyRowsUnchanged(before, after))
    #expect(pageOnlyRowsUnchanged(before, before))
}

@Test func pageOnlyTraceOmitsTabMetadataAndDeviceRows() {
    let rows = [
        ["space", "s", #"{"title":"Work"}"#],
        ["item", "t", #"{"title":"Private title","kind":{"Tab":{"url":"https://example.test/secret","saved_title":"Secret"}}}"#],
        ["window", "w", "{}"], ["last_selected", "l", "{}"],
    ]
    #expect(pageOnlyTraceRows(rows) == [["kind": "space", "id": "s", "title": "Work"], ["kind": "item", "id": "t"]])
    #expect(pageOnlyTraceRows(nil) == nil)
}
