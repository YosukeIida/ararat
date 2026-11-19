import unittest

from check_structure import check


def view(name, x=0, y=0, children=(), hidden=False):
    return {"class": name, "frame": {"x": x, "y": y, "width": 16, "height": 16},
            "hidden": hidden, "children": children}


class StructureTests(unittest.TestCase):
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
