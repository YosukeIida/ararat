#!/usr/bin/env python3
"""Tests for engine/scripts/release-watch, on recorded API responses.

Run: uv run --no-project python engine/scripts/tests/test_release_watch.py

The fixtures under fixtures/ were recorded on 2026-11-19:

  build-inputs.toml         a copy of engine/build-inputs.toml at the recording
  chromiumdash-stable.json  .../fetch_releases?channel=Stable&platform=Mac&num=6
  ungoogled-tags.json       api.github.com/repos/ungoogled-software/ungoogled-chromium/tags?per_page=20
  chromereleases-feed.json  chromereleases.googleblog.com/feeds/posts/default?alt=json&max-results=6

No test reaches the network. The script requests max-results=20. The six-entry
fixture keeps the same feed shape and omits the older desktop stable post and
its large CVE table. Hand-written entries cover the matching desktop posts.
"""

import importlib.machinery
import importlib.util
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime, timezone
from io import StringIO
from pathlib import Path
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
FIXTURES = HERE / "fixtures"
SCRIPT = HERE.parent / "release-watch"

# the script is loaded by path, which would otherwise leave a __pycache__ in
# engine/scripts beside a file that git tracks as a script
sys.dont_write_bytecode = True
_loader = importlib.machinery.SourceFileLoader("release_watch", str(SCRIPT))
_spec = importlib.util.spec_from_loader("release_watch", _loader)
rw = importlib.util.module_from_spec(_spec)
_loader.exec_module(rw)

RECORDED_STABLE_TIME = 1795028027121  # 2026-11-18, from the chromiumdash fixture
FIRST_UNPINNED_TIME = 1794426661554  # 157.0.8103.79


def fixture(name):
    return (FIXTURES / name).read_text()


def feed_entry(title, body, published="2026-11-17T10:00:00.000-08:00"):
    """One entry in the shape the Blogger JSON feed returns."""
    return {
        "title": {"$t": title},
        "published": {"$t": published},
        "content": {"$t": body},
    }


class FakeFetch:
    """Answers the script's URLs from the fixtures; fails on anything else."""

    def __init__(self, feed=None, releases=None):
        self.feed = feed
        self.releases = releases
        self.urls = []

    def __call__(self, url):
        self.urls.append(url)
        if url == rw.STABLE_URL:
            return json.dumps(self.releases) if self.releases is not None else fixture("chromiumdash-stable.json")
        if url == rw.TAGS_URL:
            return fixture("ungoogled-tags.json")
        if url == rw.FEED_URL:
            return json.dumps(self.feed) if self.feed is not None else fixture("chromereleases-feed.json")
        raise AssertionError(f"unexpected URL: {url}")


class BuildInputs(unittest.TestCase):
    def test_reads_the_pin_and_the_base_tag(self):
        inputs = rw.read_build_inputs(FIXTURES / "build-inputs.toml")
        self.assertEqual(inputs["chromium_version"], "157.0.8103.39")
        self.assertEqual(inputs["ungoogled_tag"], "157.0.8103.38-1")

    def test_this_tree_pins_a_tag_too(self):
        inputs = rw.read_build_inputs(SCRIPT.parents[1] / "build-inputs.toml")
        self.assertIn("ungoogled_tag", inputs)


class Versions(unittest.TestCase):
    def test_milestone_bumps_outrank_patch_bumps(self):
        self.assertLess(rw.version_key("157.0.8103.99"), rw.version_key("158.0.8127.18"))

    def test_tag_revision_breaks_a_tie(self):
        self.assertLess(rw.tag_key("157.0.8103.38-1"), rw.tag_key("157.0.8103.38-2"))

    def test_a_version_that_is_not_one_is_refused(self):
        with self.assertRaises(rw.WatchError):
            rw.version_key("157.0.8103")
        with self.assertRaises(rw.WatchError):
            rw.tag_key("master")


