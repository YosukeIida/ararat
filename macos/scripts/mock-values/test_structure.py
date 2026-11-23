import json
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest

from check_structure import check


def view(name, x=0, y=0, children=(), hidden=False, **attributes):
    return {"class": name, "frame": {"x": x, "y": y, "width": 16, "height": 16},
            "hidden": hidden, "children": children, **attributes}


class StructureTests(unittest.TestCase):
    def check_folder_capture(self, name):
        with TemporaryDirectory() as directory:
            sidecar = Path(directory) / "capture.json"
            sidecar.write_text(json.dumps({"screen": "folder-empty", "name": name,
                                           "windows": [{"root": view("NSView")}]}))
            script = Path(__file__).with_name("check_structure.py")
            return subprocess.run([sys.executable, "-B", str(script), "--screen", "folder-empty", str(sidecar)],
                                  capture_output=True, text=True, check=False)

    def test_missing_capture_exits_one(self):
        result = self.check_folder_capture("folder-empty-other")
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL folder-empty-line count", result.stdout)
        self.assertIn("missing capture", result.stdout)

    def test_count_mismatch_exits_one(self):
        result = self.check_folder_capture("folder-empty-line")
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL folder-empty-line count SidebarNoTabsRow", result.stdout)
        self.assertNotIn("missing capture", result.stdout)

    def test_passwords_captures_require_their_own_state_markers(self):
        rules = json.loads(Path(__file__).with_name("structure.json").read_text())
        rules = [rule for rule in rules if rule["capture"].startswith("settings-passwords-")]
        self.assertEqual(len(rules), 3)
        states = {
            "settings-passwords-locked": ("row-password-fill", "passwords-unlock"),
            "settings-passwords-search": ("row-password-fill", "passwords-search", "passwords-result"),
            "settings-passwords-detail": ("passwords-revealed",),
        }
        self.assertEqual({rule["capture"] for rule in rules}, set(states))
        for rule in rules:
            for name, identifiers in states.items():
                with self.subTest(capture=rule["capture"], identifiers=identifiers):
                    children = [view("SettingsMarkerView", identifier=name) for name in identifiers]
                    self.assertEqual(check(rule, {"windows": [{"root": view("NSView", children=children)}]}),
                                     rule["capture"] == name)

    def test_refusal_requires_the_message_and_hides_the_recorder(self):
        rule = {"kind": "contains", "members": [{"identifier": "message"}], "absent": [{"identifier": "recorder"}]}
        message = view("NSView", identifier="message")
        recorder = view("NSView", identifier="recorder")
        for children, expected in [([message], True), ([message, recorder], False), ([recorder], False),
                                   ([message, {**recorder, "hidden": True}], True)]:
            with self.subTest(children=children):
                self.assertEqual(check(rule, {"windows": [{"root": view("NSView", children=children)}]}), expected)

    def test_floating_sidebar_requires_insets_inside_its_container(self):
        rule = {"kind": "floating-sidebar", "inset": 5}
        frame = {"x": 15, "y": 25, "width": 60, "height": 90}
        for panel_frame, expected in [(frame, True), ({**frame, "height": 100}, False),
                                      ({**frame, "x": -45}, False)]:
            panel = view("SidebarPanelView", frame=panel_frame)
            owner = view("SidebarContainerView", frame={"x": 10, "y": 20, "width": 200, "height": 100},
                         children=[panel])
            with self.subTest(panel_frame=panel_frame):
                self.assertEqual(check(rule, {"windows": [{"root": owner}]}), expected)

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
        rule = {"kind": "contains", "members": [{"label": "Downloads"}, {"label": "Open in Library"}, {"class": "DownloadRowView"}]}
        header = view("NSStackView", children=[view("NSTextField", label="Downloads"), view("NSButton", label="Open in Library")])
        row = view("DownloadRowView")
        self.assertTrue(check(rule, {"windows": [{"root": view("NSView", children=[header, row])}]}))
        self.assertFalse(check(rule, {"windows": [{"root": header}, {"root": row}]}))

    def test_library_tile_centres_the_icon_and_label(self):
        rule = {"kind": "library-tile", "tiles": 1, "gap": 8}
        tile_frame = {"x": 12, "y": 46, "width": 88, "height": 80}
        icon = {"x": 45, "y": 87.5, "width": 22, "height": 22}
        label = {"x": 32, "y": 62.5, "width": 48, "height": 17}

        def tree(icon_frame, label_frame):
            stack = view("NSStackView", frame={"x": 32, "y": 62.5, "width": 48, "height": 47},
                         children=[view("LibraryRailTileIconView", frame=icon_frame), view("NSTextField", frame=label_frame)])
            tile = view("LibraryRailTileButton", frame=tile_frame, children=[stack])
            return {"windows": [{"root": view("NSView", children=[tile])}]}

        for icon_frame, label_frame, expected in [
                (icon, label, True),
                ({**icon, "y": icon["y"] + 2}, label, False),
                (icon, {**label, "y": label["y"] + 2}, False),
                ({**icon, "y": icon["y"] + 2}, {**label, "y": label["y"] + 2}, False),
                (icon, {**label, "x": label["x"] - 2}, False)]:
            with self.subTest(icon=icon_frame, label=label_frame):
                self.assertEqual(check(rule, tree(icon_frame, label_frame)), expected)
        bare = view("LibraryRailTileButton", frame=tile_frame)
        self.assertFalse(check(rule, {"windows": [{"root": view("NSView", children=[bare])}]}))

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
