"""Save a labelled side-by-side PNG with the mock at left and the VM capture at right."""

import argparse
import base64
from html import escape
from pathlib import Path
import subprocess
import tempfile

from chrome_screenshot import CHROME, png_size, screenshot


def panel(label, path, size):
    data = base64.b64encode(path.read_bytes()).decode("ascii")
    width, height = size
    return (f'<section style="width:{width}px"><header>{escape(label)}</header>'
            f'<img width="{width}" height="{height}" src="data:image/png;base64,{data}"></section>')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mock", type=Path)
    parser.add_argument("capture", type=Path)
    parser.add_argument("--chrome", type=Path, default=CHROME)
    args = parser.parse_args()

    try:
        left = png_size(args.mock)
        right = png_size(args.capture)
        html = """<!doctype html><meta charset="utf-8">
<style>
body { margin:16px; background:#ececec; color:#1d1d1f; font:14px system-ui,sans-serif; }
main { display:flex; gap:16px; }
header { height:32px; line-height:24px; font-weight:600; overflow:hidden; white-space:nowrap; text-overflow:ellipsis; }
section { flex:none; }
img { display:block; }
</style><main>"""
        html += panel("Mock · " + args.mock.name, args.mock, left)
        html += panel("Ararat VM · " + args.capture.name, args.capture, right) + "</main>"
        destination = Path(tempfile.mkdtemp(prefix="ararat-mock-sheet-")) / "comparison.png"
        screenshot(args.chrome, html, destination,
                   (left[0] + right[0] + 48, max(left[1], right[1]) + 64))
        print(destination)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        parser.exit(1, f"{parser.prog}: {error}\n")


if __name__ == "__main__":
    main()
