"""Count candidate CSS declarations before reviewing their applicability to built surfaces."""

import argparse
from html.parser import HTMLParser
import json
from pathlib import Path
import re

PROPERTY = re.compile(
    r"(?:[\w-]*(?:width|height|radius|color|shadow)|(?:row-|column-)?gap|"
    r"(?:padding|margin|inset)(?:-[\w-]+)?|font(?:-size|-weight)?|line-height|"
    r"background(?:-[\w-]+)?|top|right|left|bottom|opacity|filter|--[\w-]+)"
)
DECLARATION = re.compile(r"(?:^|;)\s*([-\w]+)\s*:\s*((?:\([^)]*\)|[^;])*)")


class MockCSS(HTMLParser):
    def __init__(self):
        super().__init__()
        self.in_style = False
        self.values = set()

    def handle_starttag(self, tag, attrs):
        if tag == "style":
            self.in_style = True
        style = dict(attrs).get("style")
        if style:
            self.add(self.getpos()[0], f"<{tag} style>", style)

    def handle_endtag(self, tag):
        if tag == "style":
            self.in_style = False

    def handle_data(self, data):
        if self.in_style:
            for block in re.finditer(r"([^{}]+)\{([^{}]+)\}", data):
                line = self.getpos()[0] + data.count("\n", 0, block.start(2))
                selector = re.sub(r"/\*.*?\*/", "", block[1], flags=re.S).strip()
                self.add(line, selector, block[2])

    def add(self, line, selector, style):
        for declaration in DECLARATION.finditer(style):
            prop, value = declaration.groups()
            if PROPERTY.fullmatch(prop):
                self.values.add((line + style.count("\n", 0, declaration.start(1)), selector, prop, value.strip()))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project", type=Path)
    args = parser.parse_args()

    pages = sorted(args.project.glob("*.dc.html"))
    if not pages:
        parser.error(f"No .dc.html pages in {args.project}")
    candidates = set()
    for page in pages:
        css = MockCSS()
        css.feed(page.read_text())
        candidates.update((f"{page.name}:{line}", selector, prop, value) for line, selector, prop, value in css.values)

    root = Path(__file__).resolve().parents[3]
    table = json.loads((root / "docs/research/mock-values.json").read_text())
    reviewed = {(row["source"], row["selector"], row["property"], row["css"]) for row in table}
    if missing := reviewed - candidates:
        for declaration in sorted(missing):
            print("Source not found:", *declaration)
        return 1

    print(f"{len(pages)} pages, {len(candidates)} candidate declarations, {len(reviewed)} reviewed declarations")
    print(f"{len(candidates - reviewed)} candidate declarations still require triage")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
