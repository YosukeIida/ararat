# Reviews waiting for Codex

The labteam Codex workspace ran out of credits on 2026-10-30. The owner chose to wait for a refill rather than switch accounts. These units need the review and judgement steps once it is back:

1. Architecture draft 2 (`docs/architecture.md`): round 2, checking the round-1 findings and the new sections (sync protocol requirements, tree repair, crash consistency, extension window semantics, pointer sampling, roadmap).
2. Phase-1 core code (`core/`): model with membership registers, fractional order keys (`order.rs`), Air Traffic Control matching, Arc sidebar import, UniFFI surface, SQLite storage (`storage.rs`: records + journal in one transaction, 1 s batch writer, retry on failure; `tests/storage.rs` including a process-abort test), tree repair (`tree.rs`, HLC and previous parent on `Membership`; `tests/tree.rs` with a randomised damage test).
3. Phase-1 macOS code (`macos/`): package layout, `SidebarView`, `SidebarRowView`, `FavoriteTile`, the harness.