class Stable(unittest.TestCase):
    def test_ignores_another_platform_or_channel(self):
        payload = [
            {"channel": "Stable", "platform": "Linux", "version": "160.0.1.1", "time": 1},
            {"channel": "Beta", "platform": "Mac", "version": "160.0.1.2", "time": 1},
            {"channel": "Stable", "platform": "Mac", "version": "159.0.8154.13", "time": 2},
        ]
        self.assertEqual(rw.stable_releases(payload), [("159.0.8154.13", 2)])

    def test_refuses_a_page_without_a_stable_mac_release(self):
        with self.assertRaises(rw.WatchError):
            rw.stable_releases([{"channel": "Beta", "platform": "Mac", "version": "160.0.1.2", "time": 1}])

    def test_refuses_an_older_stable_release_without_a_time(self):
        releases = json.loads(fixture("chromiumdash-stable.json"))
        del releases[-1]["time"]
        with self.assertRaisesRegex(rw.WatchError, "no valid time"):
            rw.stable_releases(releases)


class Tags(unittest.TestCase):
    def test_takes_the_newest_tag_by_version(self):
        self.assertEqual(rw.pick_latest_tag(json.loads(fixture("ungoogled-tags.json"))), "157.0.8103.78-1")

    def test_position_in_the_list_does_not_decide(self):
        payload = json.loads(fixture("ungoogled-tags.json"))
        self.assertEqual(rw.pick_latest_tag(list(reversed(payload))), "157.0.8103.78-1")

    def test_refuses_a_page_of_non_version_tags(self):
        with self.assertRaises(rw.WatchError):
            rw.pick_latest_tag([{"name": "master"}])


class Security(unittest.TestCase):
    def test_an_early_stable_is_unknown(self):
        # the recorded feed names 159.0.8154.13 only in the early stable post,
        # which carries no CVE list
        feed = json.loads(fixture("chromereleases-feed.json"))
        self.assertEqual(rw.security_state(feed, {"159.0.8154.13"}), "unknown")

    def test_a_version_the_feed_has_left_behind_is_unknown(self):
        feed = json.loads(fixture("chromereleases-feed.json"))
        self.assertEqual(rw.security_state(feed, {"156.0.8078.80"}), "unknown")

    def test_a_stable_post_with_cves_is_true(self):
        feed = {
            "feed": {
                "entry": [
                    feed_entry(
                        rw.STABLE_DESKTOP_POST,
                        "The Stable channel has been updated to 157.0.8103.39 for Mac. "
                        "$5000 : High CVE-2026-1234: Use after free in Blink. "
                        "$3000 : Medium CVE-2026-5678: Out of bounds read in V8.",
                    )
                ]
            }
        }
        self.assertIs(rw.security_state(feed, {"157.0.8103.39"}), True)

    def test_a_stable_post_without_cves_is_false(self):
        feed = {
            "feed": {
                "entry": [
                    feed_entry(
                        rw.STABLE_DESKTOP_POST,
                        "The Stable channel has been updated to 157.0.8103.39 for Mac. "
                        "This update includes no security fixes.",
                    )
                ]
            }
        }
        self.assertIs(rw.security_state(feed, {"157.0.8103.39"}), False)

    def test_a_mac_patch_in_slash_notation_matches(self):
        feed = {"feed": {"entry": [
            feed_entry(
                rw.STABLE_DESKTOP_POST,
                "The Stable channel has been updated to 142.0.7444.175/.176 for Windows/Mac. "
                "CVE-2026-1234.",
            ),
        ]}}
        self.assertIs(rw.security_state(feed, {"142.0.7444.176"}), True)

    def test_a_post_for_another_version_is_not_read(self):
        feed = {
            "feed": {
                "entry": [
                    feed_entry(
                        rw.STABLE_DESKTOP_POST,
                        "The Stable channel has been updated to 157.0.8103.38 for Mac. "
                        "CVE-2026-1234: Use after free in Blink.",
                    )
                ]
            }
        }
        self.assertEqual(rw.security_state(feed, {"157.0.8103.39"}), "unknown")

    def test_a_beta_post_for_the_version_is_not_read(self):
        feed = {
            "feed": {
                "entry": [
                    feed_entry(
                        "Chrome Beta for Desktop Update",
                        "Beta has been updated to 157.0.8103.39. CVE-2026-1234 is listed.",
                    )
                ]
            }
        }
        self.assertEqual(rw.security_state(feed, {"157.0.8103.39"}), "unknown")

    def test_a_release_whose_version_run_on_is_not_a_match(self):
        feed = {
            "feed": {
                "entry": [
                    feed_entry(
                        rw.STABLE_DESKTOP_POST,
                        "The Stable channel has been updated to 157.0.8103.390 for Mac. CVE-2026-1: x.",
                    )
                ]
            }
        }
        self.assertEqual(rw.security_state(feed, {"157.0.8103.39"}), "unknown")


