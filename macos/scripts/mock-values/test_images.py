import struct
import tempfile
import unittest
from pathlib import Path

from chrome_screenshot import png_size
from render_mock import prepare


class ImageTests(unittest.TestCase):
    def test_read_pixel_dimensions_and_reject_non_png(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "image.png"
            path.write_bytes(b"\x89PNG\r\n\x1a\n" + struct.pack(">I4sII", 13, b"IHDR", 320, 240))
            self.assertEqual(png_size(path), (320, 240))
            path.write_bytes(b"")
            with self.assertRaisesRegex(ValueError, "Expected a PNG"):
                png_size(path)

    def test_preserve_asset_base_and_escape_selector(self):
        with tempfile.TemporaryDirectory(prefix="mock source ") as tmp:
            path = Path(tmp) / "board.dc.html"
            path.write_text("<html><head></head><body><x-dc>Mock</x-dc></body></html>")
            page = prepare(path, (320, 240), '[aria-label="</script>"]')
            self.assertIn(f'<base href="{path.parent.as_uri()}/">', page)
            self.assertIn(r'\u003c/script>', page)
            self.assertIn("Math.min(320 / r.width, 240 / r.height)", page)


if __name__ == "__main__":
    unittest.main()
