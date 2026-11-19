"""Check named VM captures against the U20 structure table."""

import argparse
import json
from pathlib import Path


def visible(node, ancestors=()):
    if node["hidden"]:
        return
    frame = node["frame"]
    path = (*ancestors, node)
    if frame["width"] > 0 and frame["height"] > 0:
        yield path
    for child in node["children"]:
        yield from visible(child, path)


def check(rule, capture):
    paths = [path for window in capture["windows"] for path in visible(window["root"])]
    if not paths:
        return False

    def by_class(name):
        return [path for path in paths if path[-1]["class"] == name]

    def inside(path, name):
        return any(node["class"] == name for node in path[:-1])

    match rule["kind"]:
        case "split-row":
            rows = by_class("SidebarRowView")
            segments = by_class("SplitSegmentButton")
            for row in rows:
                members = [path[-1]["frame"] for path in segments if any(node is row[-1] for node in path[:-1])]
                if len(members) != rule["segments"]:
                    continue
                members.sort(key=lambda rect: rect["x"])
                if max(rect["y"] for rect in members) - min(rect["y"] for rect in members) > 1:
                    continue
                if all(a["x"] + a["width"] <= b["x"] for a, b in zip(members, members[1:])):
                    return True
            return False
        case "split-chrome":
            headers = by_class("SidebarHeaderView")
            fields = by_class("URLFieldBackgroundButton")
            return (len(headers) == len(fields) == 1 and inside(headers[0], "SidebarPanelView")
                    and inside(fields[0], "SidebarView") and bool(by_class("SplitDividerView"))
                    and all(path[-1].get("role") != "AXToolbar" or inside(path, "SidebarView") for path in paths))
        case "library-dock":
            dock = by_class("SpaceDockView")
            library = [path for path in by_class("DownloadsButton") if path[-1].get("label") == "Library"]
            if len(dock) != 1 or len(library) != 1 or not inside(library[0], "SidebarView"):
                return False
            sidebar = next(node["frame"] for node in library[0] if node["class"] == "SidebarView")
            button, cells = library[0][-1]["frame"], dock[0][-1]["frame"]
            return (0 <= button["y"] - sidebar["y"] <= 32 and button["x"] < cells["x"]
                    and button["y"] < cells["y"] + cells["height"]
                    and cells["y"] < button["y"] + button["height"])
        case "url-field":
            field = by_class("URLFieldBackgroundButton")
            if len(field) != 1:
                return False
            labels = {path[-1].get("label") for path in paths if any(node is field[0][-1] for node in path[:-1])}
            return {"Copy Link", "Site controls"} <= labels
        case "count":
            return len(by_class(rule["class"])) == rule["count"]
        case "floating-sidebar":
            panels = by_class("SidebarPanelView")
            if len(panels) != 1:
                return False
            panel = panels[0][-1]["frame"]
            owner = next((node["frame"] for node in reversed(panels[0][:-1])
                          if node["class"] == "SidebarContainerView"), None)
            if owner is None:
                return False
            gaps = [panel["x"] - owner["x"], panel["y"] - owner["y"],
                    owner["y"] + owner["height"] - panel["y"] - panel["height"]]
            return all(abs(gap - rule["inset"]) <= 1 for gap in gaps)
        case "contains":
            def matches(node, selector):
                return all(node.get(key) == value for key, value in selector.items())

            selector = rule.get("container")
            containers = ([path[-1] for path in paths if matches(path[-1], selector)]
                          if selector else [window["root"] for window in capture["windows"]])
            if not containers:
                return False
            for container in containers:
                descendants = [path[-1] for path in paths if any(ancestor is container for ancestor in path[:-1])]
                if not all(any(matches(node, member) for node in descendants) for member in rule["members"]):
                    return False
                if any(matches(node, member) for node in descendants for member in rule.get("absent", [])):
                    return False
            return True
        case _:
            raise ValueError(f"Unknown rule: {rule['kind']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sidecars", nargs="+", type=Path)
    parser.add_argument("--screen", action="append", help="Only require captures from this screen check (repeatable)")
    args = parser.parse_args()

    rules = json.loads(Path(__file__).with_name("structure.json").read_text())
    if args.screen:
        rules = [rule for rule in rules if any(rule["capture"].startswith(f"{name}-") for name in args.screen)]
    if not rules:
        parser.error("No structure expectations for the requested screen checks")

    captures = {}
    for path in args.sidecars:
        data = json.loads(path.read_text())
        if args.screen and data["screen"] not in args.screen:
            continue
        if data["name"] in captures:
            parser.error(f"Multiple captures for {data['name']}; provide one run per screen")
        captures[data["name"]] = data

    failed = False
    for rule in rules:
        capture = captures.get(rule["capture"])
        ok = capture is not None and check(rule, capture)
        detail = rule.get("class", rule.get("segments", ""))
        print(f"{'PASS' if ok else 'FAIL'} {rule['capture']} {rule['kind']} {detail} ({rule['source']})"
              + (" — missing capture" if capture is None else ""))
        failed |= not ok
    return int(failed)


if __name__ == "__main__":
    raise SystemExit(main())
