# Ararat

A macOS browser with Arc's workflow, built on Chromium. The UI is Swift (AppKit). The engine is a Chromium fork with Ararat's own layer built inside the tree. The cross-platform core is Rust. Windows, Linux and iPhone come later, but the structure assumes them from the start. The design is in `docs/architecture.md`.

## Language

Write repository files (README, AGENTS.md, everything under `docs/`, code comments, commit messages) in English unless a file says otherwise. The English file is the source of truth. Markdown documents also get a Japanese translation next to them as `<name>.ja.md` (`README.ja.md`, `docs/architecture.ja.md`), updated in the same change as the English file. Working notes overwritten every session (`docs/HANDOVER.md`, `docs/reviews/PENDING.md`) and raw reviewer output (`docs/reviews/*-codex.md`) get no translation.

## How work is done (the sandwich)

Every unit of work is split between design, orchestrator, implementation and review seats:

1. Scope and design: Claude. It writes what to build, the files it touches, the invariants and the edge cases. The orchestrator is a Claude seat.
2. Implementation: two seats run in parallel on separate worktrees: Codex on the personal account, and an OpenCode Go seat. When the personal Codex weekly quota is exhausted, continue only work the OpenCode seat can do and wait for the quota to reset. Hard work (engine changes, input and event handling, edge-case bugs, anything a review sent back twice) goes to the Codex seat; the OpenCode seat takes well-specified, mechanical work (docs, check lists, small UI fixes). Codex uses `CODEX_HOME=$HOME/.codex-personal`; Ararat never uses labteam.
3. Review: Claude. For each finding, decide fix or no fix and why, and send the fixes back to step 2.

Each seat's model and effort are set in the team config, `~/.config/herdr-agent-team/ararat.json`, not here.

For a hard edge-case bug the order is reversed: implementation investigates, design gives a second opinion, implementation fixes it, and review checks it.

Measurement and design-stage work (research notes, `docs/architecture.md`) needs no review unless the owner asks for one.

The seats run on orca-agent-team (one Orca tab per role) from a Codex session inside Orca, or on herdr-agent-team from one inside herdr. Agents get the devshell from dotfiles' agent-switch shims, which load direnv when `claude` or `codex` starts in the repo. If `command -v cargo` does not point into `/nix/store`, restart the agent from the repo instead of building with another toolchain: a second toolchain writes into the same `target/`.

## Other projects

- Reuse another open-source project's code only where its license allows it in this GPL-3.0 repository. Every file that reuses it keeps that project's copyright and license, states the changes, and that project's LICENSE and NOTICE go under `third_party/<project>/` and are bundled with the app.
- A project's names, logos, app icons and separately licensed assets are never copied.
- Arc and Dia are closed source. Use only published analyses and static analysis within their terms, and never their code or assets.
- Behaviour values follow Arc's measurements. Where Arc has not been measured, the value Ararat uses and the reason for it are recorded in the design notes.
- Research notes, including which projects were compared and under which licenses, live in `docs/research/`.
- Analyse with REA (`morluto/rea`) from a clone of its repository, not the npm package (`npx rea-agents`). Keep node inside the devshell.
