# Judgement on the 2026-10-31 Codex reviews

Japanese translation: `2026-10-31-phase1-judgement.ja.md`. Reviews: `2026-10-31-architecture-draft2-codex.md`, `2026-10-31-phase1-core-codex.md`, `2026-10-31-phase1-macos-codex.md`, `2026-10-31-observations-codex.md` (Codex `gpt-6.1-sol`, effort medium, labteam).

Every finding is accepted; each points at a real gap with evidence in the files. "Done" means fixed in this change; the rest go back to step 1.

## Architecture draft 2

| # | Finding | Decision | Why |
|---|---|---|---|
| A1 | Epoch change does not revoke a removed device | Fix | Keys derived from the same group secret stay derivable by the removed device. Needs fresh epoch secret material sent only to remaining devices (§8.2) |
| A2 | Tree repair can depend on merge order | Fix | The counterexample holds for the current code, which writes repairs back into the registers. Repair becomes a derived view over unmodified registers (§6.1, `tree.rs`), with a delivery-order test |
| A3 | Startup reconciliation can resurrect closed tabs | Fix | Needs durable lifecycle state and a precedence rule between SQLite and engine sessions (§5.2) |
| A4 | Extension focus ignores native-window focus | Fix | Focused = displayed profile's `Browser` of the key window while the app is active (§4.6) |
| A5 | Outside-window reveal has no detection while hidden | Done | §7 now follows the pointer with mouse-moved monitors while the app is active and the sidebar is hidden |
| A6 | Duplicate selection within one window | Fix | The newly focused pane takes the page; the other gets the placeholder (§4.6) |

## Core

| # | Finding | Decision | Why |
|---|---|---|---|
| C1 | Queued writes starve the 1 s deadline | Fix | A steady stream never reaches the timeout branch; check the deadline before each receive |
| C2 | Imported cycle makes the snapshot loop | Fix | Run `repair_tree` (or reject) on import before any traversal; test through the FFI function |
| C3 | Missing or mistyped collections import as empty | Fix | Silent data loss; reject them |
| C4 | ATC strips text before an embedded `://` | Fix | Wrong matches; strip only a leading scheme |
| C5 | Storage tests skip scheduled retry and interrupted commits | Fix | The claims rest on those paths |

## macOS

| # | Finding | Decision | Why |
|---|---|---|---|
| M1 | Rows are not keyboard operable | Fix | Accessibility is not cut, even in the harness |
| M2 | Harness links the dylib by absolute path | Fix | Contradicts the static-library layout; link `libararat_ffi.a` |
| M3 | Layer colours ignore appearance changes | Fix | Refresh in `viewDidChangeEffectiveAppearance` |
| M4 | No command channel in the harness | Fix | Architecture requires pointer-free UI checks |
| M5 | No hitch monitor | Fix | Architecture requires it from the first build |

## Observations

| # | Finding | Decision | Why |
|---|---|---|---|
| O1 | Same as A5 | Done | |
| O2 | Capture latency was inferred circularly | Done | The documents now give times from event post to frame callback and say capture delay was not measured |
| O3 | The edge detector stops after a page-coloured gap | Done | README section 4 now states the rule and its limits; the Arc spring was re-estimated from whole curves rather than the 2 px overshoot (`arc-ardia-observed.md` section 4) |

## Outcome of the fixes

All findings above are fixed in the working tree, with these limits:

- C1: the deadline is now checked before each receive. `steady_writes_still_commit_within_the_batch_window` checks the property under steady writes but also passes without the fix: reproducing a queue that is never empty at the deadline needs test-only code in the writer or hundreds of MB of queued ops, and neither was taken. The fix rests on reading the loop.
- C2, C4: their new tests fail without the fix. C5's interrupted-commit test kills a child at six points during large commits rather than at a hook (reason in the test).
- A2: the architecture now makes repair a view over unmodified registers; `repair_tree` still writes its result and is only called by the importer, where that is correct. The view form and delivery-order tests come with the sync merge (phase 8).
- M1–M5: built and run: the harness binary no longer links a dylib, `--check` works, and the stdin commands answer as documented in the README. Keyboard focus, appearance changes and the hitch monitor were not exercised by hand.

## Round 2 (`2026-10-31-fixes-codex.md`)

All five findings are accepted; the "all fixed" line above was too broad. Round 3 (`2026-10-31-fixes2-codex.md`) found 1, 3 and 4 resolved and two gaps left, handled as below: recovery after removal (2) is now specified, and the crash test (5) is renamed to what it is, stress coverage.

| # | Finding | Fix |
|---|---|---|
| 1 | Repair can leave a cycle when a space's container is missing; the FFI test changed the wrong parent | The importer rejects spaces whose pinned or Today id is not a container, and rejects a tree that still fails `check_tree` after repair. The FFI test now makes `pin-work` a child of `tab-spec`; without the repair it runs forever (checked). |
| 2 | Key schedule still derives from the group secret; recovery after removal undefined | §8.2: keys come from the current epoch secret; removal also replaces the group secret and shows a new phrase, so the old phrase no longer joins. After round 3: each epoch secret is also kept on the relay sealed under a recovery key from the current group secret, so the current phrase alone recovers it. |
| 3 | `selectRow` traps on an empty workspace | Guarded. |
| 4 | Commands split across reads | Commands are read line by line on a background thread; a command sent in two pieces was checked. |
| 5 | Kills may miss every transaction | The child now reports after its first commit and the parent kills 3–71 ms later, while large commits follow one another, and checks the database is not empty. A guaranteed mid-transaction kill would still need a hook in the writer, which is not taken. |
