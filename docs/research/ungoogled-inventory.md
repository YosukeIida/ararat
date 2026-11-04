# ungoogled-chromium inventory for Ararat (2026-11-05)

Input to docs/architecture.md §4.1 (base patch set row), §4.2 (inventory and one measured rebase) and §4.7/§4.9.
Every number in sections 1–5 is **measured** from the clones below unless marked *estimate*. Section 6 holds the estimates.

## 1. Sources

| Repo | Clone path | Commit | Date | Targets |
|---|---|---|---|---|
| ungoogled-software/ungoogled-chromium (master, `--depth 1`) | `~/chromium-build/ungoogled/ungoogled-chromium` | `28a211ab4ab6b83d919966a4f58a6df23cf4fb29` | 2026-10-30 | `chromium_version.txt` = **156.0.8078.79**, `revision.txt` = 1 (tag `156.0.8078.79-1`) |
| ungoogled-software/ungoogled-chromium-macos (master, `--depth 1`) | `~/chromium-build/ungoogled/ungoogled-chromium-macos` | `31f01756a43d55b2c4211e73ca329bfab4ebfcb2` | 2026-11-03 | submodule `ungoogled-chromium` pinned to `28a211ab…` (same as above) → **156.0.8078.79**, `revision.txt` = 1 |
| ungoogled-chromium PR #4032 "Update to Chromium 157.0.8103.38" (open, mergeable, updated 2026-11-04) | fetched as local branch `pr-4032` in the first clone | `de09e0c70c6bc1ac83d4ecdfd0e82c7e250c9a3c` | — | **157.0.8103.38** |
| Our stock checkout (read only, not modified) | `~/chromium-build/src` | `9a31f0acec1854d44e49a73fbf8017598151a583` | 2026-11-02 | **157.0.8103.39** (shallow, no tags) |

Open tracking issues upstream: #4036 "Updating to Chromium 157.0.8103.39 on macOS" (opened 2026-11-03), #4035 (Linux, .38), #4037 (Windows, .39).
The macOS repo has no 157 branch or PR yet; its macOS-specific patch `fix-gn-compatibility-chromium-156.patch` is version-named.

## 2. Patch series counts

Counted from `patches/series` (comments and blank lines excluded) and each patch file: `+`/`-` lines exclude the `+++`/`---` headers; hunks = `@@` lines; files = distinct `+++` targets.

### ungoogled-chromium (generic), 110 patches

| Group | Patches | +lines | −lines | Hunks | Files |
|---|---:|---:|---:|---:|---:|
| upstream-fixes | 2 | 9 | 1 | 8 | 8 |
| core/inox-patchset | 5 | 15 | 208 | 29 | 17 |
| core/iridium-browser | 2 | 8 | 109 | 6 | 6 |
| core/ungoogled-chromium | 28 | 369 | 8,105 | 945 | 481 |
| core/bromite | 1 | 4 | 23 | 5 | 2 |
| extra/ungoogled-chromium | 58 | 1,449 | 707 | 354 | 165 |
| extra/inox-patchset | 5 | 27 | 98 | 22 | 17 |
| extra/debian | 1 | 0 | 14 | 1 | 1 |
| extra/iridium-browser | 5 | 14 | 30 | 5 | 5 |
| extra/bromite | 3 | 330 | 5 | 50 | 26 |
| **core total** | **36** | 396 | 8,445 | 985 | — |
| **extra total** | **72** | 1,820 | 854 | 432 | — |
| **Total** | **110** | **2,225** | **9,300** | **1,425** | **690** distinct |

Their own definition (`docs/design.md`): **core** = background requests, Google-service code, prebuilt binaries; "must be kept up-to-date with all of the changes in Chromium". **extra** = control/transparency features; "not guaranteed to persist across updates".

Hunks concentrate in three core patches (hunks / files / +/−):

| Patch | Hunks | Files | + | − |
|---|---:|---:|---:|---:|
| core/ungoogled-chromium/remove-unused-preferences-fields | 459 | 231 | 94 | 3,412 |
| core/ungoogled-chromium/fix-building-without-safebrowsing | 216 | 127 | 56 | 1,892 |
| core/ungoogled-chromium/disable-ai | 116 | 60 | 10 | 664 |
| extra/ungoogled-chromium/remove-uneeded-ui | 47 | 31 | 31 | 270 |
| extra/ungoogled-chromium/add-suggestions-url-field | 38 | 13 | 102 | 29 |

These three core patches are 791 of 1,425 hunks (56 %).

### ungoogled-chromium-macos, 27 patches (all under `ungoogled-chromium/macos/`)

| Patches | +lines | −lines | Hunks | Files |
|---:|---:|---:|---:|---:|
| 27 | 530 | 1,096 | 235 | 133 |

Mostly build-toolchain fixes (bindgen, rust, clang checks, dsymutil, typescript/esbuild, GN compatibility) plus `fix-disabling-safebrowsing`, `fix-disable-verification-token`, `disable-crashpad-handler`, `set-bundle-identifier`, `add-local-network-usage-description`.

Combined series applied for a macOS build: **137 patches, 1,660 hunks**.

### Lists

| File | Lines |
|---|---:|
| `pruning.list` (files deleted from the tree, mostly prebuilt binaries) | 14,135 |
| `domain_substitution.list` (files whose Google domains are rewritten) | 17,862 |
| `domain_regex.list` (substitution rules) | 21 |

### Flags