class Run(unittest.TestCase):
    def inputs(self, pinned, base_tag):
        handle = tempfile.NamedTemporaryFile("w", suffix=".toml", delete=False)
        with handle as stream:
            stream.write(f'chromium_version = "{pinned}"\nungoogled_tag = "{base_tag}"\n')
        self.addCleanup(Path(handle.name).unlink)
        return Path(handle.name)

    def two_days_later(self):
        return datetime.fromtimestamp(RECORDED_STABLE_TIME / 1000 + 2.5 * 86_400, tz=timezone.utc)

    def test_behind_in_chromium_on_the_recorded_responses(self):
        fetch = FakeFetch()
        now = self.two_days_later()
        first_unpinned = datetime.fromtimestamp(FIRST_UNPINNED_TIME / 1000, tz=timezone.utc)
        report, code = rw.run(fetch, FIXTURES / "build-inputs.toml", now=now)
        self.assertEqual(code, 10)
        self.assertEqual(
            report,
            {
                "pinned": "157.0.8103.39",
                "stable": "159.0.8154.13",
                "base_tag_pinned": "157.0.8103.38-1",
                "base_tag_latest": "157.0.8103.78-1",
                "behind_days": (now - first_unpinned).days,
                "security": "unknown",
            },
        )
        self.assertEqual(fetch.urls, [rw.STABLE_URL, rw.TAGS_URL, rw.FEED_URL])

    def test_a_new_release_does_not_reset_the_lag(self):
        releases = json.loads(fixture("chromiumdash-stable.json"))
        inputs = FIXTURES / "build-inputs.toml"
        before, _ = rw.run(FakeFetch(releases=releases[1:]), inputs, now=self.two_days_later())
        after, _ = rw.run(FakeFetch(releases=releases[::-1]), inputs, now=self.two_days_later())
        self.assertEqual(before["stable"], "158.0.8127.37")
        self.assertEqual(after["stable"], "159.0.8154.13")
        self.assertEqual(before["behind_days"], after["behind_days"])

    def test_security_includes_older_unpinned_releases(self):
        releases = json.loads(fixture("chromiumdash-stable.json"))
        stable_posts = [
            feed_entry(rw.STABLE_DESKTOP_POST, f"Updated to {entry['version']} for Mac.")
            for entry in releases
        ]
        pinned_cve = feed_entry(rw.STABLE_DESKTOP_POST, "Updated to 157.0.8103.39 for Mac. CVE-2026-1234.")
        older_cve = feed_entry(rw.STABLE_DESKTOP_POST, "Updated to 157.0.8103.79 for Mac. CVE-2026-1234.")
        sentence_final_cve = feed_entry(rw.STABLE_DESKTOP_POST, "Updated to 157.0.8103.79. CVE-2026-1234.")
        scenarios = [
            ("only pinned release has CVEs", [pinned_cve], "unknown"),
            ("all unpinned releases have no CVEs", stable_posts, False),
            ("one release has no CVEs and the others are unknown", stable_posts[-1:], "unknown"),
            ("older release has CVEs and newest is unknown", [older_cve], True),
            ("older release version ends a sentence", [sentence_final_cve], True),
            ("older release has CVEs and newest has none", [stable_posts[0], older_cve], True),
        ]
        for label, entries, expected in scenarios:
            with self.subTest(label):
                fetch = FakeFetch({"feed": {"entry": entries}})
                report, _ = rw.run(fetch, FIXTURES / "build-inputs.toml")
                self.assertEqual(report["security"], expected)

    def test_nothing_new_is_zero(self):
        report, code = rw.run(
            FakeFetch(), self.inputs("159.0.8154.13", "157.0.8103.78-1"), now=self.two_days_later()
        )
        self.assertEqual(code, 0)
        self.assertEqual(report["behind_days"], 0)
        self.assertEqual(report["security"], "unknown")

    def test_a_newer_base_tag_alone_is_ten(self):
        report, code = rw.run(
            FakeFetch(), self.inputs("159.0.8154.13", "157.0.8103.38-1"), now=self.two_days_later()
        )
        self.assertEqual(code, 10)
        self.assertEqual(report["base_tag_latest"], "157.0.8103.78-1")
        self.assertEqual(report["behind_days"], 0)

    def test_a_pin_ahead_of_stable_is_nothing_new(self):
        report, code = rw.run(
            FakeFetch(), self.inputs("160.0.8157.0", "157.0.8103.78-1"), now=self.two_days_later()
        )
        self.assertEqual(code, 0)
        self.assertEqual(report["behind_days"], 0)

    def test_a_manifest_without_the_tag_is_refused(self):
        path = self.inputs("157.0.8103.39", "")
        with self.assertRaises(rw.WatchError):
            rw.run(FakeFetch(), path)

    def test_a_network_failure_surfaces_as_a_watch_error(self):
        def broken(url):
            raise rw.WatchError(f"{url}: timed out")

        with self.assertRaises(rw.WatchError):
            rw.run(broken, FIXTURES / "build-inputs.toml")

    def test_a_response_that_is_not_json_is_refused(self):
        with self.assertRaises(rw.WatchError):
            rw.load_json("<html>not found</html>", rw.STABLE_URL)

    def test_malformed_feeds_exit_two_with_a_message(self):
        malformed = [
            [],
            {"feed": []},
            {"feed": {}},
            {"feed": {"entry": {}}},
            {"feed": {"entry": [None]}},
            {"feed": {"entry": [{"title": "bad", "content": {"$t": "body"}}]}},
            {"feed": {"entry": [{"title": {"$t": rw.STABLE_DESKTOP_POST}, "content": "bad"}]}},
            {"feed": {"entry": [feed_entry(1, "body")]}},
            {"feed": {"entry": [feed_entry(rw.STABLE_DESKTOP_POST, None)]}},
            {"feed": {"entry": [
                feed_entry(rw.STABLE_DESKTOP_POST, "Updated to 159.0.8154.13 for Mac. CVE-2026-1234."),
                {},
            ]}},
        ]
        for feed in malformed:
            with self.subTest(feed):
                error = StringIO()
                with (
                    patch.object(rw, "http_get", FakeFetch(feed)),
                    patch.dict(rw.os.environ, {"ARARAT_BUILD_INPUTS": str(FIXTURES / "build-inputs.toml")}),
                    redirect_stderr(error),
                    redirect_stdout(StringIO()) as output,
                ):
                    self.assertEqual(rw.main([]), 2)
                self.assertIn("Chrome Releases feed", error.getvalue())
                self.assertEqual(output.getvalue(), "")

    def test_invalid_utf8_exits_two_with_a_message(self):
        error = StringIO()
        with (
            patch.object(rw.urllib.request, "urlopen") as urlopen,
            patch.dict(rw.os.environ, {"ARARAT_BUILD_INPUTS": str(FIXTURES / "build-inputs.toml")}),
            redirect_stderr(error),
        ):
            urlopen.return_value.__enter__.return_value.read.return_value = b"\xff"
            self.assertEqual(rw.main([]), 2)
        self.assertIn("UTF-8", error.getvalue())


if __name__ == "__main__":
    unittest.main(verbosity=2)
