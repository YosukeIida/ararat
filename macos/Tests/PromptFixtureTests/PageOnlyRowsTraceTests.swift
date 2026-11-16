import Testing
@testable import Ararat

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