- GN args added: `flags.gn` 18 lines (e.g. `safe_browsing_mode=0`, `enable_reporting=false`, `enable_mdns=false`, `enable_service_discovery=false`, `enable_remoting=false`, `enable_hangout_services_extension=false`, `disable_fieldtrial_testing_config=true`, `google_api_key=""`, `use_official_google_api_keys=false`, `chrome_pgo_phase=0`, `enable_widevine=true`); macOS `flags.macos.gn` 18 lines (17 args + 1 comment) (official build, ThinLTO, `chrome_pgo_phase=2`, `proprietary_codecs=true`, `ffmpeg_branding="Chrome"`, `enable_updater=false`, `symbol_level=1`, …). `chrome_pgo_phase` is set in both: 0 in the generic file, 2 in the macOS file, which wins for macOS builds (relevant to §4.7's PGO line).
- Runtime flags: `docs/flags.md` has **52** entries in three groups: command-line switches (with `chrome://flags` entries), feature flags passed via `--enable-features`, and `chrome://flags` entries for existing Chromium switches; each group split into all-platform and desktop-only tables.

## 3. Overlap with Ararat's own layer

Path matches on each patch's target files (a patch can appear in several rows). Ararat's layer: `chrome/browser/ui` (no `BrowserView`, our `BrowserWindow`, seam implementations), tab strip, omnibox (command bar via `ARAutocomplete`), profiles, extensions (window semantics, popups), sync, Safe Browsing (replaced by our reputation check, §14), component updater.

| Area | Generic patches | macOS patches | Notable patches |
|---|---:|---:|---|
| `chrome/browser/ui/` | 36 | 2 | remove-unused-preferences-fields (42 files), fix-building-without-safebrowsing (15), disable-ai (15), remove-uneeded-ui (7), and ~20 `extra` UI flags (hover cards, tab close buttons, grab handle, scroll tabs, avatar button, window buttons, extensions menu, fullscreen exit UI, close confirmation, close window with last tab, paste-and-go new tab button, reload menu, bookmark bar NTP, QR generator, incognito themes, crashed bubble, first-run page) |
| Tab strip | 7 | 0 | add-flag-for-tab-hover-cards, add-flag-to-hide-tab-close-buttons, add-flag-for-grab-handle, add-flag-to-close-window-with-last-tab, enable-paste-and-go-new-tab-button, remove-uneeded-ui, disable-ai |
| Omnibox / search engines / autocomplete | 10 | 0 | add-suggestions-url-field (10 files), add-flag-for-omnibox-autocomplete-filtering, add-flag-for-search-engine-collection, prepopulated-search-engines, replace-google-search-engine-with-nosearch, disable-ai-search-shortcuts, block-trk-and-subdomains |
| Profiles | 7 | 1 | remove-unused-preferences-fields (23), disable-ai (5), fix-building-without-safebrowsing (3), 0006-modify-default-prefs, disable-profile-avatar-downloading; macOS fix-disable-verification-token |
| Extensions | 11 | 1 | extensions-manifestv2, disable-webstore-urls, 0005-disable-default-extensions, add-flag-to-configure-extension-downloading, add-flag-to-hide-extensions-menu, fix-building-without-safebrowsing (20) |
| Sync | 2 | 1 | remove-unused-preferences-fields (10), fix-building-without-safebrowsing (1) |
| Safe Browsing | 5 | 1 | fix-building-without-safebrowsing (24), remove-unused-preferences-fields (57), two iridium safe_browsing reporting patches, inox 0001 |
| Component updater | 6 | 1 | 0015-disable-update-pings, disable-webstore-urls, disable-ai, fix-building-without-safebrowsing |

Note: the "profiles" and "sync" rows match on path substrings (`profile`, `sync`), so they slightly over-match.

Domain substitution also rewrites files in these areas (entries in `domain_substitution.list`): `chrome/browser/ui/` 486 (of which `ui/views/tabs/` 6), `chrome/browser/extensions/` 132, `extensions/` 95, `components/omnibox/` 78, `components/safe_browsing/` 42, `components/sync*` 27, `chrome/browser/profiles/` 16, `components/component_updater/` 1. Pruning touches these areas almost not at all (`chrome/browser/ui/` 1, `components/safe_browsing/` 3).

Observations (measured facts, conclusions left to the inventory in §4.2):
- Almost all `chrome/browser/ui` and tab-strip patches in `extra` act on Chrome's `BrowserView`/Views tab strip/toolbar, which Ararat does not instantiate. They are candidates for the skip list rather than conflicts.
- The three large `core` patches (prefs removal, Safe Browsing removal, AI removal) cross `chrome/browser/ui`, profiles, extensions, sync and Safe Browsing at once. They are the ones whose skip/keep decision decides most of the hunk count Ararat inherits.
- `fix-building-without-safebrowsing` + `safe_browsing_mode=0` are the Safe Browsing removal §4.2 refers to.

## 4. Version gap and applicability check

- **Measured:** upstream master and the macOS repo target **156.0.8078.79**; our checkout is **157.0.8103.39**. The versions do not match, so `git apply --check` against a worktree of `~/chromium-build/src` was **not run** (per the task rule).
- **Measured:** the closest upstream work is PR #4032 at **157.0.8103.38** (one patch release below ours), still open. Also not run against our .39 tree, since the versions do not match exactly; .38 → .39 is a respin on the same branch (8103), so this PR is the natural candidate once it merges or if the owner allows a check against it.
- **Measured:** of the 690 files the 156 series touches, 663 exist in our 157 src git repo. The other 27: 17 are files the patches create (`components/ungoogled/*`, `*_flag_entries.h`, `trk_protocol_handler.*`, `referrer_sanitizer.*`, …); 8 live in DEPS sub-repos that a `git worktree` of `src` would not contain (`third_party/devtools-frontend` 5, `v8/` 3); `third_party/search_engines_data/.../prepopulated_engines.json` likewise; and `chrome/browser/enterprise/connectors/reporting/telomere_reporting_context.cc` does not exist in 157.
- Consequence for a future check (fact about the layout, not run): a `git worktree` of `src` alone cannot apply the series; patches into `v8/` and `third_party/devtools-frontend` need those sub-repos checked out too. Upstream applies to the release tarball (`chromium-<ver>-lite.tar.xz`, `downloads.ini`), where everything is one tree.
- **Measured (the 156 → 157 rebase, from PR #4032 vs master):** 70 files changed, +1,165 / −1,163.
  - Patches: 64 modified, 2 removed (`upstream-fixes/wasm-interpreter-fixes` landed upstream; `core/ungoogled-chromium/disable-tos-dialog` obsolete). 45 of the 64 changed only hunk offsets or headers (quilt refresh); **19 had content changes**.
  - Biggest content changes: remove-unused-preferences-fields (+351/−249), disable-ai (+142/−308), fix-building-without-safebrowsing (+101/−218), remove-uneeded-ui (+37/−40), add-flag-for-search-engine-collection (+37/−14), add-suggestions-url-field, disable-gcm.
  - Lists: `domain_substitution.list` +147 / −65 entries, `pruning.list` +133 / −2 entries.
  - Timing (upstream opens an "Updating to Chromium X" issue per platform automatically when stable updates; issue `createdAt` = stable date):

    | Update | Kind | Stable issue opened | PR opened | Merged | Stable → merged |
    |---|---|---|---|---|---|
    | 156.0.8078.47 | milestone bump | 2026-10-20 20:53Z | 2026-10-18 (before stable) | 2026-10-23 01:55Z | ~2.2 days |
    | 156.0.8078.73 | same-milestone respin | 2026-10-27 20:52Z | 2026-10-27 21:01Z | 2026-10-28 00:26Z | ~3.6 h |
    | 156.0.8078.79 | same-milestone respin | 2026-10-29 21:52Z | 2026-10-29 21:56Z | 2026-10-30 14:19Z | ~16.5 h |
    | 157.0.8103.38 | milestone bump | 2026-11-03 21:52Z (.39 on macOS) | 2026-11-01 (before stable) | open on 2026-11-05 | > ~1.5 days so far |

    macOS packaging lags the generic repo: the macOS repo took 156.0.8078.79 on 2026-11-03, four days after the generic merge (2026-10-30).

## 5. Their process for a version bump (from their docs)

Generic repo, `docs/developing.md` "Workflow of updating to a new Chromium version":
1. Download the source tarball (`utils/downloads.py retrieve/unpack -i downloads.ini`) or clone (`utils/clone.py`).
2. `devutils/update_lists.py -t build/src` regenerates `pruning.list` and `domain_substitution.list`.
3. With domain substitution **not** applied: `source devutils/set_quilt_vars.sh`, then `quilt push -a --refresh`; on failure `quilt push -f`, fix with `quilt edit/add/remove`, `quilt refresh`, repeat. Large removals are done line by line rather than by `#if 0`/comments, so `quilt refresh` stays reliable.
4. `quilt pop -a`, `devutils/validate_config.py`, `devutils/validate_patches.py -l build/src`.
5. After a failed build with substitution applied: `utils/domain_substitution.py revert`, fix patches, re-apply, rebuild.
6. PR to the generic repo; after merge, each platform repo is updated.

macOS repo, `README.md` "Updating": `devutils/update_patches.sh merge` (merges generic + macOS series), `set_quilt_vars.sh`, retrieve sources (`--all`, or `-g`/`-p` per phase), update the Rust toolchain to match `src/tools/rust/update_rust.py`'s `RUST_REVISION` (nightly date lookup), the same quilt loop, `validate_config.py`, `update_patches.sh unmerge`, `check_patch_files.sh`, commit.

Doc-vs-code inconsistency in upstream: `docs/developing.md` says new switches go into `third_party/ungoogled/ungoogled_switches.cc` by editing `resources/patches/ungoogled-chromium/add-third-party-ungoogled.patch`; the tree has no `resources/` directory, and the switches file is created as `components/ungoogled/ungoogled_switches.cc` by `patches/extra/ungoogled-chromium/add-components-ungoogled.patch`.

Their tools assume quilt with fuzz-tolerant refresh; Ararat's `series check` (§4.2) is no-fuzz byte comparison, so ungoogled releases would be imported as refreshed by them and then checked by us.

## 6. Estimates (not measured)

- *Estimate:* applying PR #4032's series to 157.0.8103.39 should need little or no work beyond what .38 needed, because .38 → .39 is a respin on branch 8103. Unverified until a `--check` is run on a full tree including DEPS sub-repos.
- *Estimate (from the timing table, n=2 and n=2):* the generic repo merges same-milestone respins within a day of stable and milestone bumps in about 2+ days; the macOS repo adds days on top (4 days for 156.0.8078.79). Waiting for the macOS repo would fit §4.9's 7-day limit but not its 48-hour limit for in-the-wild exploits; taking the generic series and carrying the 27 macOS patches ourselves removes the macOS lag.
- *Estimate:* if Ararat skips most `extra` UI patches (they target Views UI we do not instantiate), the inherited hunk count drops from 1,425 toward the core's ~985 plus macOS's 235; the three big core patches dominate either way and are also where 156 → 157 had most content changes.
- *Estimate:* domain substitution rewrites ~486 files under `chrome/browser/ui/` alone; any Ararat patch into those files must be authored against the substituted or the unsubstituted tree consistently. Upstream's rule is "patches against the unsubstituted tree".

## 7. What was not done

- No `git apply --check` (version mismatch: 156.0.8078.79 / 157.0.8103.38 vs 157.0.8103.39).
- No build, no `gclient`, `~/chromium-build/src` untouched.
- Per-patch decisions are in section 8.

## 8. Per-patch decisions


It uses the same clones and counting rule as sections 1–5 (hunks = lines starting with `@@` in each patch file).
The series are the 156.0.8078.79 ones; our base is 157.0.8103.39 (see section 8.5).

Decision rules used:

- **keep**: removes Google service traffic or telemetry, or is needed for our build, and conflicts with none of Ararat's needs (Web Store installs and updates, MV3, passkeys, autofill, permission prompts, DevTools, proprietary codecs, our reputation check, possibly Widevine, our own UI).
- **skip**: conflicts with a need, only touches Chrome UI that Ararat replaces, is an opt-in chrome://flags entry, or is a preference default our layer sets instead.
- **counter-patch**: kept, plus our own change that restores something it removes.
- **provisional**: depends on an open item, named in brackets and in section 8.4.

### 8.1 Summary

| Decision | Generic patches | Generic hunks | macOS patches | macOS hunks |
|---|---:|---:|---:|---:|
| keep | 22 | 227 | 2 | 4 |
| keep (provisional) | 3 | 19 | 1 | 8 |
| skip | 78 | 909 | 24 | 223 |
| skip (provisional) | 4 | 27 | 0 | 0 |
| counter-patch | 1 | 12 | 0 | 0 |
| counter-patch (provisional) | 2 | 231 | 0 | 0 |
| **Total** | **110** | **1,425** | **27** | **235** |

Hunks Ararat inherits from the imported series (our own counter-patch hunks not included):

| Case | Hunks |
|---|---:|
| Always kept (keep + counter-patch, both series) | 243 (242 after dropping the `update_checker.cc` hunk) |
| + domain substitution applied (`block-trk-and-subdomains`, `fix-learn-doubleclick-hsts`) | +18 |
| + Safe Browsing replaced by another source (`fix-building-without-safebrowsing`, inox `0001`, macOS `fix-disabling-safebrowsing`, `safe_browsing-disable-reporting-of-safebrowsing-over`) | +240 |
| + pruning applied (`fix-building-with-prunned-binaries`, `disable-mei-preload`, `disable-privacy-sandbox`) | +23 |
| + uBlock Origin (MV2) chosen (`extensions-manifestv2`) | +4 |
| Range: Google Safe Browsing, no substitution, no pruning, uBO Lite → everything provisional kept | 243 → 528 |

The full series for a macOS build is 1,660 hunks (section 2). The three largest core patches split three ways: `disable-ai` (116) is kept, `fix-building-without-safebrowsing` (216) depends on the Safe Browsing item, and `remove-unused-preferences-fields` (459) is skipped.

### 8.2 Per-patch decisions

#### 8.2.1 ungoogled-chromium (generic), 110 patches

| Patch | Hunks | Decision | Reason | Security consequence |
|---|---:|---|---|---|
| `upstream-fixes/missing-dependencies.patch` | 6 | keep | Adds missing GN deps and one include that the series needs to build. | none |
| `upstream-fixes/wasm-interpreter-fixes.patch` | 2 | skip | Landed upstream; absent from the 157 series (PR #4032), and our base is 157. | none |
| `core/inox-patchset/0001-fix-building-without-safebrowsing.patch` | 15 | counter-patch (provisional: Safe Browsing) | Build fix for `safe_browsing_mode=0`; it also stops reading the file-type-policies component, which our download UI needs. | Removes dynamic download file-type danger levels and the SSL-interstitial extension event; restore the file-type read (section 8.3). |
| `core/inox-patchset/0003-disable-autofill-download-manager.patch` | 5 | keep | Stops autofill crowdsourcing queries and uploads to Google; local autofill heuristics still work. | none |
| `core/inox-patchset/0005-disable-default-extensions.patch` | 6 | skip | Its `webstore_installer.cc` hunks remove the Web Store download and install path; the in-app-payments hunks are branding-gated and the Web Store app hunk is feature-gated (`kWebstoreHostedApp`). | Skipping keeps verified Web Store installs (§9). |
| `core/inox-patchset/0015-disable-update-pings.patch` | 1 | skip | Edits `chrome/updater`, which `enable_updater=false` does not build; Sparkle replaces it. | none |
| `core/inox-patchset/0021-disable-rlz.patch` | 2 | keep | Turns off RLZ (promotion tracking) at build level; two small hunks. | none |
| `core/iridium-browser/safe_browsing-disable-incident-reporting.patch` | 5 | keep | Stops incident and extended-reporting uploads to Google; reporting only. | none |
| `core/iridium-browser/safe_browsing-disable-reporting-of-safebrowsing-over.patch` | 1 | keep (provisional: Safe Browsing) | Removes the client-side phishing detector's verdict request to Google. | With Google Safe Browsing, client-side phishing detection can no longer block a page; with another source, none. |
| `core/ungoogled-chromium/disable-crash-reporter.patch` | 4 | keep | Stops crash uploads to Google and, on macOS, Crashpad entirely. | none (no local crash dumps either; see section 8.4) |
| `core/ungoogled-chromium/disable-google-host-detection.patch` | 22 | keep | Removes X-Client-Data headers and Google-only request handling. | Policy-forced SafeSearch/YouTube restrict and Google bound-session cookies stop working; no effect without enterprise policy or Chrome sign-in. |
| `core/ungoogled-chromium/replace-google-search-engine-with-nosearch.patch` | 1 | skip | Search engine defaults are a preference our layer sets; the file is in a DEPS sub-repo. | none |
| `core/ungoogled-chromium/toggle-translation-via-switch.patch` | 9 | keep | Stops fetching Google's translate script unless a switch names a script URL. | none |
| `core/ungoogled-chromium/disable-untraceable-urls.patch` | 3 | skip | Edits `rlz/lib`, which `disable-rlz` already removes from the build (unverified, section 8.5). | none |
| `core/ungoogled-chromium/disable-profile-avatar-downloading.patch` | 1 | keep | Stops avatar downloads from gstatic. | none |
| `core/ungoogled-chromium/disable-gcm.patch` | 10 | keep | Stops GCM check-in and the MCS connection to Google. | none (Web Push stops working; section 8.4) |
| `core/ungoogled-chromium/disable-domain-reliability.patch` | 9 | keep | Stops Domain Reliability beacons to Google. | none |
| `core/ungoogled-chromium/block-trk-and-subdomains.patch` | 17 | keep (provisional: domain substitution) | Blocks `trk:` and `*.qjz9zk` URLs, the safety net for domain substitution; useless without it. | none |
| `core/ungoogled-chromium/disable-gaia.patch` | 1 | keep | Stops Gaia auth fetches. | none |
| `core/ungoogled-chromium/disable-fonts-googleapis-references.patch` | 6 | keep | Stops reader-mode font loads from fonts.googleapis.com; four of six hunks are in non-shipping docs. | none |
| `core/ungoogled-chromium/disable-webstore-urls.patch` | 13 | skip | Removes all extension update checks, the Web Store install download and content verification for store extensions. | Skipping keeps extension auto-updates, content verification and the Web Store's dedicated process. |
| `core/ungoogled-chromium/fix-learn-doubleclick-hsts.patch` | 1 | keep (provisional: domain substitution) | Only needed so domain substitution does not break the HSTS generator. | none |
| `core/ungoogled-chromium/disable-webrtc-log-uploader.patch` | 4 | keep | Stops WebRTC log uploads to Google. | none |
| `core/ungoogled-chromium/disable-ai.patch` | 116 | keep | Removes Gemini (Glic), ScreenAI and other AI features that talk to Google or download models. | ML-based quiet permission prompts go; PDF OCR and accessibility annotations go. |
| `core/ungoogled-chromium/fix-building-with-prunned-binaries.patch` | 19 | skip (provisional: pruning) | Only needed when `pruning.list` deletes prebuilt files; they exist in our checkout. | none |
| `core/ungoogled-chromium/disable-network-time-tracker.patch` | 1 | keep | Stops time queries to Google. | Certificate errors caused by a wrong system clock are no longer identified as such. |
| `core/ungoogled-chromium/disable-mei-preload.patch` | 3 | skip (provisional: pruning) | Only needed when the preload data file is pruned; it is local data, no traffic. | none |
| `core/ungoogled-chromium/fix-building-without-safebrowsing.patch` | 216 | counter-patch (provisional: Safe Browsing) | Removes Safe Browsing from the build; with another reputation source we keep it but restore what §9 and our download UI need. | Removes URL/download reputation checks, the extension kill switch (Safe Browsing and Omaha attributes) and file-type danger levels; section 8.3 restores the last two. |
| `core/ungoogled-chromium/remove-unused-preferences-fields.patch` | 459 | skip | Deletes Safe Browsing and sign-in prefs from the Preferences file; the traffic they gate is already stopped by disable-gaia and the empty API key. Largest patch (459 hunks). | Skipping keeps the prefs; leaked-password checks still need a Google API key and stay off. |
| `core/ungoogled-chromium/block-requests.patch` | 12 | counter-patch | Stops NTP, profile-reset, affiliation and DevTools fetches, but its `update_checker.cc` hunk disables the component updater. | Without the counter-patch CRLSet, PKI metadata (root store, CT log list), file-type policies and Widevine never update. |
| `core/ungoogled-chromium/disable-privacy-sandbox.patch` | 1 | skip (provisional: pruning) | Only needed when the attestations file is pruned. | none |
| `core/ungoogled-chromium/doh-changes.patch` | 4 | skip | Default-preference change: Secure DNS off and the automatic DoH upgrade disabled. | Skipping keeps automatic DNS-over-HTTPS upgrade. |
| `core/ungoogled-chromium/extensions-manifestv2.patch` | 4 | skip (provisional: content blocker) | Removes MV2 deprecation handling; only useful if the owner picks uBlock Origin (MV2). | none |
| `core/ungoogled-chromium/remove-f1-shortcut.patch` | 1 | skip | Edits Chrome's accelerator table, which our host replaces. | none |
| `core/ungoogled-chromium/move-js-optimizer-unfamiliar-sites.patch` | 6 | skip | Exists only because `remove-unused-preferences-fields` removes the Safe Browsing prefs. | none |
| `core/ungoogled-chromium/remove-navigation-source-param.patch` | 1 | keep | Stops adding the `source=chrome.ob` tracking parameter to search URLs. | none |
| `core/ungoogled-chromium/disable-tos-dialog.patch` | 1 | skip | Absent from the 157 series (obsolete). | none |
| `core/bromite/disable-fetching-field-trials.patch` | 5 | keep | Stops variations seed fetches; four of five hunks are Android Java and inert. | none |
| `extra/ungoogled-chromium/add-ungoogled-flag-headers.patch` | 7 | skip | Infrastructure for the chrome://flags entries; needed only if a flag patch is kept. | none |
| `extra/inox-patchset/0006-modify-default-prefs.patch` | 13 | skip | Preference defaults; it turns off autofill, the password manager and payments, which Ararat needs. | Skipping keeps password and autofill on; privacy defaults move to our layer (section 8.3). |
| `extra/inox-patchset/0008-restore-classic-ntp.patch` | 3 | skip | New tab page is our UI. | none |
| `extra/inox-patchset/0013-disable-missing-key-warning.patch` | 1 | skip | Startup infobar in Chrome's UI. | none |
| `extra/inox-patchset/0016-chromium-sandbox-pie.patch` | 1 | skip | Linux only; revisit for the Linux port. | none |
| `extra/inox-patchset/0019-disable-battery-status-service.patch` | 4 | skip | Web API behaviour choice, not Google traffic. | Skipping keeps the Battery Status API visible to pages (fingerprinting surface). |
| `extra/debian/disable/google-api-warning.patch` | 1 | skip | Startup infobar in Chrome's UI. | none |
| `extra/iridium-browser/mime_util-force-text-x-suse-ymp-to-be-downloaded.patch` | 1 | skip | Irrelevant on macOS. | none |
| `extra/iridium-browser/prefs-always-prompt-for-download-directory-by-defaul.patch` | 1 | skip | Preference default; our downloads UI decides. | none |
| `extra/iridium-browser/updater-disable-auto-update.patch` | 1 | skip | Edits `app_controller_mac.mm`, which we replace (§4.5). | none |
| `extra/iridium-browser/Remove-EV-certificates.patch` | 1 | skip | Display choice; EV is not shown differently in current Chrome. | none |
| `extra/iridium-browser/browser-disable-profile-auto-import-on-first-run.patch` | 1 | skip | First-run import is suppressed by our layer; import is ours (§9). | none |
| `extra/bromite/fingerprinting-flags-client-rects-and-measuretext.patch` | 27 | skip | Opt-in flag, not Google traffic. | none |
| `extra/bromite/flag-max-connections-per-host.patch` | 9 | skip | Opt-in flag. | none |
| `extra/bromite/flag-fingerprinting-canvas-image-data-noise.patch` | 14 | skip | Opt-in flag. | none |
| `extra/ungoogled-chromium/add-components-ungoogled.patch` | 3 | skip | Switch infrastructure for the bromite flags. | none |
| `extra/ungoogled-chromium/disable-formatting-in-omnibox.patch` | 2 | skip | Omnibox/status bubble UI we replace. | none |
| `extra/ungoogled-chromium/add-ipv6-probing-option.patch` | 6 | skip | Replaces the IPv6 reachability check with a constant; the check sends no packets to Google. | none |
| `extra/ungoogled-chromium/remove-disable-setuid-sandbox-as-bad-flag.patch` | 1 | skip | Linux bad-flags infobar. | none |
| `extra/ungoogled-chromium/disable-intranet-redirect-detector.patch` | 1 | keep | Stops random-hostname DNS probes at startup. | none |
| `extra/ungoogled-chromium/disable-download-quarantine.patch` | 9 | skip | Removes download quarantine. | Skipping keeps the macOS quarantine attribute, so Gatekeeper checks downloaded apps. |
| `extra/ungoogled-chromium/fix-building-without-mdns-and-service-discovery.patch` | 10 | keep | Build fix for `enable_mdns=false` and `enable_service_discovery=false` in `flags.gn`. | none |
| `extra/ungoogled-chromium/add-flag-to-configure-extension-downloading.patch` | 8 | skip | Opt-in flag. | none |
| `extra/ungoogled-chromium/add-flag-for-search-engine-collection.patch` | 10 | skip | Opt-in flag. | none |
| `extra/ungoogled-chromium/add-flag-to-disable-beforeunload.patch` | 3 | skip | Opt-in flag. | none |
| `extra/ungoogled-chromium/add-flag-to-force-punycode-hostnames.patch` | 3 | skip | Opt-in flag; our UI formats URLs itself. | none |
| `extra/ungoogled-chromium/add-flag-to-show-avatar-button.patch` | 3 | skip | Chrome toolbar UI. | none |
| `extra/ungoogled-chromium/add-suggestions-url-field.patch` | 38 | skip | chrome://settings search engine editor; our command bar has its own (section 8.5). | none |
| `extra/ungoogled-chromium/add-flag-to-hide-crashed-bubble.patch` | 2 | skip | Chrome UI. | none |
| `extra/ungoogled-chromium/add-flag-to-scroll-tabs.patch` | 7 | skip | Chrome tab strip UI. | none |
| `extra/ungoogled-chromium/enable-paste-and-go-new-tab-button.patch` | 3 | skip | Chrome tab strip UI. | none |
| `extra/ungoogled-chromium/add-flag-for-bookmark-bar-ntp.patch` | 4 | skip | Chrome bookmark bar UI. | none |
| `extra/ungoogled-chromium/enable-menu-on-reload-button.patch` | 1 | skip | Chrome toolbar UI. | none |
| `extra/ungoogled-chromium/add-flag-for-omnibox-autocomplete-filtering.patch` | 9 | skip | Opt-in flag; our command bar chooses providers. | none |
| `extra/ungoogled-chromium/disable-dial-repeating-discovery.patch` | 2 | keep | Stops periodic SSDP (DIAL/Cast) discovery on the local network. | none |
| `extra/ungoogled-chromium/remove-uneeded-ui.patch` | 47 | skip | chrome:// WebUI strings and links; depends on which WebUI pages we show (section 8.5). | none |
| `extra/ungoogled-chromium/add-flag-to-close-window-with-last-tab.patch` | 5 | skip | Chrome tab strip behaviour; our host owns windows. | none |
| `extra/ungoogled-chromium/add-flag-to-convert-popups-to-tabs.patch` | 5 | skip | Opt-in flag; popup routing is ours (§4.6). | none |
| `extra/ungoogled-chromium/add-flag-to-disable-local-history-expiration.patch` | 4 | skip | Opt-in flag. | none |
| `extra/ungoogled-chromium/add-extra-channel-info.patch` | 1 | skip | chrome://version string. | none |
| `extra/ungoogled-chromium/prepopulated-search-engines.patch` | 1 | skip | Preference default. | none |
| `extra/ungoogled-chromium/add-flag-to-clear-data-on-exit.patch` | 7 | skip | Opt-in flag. | none |
| `extra/ungoogled-chromium/add-flag-for-qr-generator.patch` | 5 | skip | Chrome UI. | none |
| `extra/ungoogled-chromium/add-flag-for-grab-handle.patch` | 3 | skip | Chrome tab strip UI. | none |
| `extra/ungoogled-chromium/add-flag-for-close-confirmation.patch` | 12 | skip | Chrome UI; our AppController owns quit (§4.5). | none |
| `extra/ungoogled-chromium/keep-expired-flags.patch` | 3 | skip | chrome://flags only. | none |
| `extra/ungoogled-chromium/add-flag-for-custom-ntp.patch` | 4 | skip | New tab page is ours. | none |
| `extra/ungoogled-chromium/add-flag-for-tab-hover-cards.patch` | 7 | skip | Chrome tab strip UI. | none |
| `extra/ungoogled-chromium/add-flag-to-hide-tab-close-buttons.patch` | 4 | skip | Chrome tab strip UI. | none |
| `extra/ungoogled-chromium/add-flag-to-disable-tls-grease.patch` | 3 | skip | Opt-in flag. | none |
| `extra/ungoogled-chromium/add-flag-to-change-http-accept-header.patch` | 5 | skip | Opt-in flag. | none |
| `extra/ungoogled-chromium/add-flag-for-disabling-link-drag.patch` | 7 | skip | Opt-in flag. | none |
| `extra/ungoogled-chromium/add-flag-to-hide-extensions-menu.patch` | 5 | skip | Chrome toolbar UI. | none |
| `extra/ungoogled-chromium/add-flag-to-hide-fullscreen-exit-ui.patch` | 4 | skip | Chrome UI; our seam owns exit warnings (§4.6). | none |
| `extra/ungoogled-chromium/add-flag-for-incognito-themes.patch` | 4 | skip | Chrome UI. | none |
| `extra/ungoogled-chromium/add-flags-for-referrer-customization.patch` | 17 | skip | Opt-in flags. | none |
| `extra/ungoogled-chromium/default-webrtc-ip-handling-policy.patch` | 1 | skip | Preference default; it sets disable-non-proxied-UDP, while §4.8 wants `default_public_interface_only`. | Our layer must set `default_public_interface_only` (section 8.3), or local IPs follow Chromium's default. |
| `extra/ungoogled-chromium/add-flags-for-existing-switches.patch` | 3 | skip | chrome://flags entries for existing switches. | none |
| `extra/ungoogled-chromium/first-run-page.patch` | 5 | skip | Chrome first-run UI. | none |
| `extra/ungoogled-chromium/add-flag-to-reduce-system-info.patch` | 6 | skip | Opt-in flag. | none |
| `extra/ungoogled-chromium/add-flag-to-remove-client-hints.patch` | 9 | skip | Opt-in flag. | none |
| `extra/ungoogled-chromium/enable-extra-locales.patch` | 5 | skip | Chrome UI locales; our UI is Swift. | none |
| `extra/ungoogled-chromium/remove-pac-size-limit.patch` | 1 | skip | Removes a resource limit, not Google traffic. | Skipping keeps the PAC file size limit. |
| `extra/ungoogled-chromium/enable-certificate-transparency-and-add-flag.patch` | 2 | skip | A feature default plus a flag; our layer enables the feature instead. | Our layer must enable `kCertificateTransparencyAskBeforeEnabling` (section 8.3), or CT is not enforced in an unbranded build. |
| `extra/ungoogled-chromium/add-flag-to-spoof-webgl-renderer-info.patch` | 6 | skip | Opt-in flag. | none |
| `extra/ungoogled-chromium/add-flag-to-increase-incognito-storage-quota.patch` | 6 | skip | Opt-in flag. | none |
| `extra/ungoogled-chromium/add-credits.patch` | 5 | keep | Adds ungoogled-chromium's BSD notice to about:credits, which we owe for the patches we import. | none |
| `extra/ungoogled-chromium/disable-ai-search-shortcuts.patch` | 2 | keep | Hides @gemini, @aimode and @page starter-pack entries, which our command bar would otherwise show. | none |
| `extra/ungoogled-chromium/disable-fedcm-by-default.patch` | 1 | skip | Feature default; FedCM is a web standard sites use for sign-in. | none |
| `extra/ungoogled-chromium/bundle-hyphenation-patterns.patch` | 1 | skip | No effect on Apple platforms (`!is_apple`). | none |
| `extra/ungoogled-chromium/add-flag-for-disabling-jit.patch` | 5 | skip | Opt-in flag. | none |
| `extra/ungoogled-chromium/add-flag-to-hide-window-buttons.patch` | 11 | skip | Chrome frame UI. | none |

#### 8.2.2 ungoogled-chromium-macos, 27 patches

Every macOS patch marked "toolchain shim" exists because the macOS repo builds a pruned tree with its own tools: `build.sh` bootstraps GN from source, builds bindgen, installs esbuild with `npm install`, and points at `/opt/homebrew/bin/{esbuild,tsc}`. Our checkout `~/chromium-build/src` has Chromium's prebuilt `third_party/llvm-build`, `third_party/rust-toolchain`, `third_party/crubit`, `third_party/node/mac_arm64`, `third_party/devtools-frontend/src/third_party/esbuild`, `buildtools/mac/gn`, `third_party/cpython3/host/bin` and `tools/clang/dsymutil/bin` (measured, 2026-11-05), and the stock 157 build in architecture §4.7 succeeded without any of these patches. That build was not the official configuration (`symbol_level=0`, no ThinLTO, no PGO), so shims that only matter there (`disable-symbol-order-verification`, `fix-dsymutil`, `fix-complex-builtins`) are skipped on the presence of the tools they replace, not on a build.

| Patch | Hunks | Decision | Reason | Security consequence |
|---|---:|---|---|---|
| `ungoogled-chromium/macos/build-bindgen.patch` | 3 | skip | Toolchain shim for a pruned tree; our gclient checkout has Chromium's toolchain. | none |
| `ungoogled-chromium/macos/disable-clang-version-check.patch` | 2 | skip | Toolchain shim (older clang). | none |
| `ungoogled-chromium/macos/disable-crashpad-handler.patch` | 2 | keep | Keeps Crashpad's handler process from starting; the macOS repo carries it next to disable-crash-reporter. | none |
| `ungoogled-chromium/macos/disable-symbol-order-verification.patch` | 1 | skip | Toolchain shim (their libc++ build). | none |
| `ungoogled-chromium/macos/fix-build-with-rust.patch` | 3 | skip | Toolchain shim (own Rust toolchain). | none |
| `ungoogled-chromium/macos/fix-clang-format-path.patch` | 1 | skip | Toolchain shim (system clang-format). | none |
| `ungoogled-chromium/macos/fix-disabling-safebrowsing.patch` | 8 | keep (provisional: Safe Browsing) | macOS build fix for `safe_browsing_mode=0`; its `chrome_content_browser_client.cc` hunk follows from disable-ai (ScreenAI and TranslateKit sandbox paths). | none by itself; the protection change is in fix-building-without-safebrowsing. |
| `ungoogled-chromium/macos/fix-dsymutil.patch` | 2 | skip | Toolchain shim (system dsymutil). | none |
| `ungoogled-chromium/macos/no-unknown-warnings.patch` | 1 | skip | Toolchain shim (older clang). | none |
| `ungoogled-chromium/macos/build-bindgen-target-override.patch` | 5 | skip | Toolchain shim (local bindgen build). | none |
| `ungoogled-chromium/macos/bindgen-disable-static.patch` | 1 | skip | Toolchain shim (local bindgen build). | none |
| `ungoogled-chromium/macos/set-rustc-nightly-capability.patch` | 1 | skip | Toolchain shim (own Rust toolchain). | none |
| `ungoogled-chromium/macos/revert-v8-sanitizer-changes.patch` | 3 | skip | Toolchain shim (older clang). | none |
| `ungoogled-chromium/macos/fix-nasm-build-config.patch` | 1 | skip | Toolchain/SDK shim; our stock build compiles nasm without it. | none |
| `ungoogled-chromium/macos/fix-anyappleos-availability.patch` | 2 | skip | Toolchain shim (clang without `anyAppleOS`). | none |
| `ungoogled-chromium/macos/fix-build-without-crubit.patch` | 64 | skip | Removes Crubit uses because their toolchain lacks it; it also drops the DevTools Storage domain. | Skipping keeps DevTools' Storage domain. |
| `ungoogled-chromium/macos/use-system-python.patch` | 1 | skip | Toolchain shim (system python). | none |
| `ungoogled-chromium/macos/fix-disable-verification-token.patch` | 31 | skip | Removes Private Verification Tokens for the no-Crubit build. | none |
| `ungoogled-chromium/macos/fix-esbuild.patch` | 4 | skip | Toolchain shim (Homebrew esbuild). | none |
| `ungoogled-chromium/macos/fix-typescript.patch` | 3 | skip | Toolchain shim (Homebrew tsc). | none |
| `ungoogled-chromium/macos/restore-typescript-js-compiler.patch` | 13 | skip | Toolchain shim (node tsc instead of tsgo). | none |
| `ungoogled-chromium/macos/fix-gn-compatibility.patch` | 11 | skip | Shim for a GN built from source; our checkout has Chromium's GN. | none |
| `ungoogled-chromium/macos/fix-gn-compatibility-chromium-156.patch` | 64 | skip | Shim for a GN built from source; version-named for 156. | none |
| `ungoogled-chromium/macos/fix-typescript-isolated-declarations.patch` | 2 | skip | Toolchain shim (older tsc). | none |
| `ungoogled-chromium/macos/fix-complex-builtins.patch` | 2 | skip | Toolchain shim (own Rust compiler_builtins). | none |
| `ungoogled-chromium/macos/set-bundle-identifier.patch` | 2 | skip | Our bundle identifier comes from our branding. | none |
| `ungoogled-chromium/macos/add-local-network-usage-description.patch` | 2 | keep | Adds `NSLocalNetworkUsageDescription` to the app and helper plists, which macOS requires for local network access. | none |

#### 8.2.3 Interactions with the lists and flags

- `domain_substitution.list` rewrites Google hosts in files Ararat needs unchanged: `extensions/common/extension_urls.cc`/`.h` (Web Store), `chrome/browser/extensions/updater/chrome_update_client_config.cc` (extension updates), `components/component_updater/component_updater_url_constants.cc` (component updater) and `components/safe_browsing/core/common/features.cc`/`.h` (Safe Browsing). Substituted hosts end in `qjz9zk`, which `block-trk-and-subdomains` blocks. Skipping `disable-webstore-urls` is therefore not enough. These six files are the minimum exclusions; the audit scope is larger (substitution touches 42 files under `components/safe_browsing/`, 132 under `chrome/browser/extensions/` and 95 under `extensions/`, section 3). Substitution is also the only thing that stops Google hosts no patch touches (for example optimization guide and suggest), so dropping it re-enables that traffic. The choice is substitution with exclusions, or no substitution plus a per-endpoint audit.
- `pruning.list` deletes files our checkout has and needs: `chrome/browser/resources/media/mei_preload/preloaded_data.pb`, `components/privacy_sandbox/privacy_sandbox_attestations/preload/privacy-sandbox-attestations.dat` and the prebuilt toolchains. Without pruning, `fix-building-with-prunned-binaries`, `disable-mei-preload`, `disable-privacy-sandbox` and all macOS toolchain shims are unnecessary.
- `flags.gn`:
  - `safe_browsing_mode=0` and `google_api_key=""` follow the Safe Browsing item. Google Safe Browsing needs `safe_browsing_mode=1` and an API key.
  - `enable_widevine=true` is set, but the Widevine CDM arrives through the component updater, which `block-requests` disables (section 8.3).
  - `enable_mdns=false` and `enable_service_discovery=false` match §4.8 and need `fix-building-without-mdns-and-service-discovery`.
  - `enable_reporting=false` removes the Reporting API and Network Error Logging, so sites lose those reports. This is a flag, not a patch, and needs its own decision with the GN args file (§4.7).
- `flags.macos.gn`: `enable_updater=false` makes `0015-disable-update-pings` dead code.

### 8.3 Counter-patches and defaults our layer sets

Counter-patches (our change on top of a kept patch):

1. `block-requests` (12 hunks): carry it without the `components/update_client/update_checker.cc` hunk (11 of 12 hunks), and exclude `component_updater_url_constants.cc` from domain substitution if substitution is applied. This restores component updates: CRLSet, PKI metadata (Chrome Root Store and the CT log list), file-type policies, and the Widevine CDM if DRM is chosen. It also restores the `update_client` path that extension updates use.
2. `fix-building-without-safebrowsing` (216 hunks, provisional on Safe Browsing = another source): restore
   - the Omaha attributes path that carries Google's extension kill switch in update responses (§9): the `OmahaAttributesHandler` member and `PerformActionBasedOnOmahaAttributes` in `chrome/browser/extensions/extension_service.cc`/`.h`, its call in `chrome_extension_system.cc`, and the blocklist and greylist state handling it relies on in `extensions/browser/extension_registrar.cc`;
   - download file-type danger levels: `SetDangerLevel` and the `DownloadRestrictions` cases in `chrome/browser/download/chrome_download_manager_delegate.cc`;
   - a hook where the removed Safe Browsing URL and download checks were, for our reputation check (§14).
3. inox `0001-fix-building-without-safebrowsing` (15 hunks, same provisional): restore the dynamic-update read in `chrome/browser/component_updater/file_type_policies_component_installer.cc`, so file-type policies update through the component updater (needs counter-patch 1).

Defaults our layer sets in place of a skipped patch (feature overrides or registered pref defaults from `//chrome/browser/ararat`, no Chrome file edits):

- Security-relevant:
  - Enable `kCertificateTransparencyAskBeforeEnabling` (replaces `enable-certificate-transparency-and-add-flag`). Without it an unbranded build does not enforce CT. Enforcement also stops when the built-in log list goes stale, which counter-patch 1 prevents.
  - Set the WebRTC IP handling policy to `default_public_interface_only` (§4.8; replaces `default-webrtc-ip-handling-policy`, which sets a stricter policy that breaks direct UDP).
- Preference choices, for the owner:
  - from `0006-modify-default-prefs`: hyperlink auditing off, third-party cookies blocked, network prediction off, background mode off;
  - default search engine (`replace-google-search-engine-with-nosearch`, `prepopulated-search-engines`);
  - no first-run auto-import (`browser-disable-profile-auto-import-on-first-run`).

### 8.4 Decisions that depend on open items

Items already in architecture §14:

- **Safe Browsing source.** `fix-building-without-safebrowsing` (216), inox `0001` (15), macOS `fix-disabling-safebrowsing` (8), `safe_browsing-disable-reporting-of-safebrowsing-over` (1), and the `safe_browsing_mode` and `google_api_key` GN args.
  - Google Safe Browsing with an API key: skip all four, set `safe_browsing_mode=1` and a key, exclude `components/safe_browsing/core/common/features.*` from domain substitution. Whether the disable-ai hunk in macOS `fix-disabling-safebrowsing` are still needed is unknown (section 8.5).
  - Another source: keep them as counter-patches 2 and 3. That adds 240 hunks plus ours.
- **DRM.** Widevine needs counter-patch 1 (component updater) regardless of `enable_widevine=true`.
- **Content blocker.** `extensions-manifestv2` (4) is needed only for uBlock Origin (MV2). With the current lean (uBO Lite) it is skipped.

Items not in §14 (new):

- **Apply `pruning.list` or not.** This decides `fix-building-with-prunned-binaries` (19), `disable-mei-preload` (3), `disable-privacy-sandbox` (1), and whether the 24 macOS toolchain shims (223) come back. The recommendation here assumes no pruning, as in the measured stock build.
- **Domain substitution with exclusions, or no substitution plus a per-endpoint audit.** This decides `block-trk-and-subdomains` (17) and `fix-learn-doubleclick-hsts` (1). With substitution, the Web Store, component updater and Safe Browsing files need exclusions (section 8.2.3). Without it, Google hosts no patch touches become reachable again.
- **Functional losses from kept patches**, which no owner decision has ruled on:
  - Web Push stops (`disable-gcm`).
  - Translation is off (`toggle-translation-via-switch`).
  - No local crash dumps exist for our own diagnostics (`disable-crash-reporter`, `disable-crashpad-handler`).
  - PDF OCR and ScreenAI accessibility annotations are gone (`disable-ai`).
  - `chrome.identity.getAuthToken` cannot work without Google sign-in, with or without the prefs patch.

### 8.5 Not determined

- No patch was applied and nothing was built. The series target 156.0.8078.79; our base is 157.0.8103.39. Section 4 lists 19 patches whose content changed in 156 → 157 (among them `remove-unused-preferences-fields`, `disable-ai`, `fix-building-without-safebrowsing`, `remove-uneeded-ui`, `add-flag-for-search-engine-collection`, `add-suggestions-url-field`, `disable-gcm`). The decisions on those need a recheck against the 157 series once it is pinned. Hunk counts are those of the 156 files.
- Whether `fix-building-without-safebrowsing` builds without `remove-unused-preferences-fields`. The latter deletes the mode-independent `safe_browsing_prefs` library (`components/safe_browsing/core/common/BUILD.gn` builds it whatever `safe_browsing_mode` is), so it reads as a cleanup, not a build requirement. Only a build with `safe_browsing_mode=0` confirms this. If it is required, it moves to "counter-patch (provisional: Safe Browsing)" with 459 hunks, and `move-js-optimizer-unfamiliar-sites` (6) comes with it.
- Whether `disable-untraceable-urls` is dead code once `disable-rlz` sets `enable_rlz_support=false`, and whether `disable-crashpad-handler` is redundant after `disable-crash-reporter` returns early from `InitializeCrashpadImpl` on macOS. Both need a build.
- Whether GN args such as the Glic and ScreenAI build flags can replace part of `disable-ai` (116 hunks). Not checked.
- Which chrome:// WebUI pages Ararat shows (settings, extensions, history, flags). This decides `remove-uneeded-ui` (47), `add-suggestions-url-field` (38), `keep-expired-flags` and `first-run-page`. They are skipped on the assumption that our UI replaces those pages.
- Whether our host calls Chrome's startup infobars (`AddInfoBarsIfNecessary`). If it does, the missing-API-key infobar appears and `0013-disable-missing-key-warning` and `google-api-warning` become worth keeping.
- The disable-ai hunk in macOS `fix-disabling-safebrowsing` (ScreenAI and TranslateKit sandbox parameters in `chrome_content_browser_client.cc`) may be needed even with Google Safe Browsing.
- How stale the built-in CT log list may get before Chromium stops enforcing CT was not measured.
- Counter-patch 3 assumes `safe_browsing::FileTypePolicies` still builds with `safe_browsing_mode=0`. Not verified.
- The official build configuration (`is_official_build`, ThinLTO, PGO, `symbol_level=1`) was not exercised, so the macOS toolchain-shim skips are confirmed only for the non-official stock build.

### 8.6 The set phase 2 builds (decided 2026-11-05, provisional)

Phase 2 builds the lowest case of section 8.1: the 25 patches marked keep or counter-patch without a condition (23 generic, 2 macOS; 243 hunks), applied to a git + gclient checkout of 156.0.8078.79.

- Safe Browsing: Google Safe Browsing stays in the build (`safe_browsing_mode=1`, the default); the four Safe Browsing patches are not applied. No API key is set yet, so lookups do not run; the source is still the owner's §14 item, required before daily use (§4.9). This keeps the extension kill switch of §9 and the download file-type danger levels without counter-patches 2 and 3.
- No domain substitution and no pruning (gclient's prebuilt toolchains are kept), so `block-trk-and-subdomains`, `fix-learn-doubleclick-hsts`, the pruning build fixes and the 24 macOS toolchain shims are not applied. Google hosts that no patch touches stay reachable until an endpoint audit is done.
- `block-requests` is carried unchanged and followed by our counter-patch that restores the `update_checker.cc` hunk, so the component updater (CRLSet, PKI metadata, file-type policies) keeps working.
- GN args: ungoogled's `flags.gn` and `flags.macos.gn` without `safe_browsing_mode=0`. `enable_reporting=false` is kept for now.
- The defaults of section 8.3 (CT enforcement, WebRTC IP policy, preference choices) belong to our layer and come with phase 3.

The macOS repository's lag (section 4) matters less than section 6 assumed: two of its 27 patches are applied.
