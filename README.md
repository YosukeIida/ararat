# Ararat

A macOS browser that brings Arc's workflow and Yab's vertical tabs to Chromium. In design.

Licensed under GPL-3.0 (`LICENSE`).

## Development

The design is in `docs/architecture.md`. The dev shell (`nix/flake.nix`, loaded by direnv) provides the Rust toolchain, and Node.js, Ghidra and a JDK for REA (`~/workspace/github.com/morluto/rea`, after `npm ci && npm run build` there). It also points `DEVELOPER_DIR` at nix's apple-sdk, which hides Xcode's `swift` and `swiftc`, so Swift and REA run through the `xc` function below.

```sh
(cd core && cargo test)                 # core tests
xc() { env -u SDKROOT DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer "$@"; }
macos/scripts/build-core.sh             # build the core and regenerate the Swift bindings
(cd macos && xc swift run AraratHarness) # sidebar harness on a synthetic Arc sidebar
(cd macos && xc swift run AraratHarness --check path/to/StorableSidebar.json)
(cd macos && xc swift run AraratHarness --db "$TMPDIR/ararat.sqlite")
printf 'space 1\nselect tab-a\nstate\n' | (cd macos && xc swift run AraratHarness)   # drive the harness without the pointer
xc node ~/workspace/github.com/morluto/rea/scripts/rea.mjs doctor   # REA with the devshell's Ghidra
```

The harness reads `space <index>`, `select <row id>`, `state`, `width` and `reset-width` on stdin and answers each on stdout. `width` reports the current sidebar width in points as `ok <width>`; `reset-width` restores 240 pt and replies `ok 240`. Drag the sidebar's right edge to resize it between 164 and 500 pt, or use View → Reset Sidebar Width to restore 240 pt. Width is kept per window in memory only. Main-thread stalls over 100 ms are written to stderr as `hitch <ms> ms`.

`--db <path>` loads a SQLite workspace. If it has no spaces, the harness imports the bundled synthetic fixture, or a sidebar file supplied as an additional argument, and flushes it to disk. Later runs load the stored workspace without importing again. The harness flushes on quit and reports errors to stderr. Without `--db`, it reads JSON without creating a database. UI edits are not saved yet.
