# Engine patch set

`series` is the only source of patch order; paths in it are relative to this
directory, ungoogled/generic before ungoogled/macos. The 25 vendored patches
are byte-for-byte copies from the two commits below; the 26th is our
counter-patch and sits directly after the one hunk it reverses.

| Source | Commit | Chromium |
|---|---|---|
| ungoogled-software/ungoogled-chromium | 28a211ab4ab6b83d919966a4f58a6df23cf4fb29 | 156.0.8078.79 |
| ungoogled-software/ungoogled-chromium-macos | 31f01756a43d55b2c4211e73ca329bfab4ebfcb2 | 156.0.8078.79 |

Both projects are BSD-3-Clause; their LICENSE files are kept unchanged at
`ungoogled/generic/LICENSE` and `ungoogled/macos/LICENSE`.

## The 25 plus the counter-patch, in series order

| # | File in `series` | Origin |
|---|---|---|
| 1 | `ungoogled/generic/upstream-fixes/missing-dependencies.patch` | generic, upstream-fixes |
| 2 | `ungoogled/generic/core/inox-patchset/0003-disable-autofill-download-manager.patch` | generic, core/inox-patchset |
| 3 | `ungoogled/generic/core/inox-patchset/0021-disable-rlz.patch` | generic, core/inox-patchset |
| 4 | `ungoogled/generic/core/iridium-browser/safe_browsing-disable-incident-reporting.patch` | generic, core/iridium-browser |
| 5 | `ungoogled/generic/core/ungoogled-chromium/disable-crash-reporter.patch` | generic, core |
| 6 | `ungoogled/generic/core/ungoogled-chromium/disable-google-host-detection.patch` | generic, core |
| 7 | `ungoogled/generic/core/ungoogled-chromium/toggle-translation-via-switch.patch` | generic, core |
| 8 | `ungoogled/generic/core/ungoogled-chromium/disable-profile-avatar-downloading.patch` | generic, core |
| 9 | `ungoogled/generic/core/ungoogled-chromium/disable-gcm.patch` | generic, core |
| 10 | `ungoogled/generic/core/ungoogled-chromium/disable-domain-reliability.patch` | generic, core |
| 11 | `ungoogled/generic/core/ungoogled-chromium/disable-gaia.patch` | generic, core |
| 12 | `ungoogled/generic/core/ungoogled-chromium/disable-fonts-googleapis-references.patch` | generic, core |
| 13 | `ungoogled/generic/core/ungoogled-chromium/disable-webrtc-log-uploader.patch` | generic, core |
| 14 | `ungoogled/generic/core/ungoogled-chromium/disable-ai.patch` | generic, core |
| 15 | `ungoogled/generic/core/ungoogled-chromium/disable-network-time-tracker.patch` | generic, core |
| 16 | `ungoogled/generic/core/ungoogled-chromium/block-requests.patch` | generic, core |
| 17 | `ararat/restore-component-updater.patch` | ours |
| 18 | `ungoogled/generic/core/ungoogled-chromium/remove-navigation-source-param.patch` | generic, core |
| 19 | `ungoogled/generic/core/bromite/disable-fetching-field-trials.patch` | generic, core/bromite |
| 20 | `ungoogled/generic/extra/ungoogled-chromium/disable-intranet-redirect-detector.patch` | generic, extra |
| 21 | `ungoogled/generic/extra/ungoogled-chromium/fix-building-without-mdns-and-service-discovery.patch` | generic, extra |
| 22 | `ungoogled/generic/extra/ungoogled-chromium/disable-dial-repeating-discovery.patch` | generic, extra |
| 23 | `ungoogled/generic/extra/ungoogled-chromium/add-credits.patch` | generic, extra |
| 24 | `ungoogled/generic/extra/ungoogled-chromium/disable-ai-search-shortcuts.patch` | generic, extra |
| 25 | `ungoogled/macos/ungoogled-chromium/macos/disable-crashpad-handler.patch` | macos |
| 26 | `ungoogled/macos/ungoogled-chromium/macos/add-local-network-usage-description.patch` | macos |

## Why these 25

Every per-patch keep/skip/counter-patch decision and its security consequence
is in `docs/research/ungoogled-inventory.md` §8.

## Notes on the counter-patch

`ararat/restore-component-updater.patch` reverses only `block-requests`'s hunk
in `components/update_client/update_checker.cc`, so the component updater
performs its network update checks again; every other hunk of that patch stays
in force. Google Safe Browsing likewise stays in the build:
`fix-building-without-safebrowsing` is not vendored and `engine/args.gn` does
not set `safe_browsing_mode=0` (no API key is set either way).
