import Testing
@testable import Ararat

@Test func pageOnlyTraceOmitsTabMetadataAndDeviceRows() {
    let rows = [
        ["space", "s", #"{"title":"Work"}"#],
        ["item", "t", #"{"title":"Private title","kind":{"Tab":{"url":"https://example.test/secret","saved_title":"Secret"}}}"#],
        ["window", "w", "{}"], ["last_selected", "l", "{}"],
    ]
    #expect(pageOnlyTraceRows(rows) == [["kind": "space", "id": "s", "title": "Work"], ["kind": "item", "id": "t"]])
    #expect(pageOnlyTraceRows(nil) == nil)
}
