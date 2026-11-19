"""Capture local HTML in a disposable Chrome profile."""

from pathlib import Path
import struct
import subprocess
import tempfile


CHROME = Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")


def png_size(path):
    with path.open("rb") as file:
        header = file.read(24)
    if len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
        raise ValueError(f"Expected a PNG with an IHDR chunk: {path}")
    width, height = struct.unpack(">II", header[16:24])
    if not width or not height:
        raise ValueError(f"Empty PNG: {path}")
    return width, height


def screenshot(chrome, html, output, size, marker=None):
    width, height = size
    needs_crop = width < 500 or height < 200
    if needs_crop:
        # sips treats a zero crop offset as centered. Reserve one column to crop from x=1.
        html += """<script>
window.addEventListener('load', () => { document.documentElement.style.transform = 'translateX(1px)'; });
</script>"""
    with tempfile.TemporaryDirectory(prefix="ararat-mock-browser-") as tmp:
        root = Path(tmp)
        page = root / "page.html"
        shot = root / "capture.png"
        page.write_text(html, encoding="utf-8")
        command = [
            str(chrome.resolve(strict=True)),
            "--headless", "--no-first-run", "--disable-background-networking",
            "--host-resolver-rules=MAP * ~NOTFOUND", "--hide-scrollbars",
            "--force-device-scale-factor=1", "--virtual-time-budget=1000",
            f"--user-data-dir={root / 'profile'}",
            f"--window-size={max(500, width + int(needs_crop))},{max(200, height)}",
            f"--screenshot={shot}", page.as_uri(),
        ]
        if marker is not None:
            command.insert(-1, "--dump-dom")
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=45)
        if result.returncode or not shot.is_file():
            raise ValueError(result.stderr.decode(errors="replace").strip() or "Chrome did not write a PNG")
        if marker is not None and marker.encode() not in result.stdout:
            raise ValueError("The requested mock element has no rendered bounds")
        if png_size(shot) == size:
            output.write_bytes(shot.read_bytes())
        else:
            subprocess.run(
                ["/usr/bin/sips", "-c", str(height), str(width), "--cropOffset", "0", "1",
                 str(shot), "--out", str(output)],
                check=True, stdout=subprocess.DEVNULL, timeout=15,
            )
        if png_size(output) != size:
            raise ValueError(f"Expected {width}×{height} pixels: {output}")
