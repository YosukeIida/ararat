"""Render a U20 board at the dimensions of a VM PNG or a specified viewport."""

import argparse
from html import escape
import json
from pathlib import Path
import re
import subprocess
import tempfile

from chrome_screenshot import CHROME, png_size, screenshot


def viewport(text):
    match = re.fullmatch(r"([1-9]\d*)x([1-9]\d*)", text)
    if match is None:
        raise argparse.ArgumentTypeError("Use WIDTHxHEIGHT in pixels")
    return tuple(map(int, match.groups()))


def prepare(page, size, selector):
    width, height = size
    source = page.read_text(encoding="utf-8")
    base = escape(page.parent.as_uri() + "/", quote=True)
    source, edits = re.subn(r"(<head\b[^>]*>)", rf'\1<base href="{base}">', source, count=1, flags=re.I)
    if edits != 1:
        raise ValueError(f"Missing HTML head: {page}")
    target = json.dumps(selector).replace("<", r"\u003c")
    script = f"""
<style>
html {{ overflow:hidden; background:#fff; }}
body {{ margin:0 !important; overflow:visible !important; }}
x-dc {{ display:block; width:max-content; }}
*,*::before,*::after {{ animation:none !important; transition:none !important; }}
</style>
<script>
window.addEventListener('load', () => {{
    const target = document.querySelector({target});
    if (!target) return;
    const r = target.getBoundingClientRect();
    if (!r.width || !r.height) return;
    const scale = Math.min({width} / r.width, {height} / r.height);
    document.body.style.clipPath = 'polygon(' +
        r.left + 'px ' + r.top + 'px,' + r.right + 'px ' + r.top + 'px,' +
        r.right + 'px ' + r.bottom + 'px,' + r.left + 'px ' + r.bottom + 'px)';
    document.body.style.transformOrigin = '0 0';
    document.body.style.transform = 'scale(' + scale + ') translate(' + -r.x + 'px,' + -r.y + 'px)';
    document.documentElement.dataset.mockRendered = 'yes';
}});
</script>
"""
    source, edits = re.subn(r"</body\s*>", lambda _: script + "</body>", source, count=1, flags=re.I)
    if edits != 1:
        raise ValueError(f"Missing HTML body: {page}")
    return source


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pages", nargs="+", type=Path)
    size = parser.add_mutually_exclusive_group(required=True)
    size.add_argument("--capture", type=Path, help="A VM PNG whose pixel dimensions set the output size")
    size.add_argument("--size", type=viewport, help="Use WIDTHxHEIGHT when no VM PNG exists")
    parser.add_argument("--selector", default="x-dc",
                        help="CSS selector for the board or an individual specimen")
    parser.add_argument("--chrome", type=Path, default=CHROME)
    args = parser.parse_args()

    try:
        dimensions = png_size(args.capture) if args.capture else args.size
        destination = Path(tempfile.mkdtemp(prefix="ararat-mock-pngs-"))
        for index, page in enumerate(args.pages, start=1):
            page = page.resolve(strict=True)
            filename = page.name.removesuffix(".dc.html")
            output = destination / f"{index:02d}-{filename}.png"
            screenshot(args.chrome, prepare(page, dimensions, args.selector), output, dimensions,
                       marker='data-mock-rendered="yes"')
            print(output, flush=True)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        parser.exit(1, f"{parser.prog}: {error}\n")


if __name__ == "__main__":
    main()
