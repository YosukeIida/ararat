Draft 2 substantially addresses the first review, but six findings remain. No Blocker finding is supported by the files.

1. **Major — Epoch changes do not establish device revocation.**  
   **Location:** `docs/architecture.md`, §8.2, lines 253–259.  
   **Problem:** A removed device knows the group secret. Deriving subsequent keys from that same secret and a new epoch allows it to derive those keys too. Revoking relay access alone does not revoke its ability to decrypt future ciphertext obtained elsewhere.  
   **Evidence:** Line 253 derives keys “from the group secret and the current epoch”; line 259 promises “a new epoch with fresh keys” without requiring new secret entropy or defining its distribution.  
   **Suggested fix:** Require fresh epoch secret material distributed only to remaining devices. Define how removal affects recovery phrases, membership authority and relay credentials. This leaves round-1 finding **#2 partially resolved**.

2. **Major — Tree repair can depend on merge order.**  
   **Location:** `docs/architecture.md`, §6.1, line 213; §8.3, line 265.  
   **Problem:** Deterministically repairing each intermediate tree does not guarantee convergence if repair overwrites the underlying membership registers. Consider initially independent folders X and Y, with three timestamp-ordered moves: X→Y, Y→X, then Y→root. A device receiving the first two moves repairs X back to root; receiving the third leaves both at root. A device receiving all three before repair retains X under Y. Both received the same original moves.  
   **Evidence:** The architecture applies repair after merge. The existing implementation persists repaired memberships as `Op::Put` operations while retaining their HLC (`core/ararat-core/src/tree.rs:1–3`, `:73–77`). Its tests establish validity and idempotence of individual repairs, rather than convergence across delivery orders (`core/ararat-core/tests/tree.rs:24–35`). This implementation does not establish the convergence the architecture requires.  
   **Suggested fix:** Preserve the merged membership registers and derive the repaired tree without overwriting them, or specify a repair protocol proven to converge. Add delivery-order tests using the example above. Round-1 **#4 remains partially resolved**.

3. **Major — Startup reconciliation can resurrect durably removed tabs.**  
   **Location:** `docs/architecture.md`, §5.2, lines 198–201.  
   **Problem:** The reconciliation rule treats every engine-only tab as a newly created tab. It cannot distinguish that case from stale engine session data for a tab whose removal already committed to SQLite. Conversely, workspace-only tabs can represent completed engine closes. Without a durable ordering rule between the two stores, reconciliation can undo changes older than the stated one-second loss window.  
   **Evidence:** Line 199 restores workspace-only tabs and adopts engine-only tabs into Today. Line 200 bounds loss using the SQLite commit, but §4.6, line 151 assigns session persistence to a separate engine mechanism without a corresponding durability boundary. Stable IDs identify tabs; they do not establish which lifecycle state is newer.  
   **Suggested fix:** Define durable lifecycle metadata and reconciliation precedence for creation, close, archive and unload. Specify how stale session entries and late command completions are rejected. Scope the one-second guarantee to successful storage operation; line 201 permits retries beyond that bound. Round-1 **#5 remains partially resolved**.

4. **Major — Extension focus semantics omit native-window focus.**  
   **Location:** `docs/architecture.md`, §4.6, line 124.  
   **Problem:** The stated rule makes the displayed profile’s `Browser` focused in each application window. With two application windows, both displayed browsers satisfy that rule, including the background window. Profile visibility alone cannot determine application focus. The text also combines “current” and “focused” without defining the result for an extension running in a hidden profile.  
   **Evidence:** Line 124 says the displayed profile’s browser “is the focused, current window” and promises tests with two application windows, but supplies no native-key-window or application-activation condition.  
   **Suggested fix:** Define focus using both profile visibility and native-window/application focus. Define current-window resolution separately for extension execution contexts, including hidden profiles. Include focus transfer and application deactivation in the spike checks. Round-1 **#8 remains partially resolved**.

5. **Major — Outside-window reveal has no observation mechanism while hidden.**  
   **Location:** `docs/architecture.md`, §7, line 237.  
   **Problem:** The sidebar must reveal after an outside-window dwell, but sampling starts only while it is already shown. A pointer approaching the window from the left without entering it cannot trigger the specified reveal.  
   **Evidence:** The same paragraph states that tracking areas report nothing outside the window, sampling runs “while the sidebar is shown,” and sampling stops when it hides. The observation supporting outside reveal explicitly tested positions 5 and 47 pt outside (`docs/research/arc-ardia-observed.md:12`).  
   **Suggested fix:** Define pointer observation while the sidebar is hidden and the application is active, including dwell cancellation and selection of the eligible window. Stop observation on deactivation. Round-1 **#15 remains partially resolved**.

6. **Minor — Duplicate selection within one window has no ownership rule.**  
   **Location:** `docs/architecture.md`, §4.6, lines 131–132.  
   **Problem:** The ownership rule covers a second “window or pane,” but resolves ownership by which window becomes key. Selecting an already displayed tab in another pane of the same window produces no key-window transition, so the rule does not identify which pane receives the page or placeholder.  
   **Evidence:** Line 131 requires one page in exactly one pane, then assigns transfer through key-window changes. Line 132 defines pane focus but does not connect it to duplicate selection.  
   **Suggested fix:** Either prohibit duplicate selection within a window or specify that the newly focused pane takes ownership and the previous pane receives the placeholder. Add this case to the split-pane spike. Round-1 **#9 remains partially resolved**.

The accepted round-1 findings were checked as follows:

| Round-1 findings | Draft-2 assessment |
|---|---|
| #1 | Addressed by §4.9 and the phase-6 daily-use gate. |
| #2, #4, #5, #8, #9, #15 | Partially resolved; findings above describe the remaining cases. |
| #3, #6, #7 | Addressed at specification level by indefinite tombstones, engine session ownership and the central private-browsing boundary. |
| #10–14 | Addressed at specification level by the duties matrix, adjusted coordinator/password design, build manifest, import provenance rules and compositor spike. |
| #16–20 | Addressed by the reordered roadmap, provisional base decision, creation-path enumeration, corrected Objective-C attribution and isolated benchmark processes. |

The settings window and per-profile Extensions pane are consistent with §9. §14 explicitly leaves the per-space interaction for a mock. The roadmap places substantial UI work after the engine spike and daily adoption after the security gate. I found no substantive English/Japanese divergence; the findings above apply to both versions.

No files were changed. No builds or runtime tests were run; engine behavior, protocol security and release readiness remain unverified.