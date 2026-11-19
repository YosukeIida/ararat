import unittest

from check_structure import check


def view(name, x=0, y=0, children=(), hidden=False, **attributes):
    return {"class": name, "frame": {"x": x, "y": y, "width": 16, "height": 16},
            "hidden": hidden, "children": children, **attributes}


class StructureTests(unittest.TestCase):
    def test_required_parts_belong_to_each_visible_container(self):
        rule = {"kind": "contains", "container": {"class": "CommandBarRowView"},
                "members": [{"identifier": "icon"}, {"identifier": "title"}]}
        icon = view("NSImageView", identifier="icon")
        title = view("NSTextField", identifier="title")
        complete = view("CommandBarRowView", children=[icon, view("NSView", children=[title])])
        incomplete = view("CommandBarRowView", children=[icon])
        hidden_title = view("CommandBarRowView", children=[icon, {**title, "hidden": True}])

        for children, expected in [([complete], True), ([incomplete, title], False),
                                   ([complete, incomplete], False), ([hidden_title], False), ([icon, title], False)]:
            with self.subTest(children=children):
                self.assertEqual(check(rule, {"windows": [{"root": view("NSView", children=children)}]}), expected)

    def test_required_parts_without_a_container_use_the_window_root(self):
        rule = {"kind": "contains", "members": [{"label": "Open Library"}, {"class": "DownloadRowView"}]}
        header = view("DownloadsHeaderButton", label="Open Library")
        row = view("DownloadRowView")
        self.assertTrue(check(rule, {"windows": [{"root": view("NSView", children=[header, row])}]}))
        self.assertFalse(check(rule, {"windows": [{"root": header}, {"root": row}]}))

    def test_split_members_must_share_a_visible_row_and_not_overlap(self):
        first = view("SplitSegmentButton")
        second = view("SplitSegmentButton", x=18)
        single_row = view("SidebarRowView", children=[view("NSStackView", children=[first, second])])
        two_rows = view("NSView", children=[view("SidebarRowView", children=[part]) for part in [first, second]])
        hidden_row = view("SidebarRowView", children=[first, second], hidden=True)
        overlapping_row = view("SidebarRowView", children=[first, view("SplitSegmentButton", x=2)])

        rule = {"kind": "split-row", "segments": 2}
        for root, expected in [(single_row, True), (two_rows, False), (hidden_row, False), (overlapping_row, False)]:
            self.assertEqual(check(rule, {"windows": [{"root": root}]}), expected)


if __name__ == "__main__":
    unittest.main()
