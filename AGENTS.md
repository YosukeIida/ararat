# Ararat

A macOS browser with Arc's workflow and Yab's vertical tabs, built on Chromium. The UI is Swift (AppKit). The engine is a Chromium fork with our own layer built inside the tree, the way Dia does it with ArcCore and Ardia with ArdiaCore. The cross-platform core is Rust. Windows, Linux and iPhone come later, but the structure assumes them from the start. The design is in `docs/architecture.md`.

## Language

Write repository files (README, AGENTS.md, everything under `docs/`, code comments, commit messages) in English unless a file says otherwise. The English file is the source of truth. Markdown documents also get a Japanese translation next to them as `<name>.ja.md` (`README.ja.md`, `docs/architecture.ja.md`), updated in the same change as the English file. Working notes overwritten every session (`docs/HANDOVER.md`, `docs/reviews/PENDING.md`) and raw reviewer output (`docs/reviews/*-codex.md`) get no translation.

## How work is done (the sandwich)

Every unit of work is split between Claude and Codex. Codex holds closed logical consistency well; Claude picks signal out of many loosely constrained variables. So Claude sets the scope and reviews, and Codex implements:

1. Scope and design: Claude Opus 5.5 (`claude-opus-5-5`). It writes what to build, the files it touches, the invariants and the edge cases.
2. Implementation: Codex `gpt-6.1-sol`, effort medium (raise it when it stalls), on the labteam account (`CODEX_HOME=$HOME/.codex-labteam`). Sol, not Terra: OpenAI's Codex model guide recommends Sol for code and positions Terra for writing, visual understanding and computer use.
3. Review: Claude Opus 5.5. For each finding, decide fix or no fix and why, and send the fixes back to step 2.

For a hard edge-case bug the order is reversed: Codex investigates, Claude gives a second opinion, Codex implements, Claude reviews.

Measurement and design-stage work (research notes, `docs/architecture.md`) needs no review unless the owner asks for one.

The seats run on orca-agent-team (one Orca tab per role) from a Claude session inside Orca, or on herdr-agent-team from one inside herdr. Agents run `cargo` through the devshell (`direnv exec . cargo ...`): their shells do not load direnv, and a `cargo` found elsewhere on `PATH` builds with another toolchain into the same `target/`.

## Prior art

- Ardia (`mantrakp04/ardia`, GPL-3.0): a Chromium fork with its own layer. This repo is also GPL-3.0, so its code may be reused; keep the source noted in any file that reuses it.
- Cra (`VictorKildahl/cra`, MIT): Swift + CEF. Reference for the UI code.
- Arc, Dia, Yab: closed source. Use only published analyses and static analysis within what their terms allow. Never copy their code or assets.
- Research notes live in `docs/research/`.
- Analyse with REA (`morluto/rea`) from a clone of its repository, not the npm package (`npx rea-agents`). Keep node inside the devshell. Yab's terms (2026-09-30) allow any lawful use and contain no clause against analysis.
