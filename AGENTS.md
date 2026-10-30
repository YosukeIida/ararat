# Ararat

A macOS browser with Arc's workflow and Yab's vertical tabs, built on Chromium. The UI is Swift (AppKit). The engine is a Chromium fork with our own layer built inside the tree, the way Dia does it with ArcCore and Ardia with ArdiaCore. The cross-platform core is Rust. Windows, Linux and iPhone come later, but the structure assumes them from the start. The design is in `docs/architecture.md`.

## Language

Write repository files (README, AGENTS.md, everything under `docs/`, code comments, commit messages) in English unless a file says otherwise. The English file is the source of truth. Markdown documents also get a Japanese translation next to them as `<name>.ja.md` (`README.ja.md`, `docs/architecture.ja.md`), updated in the same change as the English file. Working notes overwritten every session (`docs/HANDOVER.md`, `docs/reviews/PENDING.md`) and raw reviewer output (`docs/reviews/*-codex.md`) get no translation.

## How work is done (the sandwich)

Every unit of design or implementation goes through three steps:

1. Design and implementation: Claude Opus 5.5 (`claude-opus-5-5`), effort medium.
2. Detailed review: Codex `gpt-6.1-sol`, effort medium, on the labteam account (switch with `cx labteam` before starting it). Ask it to review only; it edits nothing.
3. Overall judgement: Claude Opus 5.5, effort medium. For each review finding, decide fix or no fix and why, and send the fixes back to step 1.

Once work is split into tasks, it may run on orca-agent-team seats (design / orchestrator / implementation / review).

## Prior art

- Ardia (`mantrakp04/ardia`, GPL-3.0): a Chromium fork with its own layer. This repo is also GPL-3.0, so its code may be reused; keep the source noted in any file that reuses it.
- Cra (`VictorKildahl/cra`, MIT): Swift + CEF. Reference for the UI code.
- Arc, Dia, Yab: closed source. Use only published analyses and static analysis within what their terms allow. Never copy their code or assets.
- Research notes live in `docs/research/`.
- Analyse with REA (`morluto/rea`) from a clone of its repository, not the npm package (`npx rea-agents`). Keep node inside the devshell. Yab's terms (2026-09-30) allow any lawful use and contain no clause against analysis.
