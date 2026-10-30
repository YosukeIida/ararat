# Judgement on the Codex review of architecture draft 1

Review: `2026-10-30-architecture-draft1-codex.md` (Codex `gpt-6.1-sol`, effort medium, labteam account, read-only).
Judge: Claude Opus 5.5, effort medium. Result: draft 2 of `docs/architecture.md`.

| # | Finding | Decision | What changed in draft 2 |
|---|---|---|---|
| 1 | No security-maintenance model | Fix | New 4.9: daily upstream detection, patch-lag limits, emergency builds, update path and reputation check required before daily use. The pre-authorisation of security bumps is an owner decision (14) |
| 2 | Sync protocol unspecified | Fix | 8.2 now requires XChaCha20-Poly1305 with random 192-bit nonces, per-device signing keys, PAKE-authenticated pairing, relay credentials separate from the content key, replay checkpoints, epoch rekey on device removal. A versioned protocol spec is a gate before sync code |
| 3 | Tombstone expiry resurrects deletes | Fix | Tombstones kept indefinitely until device retirement, epochs and mandatory snapshot rejoin exist; incarnation and sequence protection from the first sync release |
| 4 | Record LWW can break the tree | Fix | One membership register per item (parent id + fractional order key); child lists are derived; deterministic repair for cycles, missing parents and delete-vs-edit; tree-invariant tests. The phase-1 model code moves to this representation; the Arc importer converts into it |
| 5 | No crash consistency between Chrome and the core | Fix | 5.2: engine epoch in every revision, stable tab ids, startup snapshot and reconciliation, a stated crash-loss window, workspace changes and outgoing sync records in one SQLite transaction, disk-full handling, backup through the SQLite backup API |
| 6 | Session payload ownership missing | Fix | 4.6/5: the engine keeps Chromium's session serialisation (navigation stacks, session storage) keyed by core item ids; retention per tab state defined. Only automatic Chrome window restore is disabled |
| 7 | Incognito persistence boundary | Fix | Off-the-record identity is part of the engine contract; the core rejects durable and sync operations for it centrally; tests listed |
| 8 | Several `Browser`s in one window vs extension window semantics | Fix | 4.6 defines the mapping (visible profile's `Browser` is current/focused; others report unfocused); spike tests added |
| 9 | Cross-window tabs and split panes lifecycle | Fix | 4.6 adds page ownership and transfer, placeholders, split focus, close semantics; both in the spike |
| 10 | Removed Chrome UI carries security duties | Fix | 4.6 adds a responsibility matrix to be completed in the spike; acceptance adds permission rejection, fullscreen exit, external protocols, IME, paste after ⌘L, accessibility |
| 11 | No portable browser contract | Fix, adjusted | The live-tab coordinator moves into the Rust core (Swift becomes a thin adapter), so Windows/Linux reuse it. Passwords pass engine → core as zeroised byte buffers inside the browser process and are sealed by the core. DRM decision moves before the phase-4 API freeze. A general page-engine abstraction is not added until a second engine is chosen |
| 12 | Engine artifact identity incomplete | Fix | 4.7: a committed build-input manifest (Chromium commit, Helium tag, DEPS hash, GN args, Xcode/SDK, arch) is the artifact key; digests and provenance published; Corresponding Source rebuilds the tree |
| 13 | Extension import provenance | Fix | Store extensions are reinstalled from the Web Store; unpacked imports need explicit approval; native host manifests and executables are validated |
| 14 | Compositor ownership absent | Fix | Spike decision with measurements (first frame, background activity, occlusion, resize, split, display change) |
| 15 | Tracking areas cannot follow the pointer outside the window | Fix | 7: tracking areas inside; while the sidebar is shown, pointer sampling outside the window, stopped on deactivation |
| 16 | Roadmap validates risk too late | Fix | Roadmap reordered: a minimal engine/core/UI vertical slice with signing identity and visible checks comes before the UI build-out; crash/relaunch and offline sync tests; separate Windows and Linux gates |
| 17 | Helium benefit unproven | Fix | Helium is provisional; phase 2 decides with a pinned patch inventory, security consequences (Helium's flags disable Safe Browsing) and one measured rebase, against Chromium + ungoogled-chromium |
| 18 | Popup wording overstated | Fix | Reworded; creation paths enumerated and tested separately |
| 19 | ObjC precedent misattributed | Fix | Dia's API is generated from mojom; ours is handwritten; threading, invalidation, cancellation and ownership rules added |
| 20 | Perf gate wording | Fix | One controller alternates isolated control and candidate processes |

No finding was rejected. Codex's summary of the main choices (direct embedding, typed ObjC API, engine not linking Rust on macOS, SQLite, blind relay, AppKit/SwiftUI split, WKWebView on iPhone) agrees with draft 1; Helium became conditional.

Next: a second Codex round on draft 2, because several sections (sync, state, roadmap) changed substantially.
