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
- Per-patch keep/skip/counter-patch decisions and their security consequences (§4.2's Phase 2 inventory) are not made here.
