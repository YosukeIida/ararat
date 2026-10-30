# Repeating the Yab analysis

Japanese translation: `README.ja.md`. Findings: `../yab-static.md`.

Tools: REA at `~/workspace/github.com/morluto/rea` (commit 8f920bb6, after `npm ci && npm run build`) and the devshell's Ghidra 12.1.4 with OpenJDK 21. `$WORK` is the absolute path of `analysis/yab` (`WORK=$PWD/analysis/yab` from the repo root; REA needs absolute paths), which is gitignored; the analysed project and the arm64 slice are kept there. Run everything inside the devshell; `xc` is the README's function that points `DEVELOPER_DIR` at Xcode, which REA needs to compile its Swift helper.

## 1. Take the arm64 slice

```sh
lipo /Applications/yab.app/Contents/MacOS/yab -thin arm64 -output "$WORK/yab-arm64"
```

## 2. Analyse once into a saved Ghidra project

```sh
GHIDRA_HEADLESS_MAXMEM=48G "$GHIDRA_INSTALL_DIR/support/analyzeHeadless" "$WORK/ghidra-project" yab \
  -import "$WORK/yab-arm64" -scriptPath docs/research/yab -preScript DisableObjcMessage.java
```

It took 24 minutes on the Mac Studio and produced a 1.2 GB project. Two settings matter:

- The Objective-C Message Analyzer is turned off. With it on, one function kept a single thread busy for over an hour (3,940 s of CPU) after every other function had finished.
- The heap is raised. At Ghidra's default 2 GB, listing names ran out of memory and the session died.

REA's own import keeps the analysed program in memory only, so a crash loses it. Always analyse into a project first.

## 3. Query through one REA MCP session

```sh
xc env GHIDRA_HEADLESS_MAXMEM=48G REA_GHIDRA_STARTUP_TIMEOUT_MS=7200000 \
  REA_GHIDRA_PROJECT_PATH="$WORK/ghidra-project/yab.gpr" REA_GHIDRA_PROGRAM_NAME=yab-arm64 \
  node docs/research/yab/rea-driver.mjs "$WORK/box"
```

The driver writes REA's tool list to `box/tools.json`. It then runs each `box/req-<n>.json` (`{"name": tool, "arguments": {...}}`) in name order and writes the answer to `box/res-<n>.json`. Create `box/stop` to end it. Write request files with `printf`, not zsh's `echo`, which rewrites the backslashes in JSON escapes. The first request is `open_binary` with `{"path": "$WORK/yab-arm64", "provider_id": "ghidra"}`. With the saved project it returns in seconds.

Useful tools: `analyze_swift_types`, `search_procedures` and `search_strings` (regex), `xrefs`, `procedure_callers`, `procedure_pseudo_code`. To find who calls an Objective-C method, chain the queries:

1. Search the selector name with `search_strings`.
2. Take its `xrefs` to reach the selector reference.
3. Take the `xrefs` of that reference to reach the `objc_msgSend` stub.
4. Ask `procedure_callers` for the stub's callers.
