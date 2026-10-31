What this change does: Phase 1 implements the workspace model, fractional order keys, ATC matching, Arc sidebar import, SQLite persistence and an import-to-snapshot UniFFI function. Records and journal entries share one SQLite transaction, and failed batches remain pending.

1. **Major — Queued writes can starve the commit deadline.**
   - **Location:** [storage.rs:141](/Users/yosuke/workspace/github.com/YosukeIida/ararat/core/ararat-core/src/storage.rs:141), writer loop.
   - **Problem:** Once the deadline expires, an already queued message can still be received. Every `Write` branch continues without checking whether a commit is overdue. A sustained backlog therefore permits changes older than one second to remain uncommitted, increasing crash loss.
   - **Evidence:** Lines 144–150 use `recv_timeout(due.saturating_duration_since(...))` and unconditionally `continue` after receiving writes. This contradicts the steady-editing claim at lines 135–136 and [architecture.md:200](/Users/yosuke/workspace/github.com/YosukeIida/ararat/docs/architecture.md:200). The deadline test submits one write and then sleeps ([tests/storage.rs:91](/Users/yosuke/workspace/github.com/YosukeIida/ararat/core/ararat-core/tests/storage.rs:91)).
   - **Suggested fix:** Check the deadline before receiving another message and commit when it has expired. Test with messages still queued at the deadline.

2. **Major — Imported cycles can make the UniFFI call loop indefinitely.**
   - **Location:** [model.rs:166](/Users/yosuke/workspace/github.com/YosukeIida/ararat/core/ararat-core/src/model.rs:166), `outline`; [ararat-ffi/src/lib.rs:56](/Users/yosuke/workspace/github.com/YosukeIida/ararat/core/ararat-ffi/src/lib.rs:56), import and snapshot.
   - **Problem:** The importer accepts parent relationships without validation, and snapshot traversal has no cycle guard. In the synthetic fixture, changing `pin-work.parentID` to `tab-spec` creates the reachable cycle `pin-work → folder-docs → tab-spec → pin-work`. Snapshot generation repeatedly traverses it and grows its output until resource exhaustion.
   - **Evidence:** Import copies `parentID` directly ([import.rs:97](/Users/yosuke/workspace/github.com/YosukeIida/ararat/core/ararat-core/src/import.rs:97)). The exported function immediately calls `snapshot`; `outline` repeatedly pushes children without tracking visited items. Filtering container rows occurs afterward.
   - **Suggested fix:** Validate or repair imported trees before snapshot generation and return an import error if invariants remain broken. Add a regression test through the exported function. The handover’s deferred repair hook after storage loading does not cover this path.

3. **Major — Missing or mistyped import collections are silently accepted as empty.**
   - **Location:** [import.rs:150](/Users/yosuke/workspace/github.com/YosukeIida/ararat/core/ararat-core/src/import.rs:150), `flat_pairs`.
   - **Problem:** Required collections do not receive structural validation. For example, `{"sidebar":{"containers":[{"spaces":null}]}}` succeeds with an empty workspace. Removing `items` from an otherwise valid fixture succeeds with spaces whose sidebar contents have disappeared.
   - **Evidence:** `flat_pairs` returns `Ok(Vec::new())` for every non-array value. Both `spaces` and `items` pass through it at lines 25 and 36. Existing rejection tests cover `{}` and an odd-length array, but neither case above ([tests/arc_import.rs:38](/Users/yosuke/workspace/github.com/YosukeIida/ararat/core/ararat-core/tests/arc_import.rs:38)).
   - **Suggested fix:** Reject missing or wrongly typed required collections. Keep optional-field handling explicit and add tests for absent `items` and non-array `spaces`.

4. **Minor — ATC normalization removes text before an embedded `://`.**
   - **Location:** [routing.rs:61](/Users/yosuke/workspace/github.com/YosukeIida/ararat/core/ararat-core/src/routing.rs:61), `normalize`.
   - **Problem:** Scheme removal is not restricted to a leading scheme. A Contains condition `redirect=https://example.com` becomes `example.com`, so it incorrectly matches `https://example.com/plain`, which contains no redirect parameter.
   - **Evidence:** Line 63 discards everything before the first `://` in both URLs and condition text. Architecture §6.1 requires Contains to inspect query and fragment text ([architecture.md:214](/Users/yosuke/workspace/github.com/YosukeIida/ararat/docs/architecture.md:214)); the current tests contain no embedded scheme in condition text.
   - **Suggested fix:** Remove only a syntactically valid leading scheme. Add the example above as a negative match test.

5. **Minor — Storage tests leave automatic retry and interrupted transactions unverified.**
   - **Location:** [tests/storage.rs:101](/Users/yosuke/workspace/github.com/YosukeIida/ararat/core/ararat-core/tests/storage.rs:101) and [tests/storage.rs:142](/Users/yosuke/workspace/github.com/YosukeIida/ararat/core/ararat-core/tests/storage.rs:142).
   - **Problem:** The retry test forces recovery with another `flush()`, bypassing scheduled retry. The crash child aborts after a completed flush and immediately after enqueueing a deletion; it does not deterministically interrupt an active transaction.
   - **Evidence:** Lines 111–112 release the lock and call `flush()` again. Lines 145–148 flush the initial workspace, enqueue one deletion and abort without synchronization with the writer.
   - **Suggested fix:** Test recovery after releasing the lock without another flush. Add a controlled interruption after record writes but before transaction commit, then verify rollback and journal consistency.

The remaining checks have these limits:

- Fractional-key tests cover generated, distinct bounds and repeated insertion. They do not cover equal sibling keys after concurrent insertion. The model deliberately orders ties by ID ([model.rs:160](/Users/yosuke/workspace/github.com/YosukeIida/ararat/core/ararat-core/src/model.rs:160)), while `key_between` rejects equal bounds. No current production move caller exercises that gap.
- Tree tests verify repair validity, idempotence and replay of returned operations. Their randomized damage preserves the root containers; it does not prove recovery when Today containers are missing or cross-device merge convergence.
- The handover correctly acknowledges missing Store bindings, private-write rejection, backup support, HLC advancement, tombstones and repair integration. These remain differences from the architecture’s intended system. Separately, the “not checked against a real file yet” comments in `import.rs:1` and `tests/arc_import.rs:1` are stale relative to `HANDOVER.md:21`. The real-file Today count remains unresolved.

**Verdict: Fix findings 1–3 before accepting this unit.**

Not checked: Fresh Cargo tests were blocked by the read-only build lock; cached binaries passed 16 tests, with zero FFI tests. Storage tests and private Arc data were not executed or accessed.  
No files were changed; crash and power-loss guarantees remain partly unverified.