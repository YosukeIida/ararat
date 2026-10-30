1. **Major — Security maintenance is missing from the operating model.**  
   **Section:** §4.7–4.8, §14, §15.  
   **Problem:** Chromium upgrades require individual approval, builds depend on one workstation, and automatic updating arrives after the owner adopts the browser. There is no maximum security-patch lag, emergency release procedure, or response when Helium falls behind. Safe Browsing remains undecided despite “daily-usable” exit criteria.  
   **Evidence:** `cra-ledger.ja.md` §2, decision 6 explicitly adopts daily update detection; `ardia-ledger.ja.md` §3 warns against shipping without reputation checks. Chromium ships weekly security refreshes because public fixes expose unpatched browsers. [Chromium release cycle](https://chromium.googlesource.com/chromium/src/+/HEAD/docs/process/release_cycle.md)  
   **Fix:** Make upstream monitoring, a patch-lag limit, emergency build authority, and a tested update path prerequisites for daily use. Require an explicit URL/download reputation implementation before that gate.

2. **Major — The sync description does not yet specify a secure protocol.**  
   **Section:** §8.1–8.4.  
   **Problem:** AES-GCM and HKDF name primitives but leave nonce allocation, domain separation, device authentication, pairing authentication, replay handling, and device revocation unspecified. Independent device sequence numbers do not guarantee unique nonces under the shared file key. A short-lived pairing code alone does not prevent interception or guessing. Possession of the recovery secret also remains permanent access unless keys rotate.  
   **Evidence:** A repeated AES-GCM nonce under one key compromises confidentiality and authentication. HMAC-derived object names conceal names but do not define authorization for the relay’s `put/get/list` operations.  
   **Fix:** Specify a versioned protocol before implementation: per-device encryption keys or another defensible nonce scheme, authenticated pairing, separate relay credentials, immutable authenticated object identities, persisted replay checkpoints, and removal/rekey behavior. BIP-39 is a reasonable recovery encoding; it does not supply these properties.

3. **Major — Tombstone expiry knowingly permits deleted data to return.**  
   **Section:** §8.2.  
   **Problem:** The draft adopts 45/90-day deletion retention while deferring the mechanism that makes collection safe. A device returning after that interval can resurrect deleted workspace records; password and extension records make this more serious than sidebar clutter.  
   **Evidence:** `ardia-ledger.ja.md` §3 explicitly identifies resurrection after the retention interval as a known defect and says not to rely on wall-clock collection. The architecture cites that warning while reproducing the defect.  
   **Fix:** Initially retain deletion metadata indefinitely. Before collecting it, define device retirement, synchronization epochs, and mandatory snapshot rejoin for expired devices. Incarnation and sequence protection after backup restoration must work from the first sync release.

4. **Major — Record-level LWW does not preserve the workspace tree.**  
   **Section:** §6.1, §8.2.  
   **Problem:** Convergent records can produce an invalid tree. Device A moves folder X under Y while device B moves Y under X: both winning records can survive and create a cycle. Independently merging `parentID` and ordered child lists also produces duplicate membership or unreachable items.  
   **Evidence:** `arc-dia-components.ja.md` §3.2 records both parent IDs and child order. Commutativity, associativity, and idempotence of individual registers do not establish structural validity.  
   **Fix:** Define one authoritative membership representation and deterministic rules for cycles, missing parents, concurrent moves, ordering, and delete-versus-edit. Require convergence **and tree-invariant tests**, including those cases.

5. **Major — Revisioned transactions do not establish crash consistency.**  
   **Section:** §5, §6.2–6.3.  
   **Problem:** Chrome commits first and Rust persists later. If the process dies between them, a closed tab can return or a newly created tab can disappear. `{rev, cmd, strips}` lacks a defined engine epoch, persistent workspace-to-engine identity mapping, startup reconciliation, and handling for delayed completion after cancellation. SQLite cannot make an in-memory Chrome mutation atomic with a database transaction.  
   **Evidence:** `ardia-ledger.ja.md` §1.4 additionally specifies a baseline snapshot after restart and transactions that never mix causes; those guarantees are absent here.  
   **Fix:** Specify startup snapshots, epoch-qualified revisions, stable IDs, durable operation handling, reconciliation, and an explicit acceptable crash-loss window. Commit workspace changes and outgoing sync records together in SQLite. Include disk-full and interrupted-write behavior and a WAL-aware backup procedure. [SQLite backup API](https://www.sqlite.org/backup.html)

6. **Major — Disabling `SessionService` leaves session payload ownership unresolved.**  
   **Section:** §4.6, §5, §15 phase 4.  
   **Problem:** Workspace metadata is insufficient to restore a browser session. The design does not assign responsibility for navigation stacks, selected navigation entries, session-storage namespaces, or restoring closed tabs into their original workspace positions. Restoring only URLs loses Back/Forward state and session-dependent applications.  
   **Evidence:** Chromium’s restore implementation reconstructs navigation entries and session-storage namespaces before adding restored tabs. `arc-dia-components.ja.md` §4.1 also identifies engine-side session objects. [Chromium session restore](https://github.com/chromium/chromium/blob/main/chrome/browser/sessions/session_restore.cc)  
   **Fix:** Keep Chromium-specific session serialization behind the engine API, with opaque references associated with Rust workspace IDs. Define retention and restoration for live, unloaded, archived, and recently closed tabs. Disabling automatic Chrome window restoration is reasonable; omitting its persistence responsibilities is not.

7. **Major — Incognito has an entry path but no persistence boundary.**  
   **Section:** §4.6, §5, §8.3.  
   **Problem:** Incognito browsers are explicitly routed into the host, but nothing says which transactions must stay out of SQLite, archive, sync, snapshots, or command-bar learning. The generic “diff and apply to workspace” rule can persist private browsing metadata.  
   **Evidence:** `ardia-ledger.ja.md` §1.1 and §1.10 place private-profile authorization in the engine, rather than leaving individual callers to infer it.  
   **Fix:** Define off-the-record identity in the engine contract and reject durable/sync operations for it centrally. Specify memory-only workspace state and tests covering close, crash, archive, and sync.

8. **Major — Multiple `Browser`s sharing one native window need explicit extension semantics.**  
   **Section:** §4.6, §9.  
   **Problem:** Native window sharing does not automatically make Chrome’s logical window APIs match the visible application. Hidden-profile browsers can retain active tabs while sharing focus and geometry with the visible profile. `windows.getCurrent`, focus events, `tabs.query({active:true})`, and `windows.update` therefore need deliberate behavior. “Internal windows are hidden” does not establish whether profile browsers are internal.  
   **Evidence:** `ardia-ledger.ja.md` §1.1 records a window-routing parity defect; `cra-ledger.ja.md` §2, decision 10 shows that extensions rely on logical window identity and type.  
   **Fix:** Define the mapping between native windows, profile browsers, extension window IDs, focus, and visibility. Test two profiles, two application windows, extension-created windows, and inactive-profile extension activity.

9. **Major — Cross-window tabs and split panes have no lifecycle contract.**  
   **Section:** §4.6, §5, §6.1.  
   **Problem:** The model owns per-window selection but does not say what happens when two windows select the same workspace tab. A native page view cannot occupy both. Split panes also require separate definitions of visibility, keyboard focus, and the tab considered active by Chrome. Closing a host window must not destroy a page another window needs.  
   **Evidence:** `cra-ledger.ja.md` §2, decisions 19–21 explicitly addresses reparenting, placeholders, window closure, and split resizing. These responsibilities were omitted.  
   **Fix:** Define page ownership and transfer, placeholder behavior, split-pane focus, and close semantics before fixing the model/API. Put cross-window transfer and a two-pane split into the engine spike.

10. **Major — Removing Chrome’s window UI removes security responsibilities beyond anchoring bubbles.**  
    **Section:** §4.5–4.6.  
    **Problem:** A Views-backed `NSWindow` supplies a native host, not complete replacements for permission prompts, external-protocol confirmation, device choosers, exclusive-access warnings, keyboard dispatch, or accessibility integration. The current acceptance list can pass while important browser behavior remains absent.  
    **Evidence:** `arc-dia-components.ja.md` §4.2 and §4.4 names permission, device, external-protocol, and dialog seams. `cra-ledger.ja.md` decision 11 identifies page-versus-browser shortcut dispatch; `ardia-ledger.ja.md` §1.10 records paste reaching the wrong page during focus handoff.  
    **Fix:** Add a responsibility matrix for removed Chrome UI, assigning every required seam to retained Chromium code or a host implementation. Include permission rejection, fullscreen exit, IME, immediate paste after ⌘L, and accessibility in acceptance tests.

11. **Major — “Platform-free Rust” does not yet establish a portable browser contract.**  
    **Section:** §3, §6.3, §8.3, §10, §14.  
    **Problem:** The shared behavior is currently described through Chrome services and a Swift coordinator. Windows/Linux would have to reproduce that coordination in C++; iPhone has neither those Chrome services nor Chrome extensions. Password sync is especially unresolved: the engine seals passwords, while the Rust sync client owns the protocol and the engine never links it on macOS.  
    **Evidence:** `ardia-ledger.ja.md` §1.11 uses an explicit page-engine contract and documents separate engine capabilities. WKWebView also provides its own profile storage mechanism. [WebKit profiles](https://webkit.org/blog/14423/building-profiles-with-new-webkit-api/)  
    **Fix:** Define portable commands, events, capabilities, secret-storage services, and coordinator state transitions now; keep platform execution in adapters. Specify password-envelope ownership and unsupported-record preservation on iPhone. Resolve “no DRM” versus “second engine” before finalizing the page API.

12. **Major — Engine artifacts are identified by an incomplete build identity.**  
    **Section:** §4.2, §4.7, §12.  
    **Problem:** An `engine/` tree hash identifies the binary only if it transitively pins Chromium, Helium, dependencies, build arguments, architecture, and toolchain inputs. The draft does not require that. The same key could otherwise select different binaries, and a source tarball containing only Ararat and patches would not reproduce the engine.  
    **Evidence:** The build also consumes files outside `engine/` and external checkouts. `series check` verifies patch/tree consistency, not artifact provenance.  
    **Fix:** Commit a complete build-input manifest covered by the artifact key, publish immutable artifact digests, and record provenance. State exactly how release sources reconstruct the upstream tree and applied layers.

13. **Major — Extension ID preservation is being treated as sufficient import provenance.**  
    **Section:** §9.  
    **Problem:** Copying a manifest `key` preserves an ID but does not authenticate the copied code. Carrying that identity into native messaging can give imported unpacked code access to native hosts allowed for that ID. A host-name exclusion list also does not validate imported host manifests or executable paths.  
    **Evidence:** `cra-ledger.ja.md` decision 8b describes an unpacked-copy mechanism; it is not a security argument. Chrome native hosts authorize extension origins through `allowed_origins`. [Native messaging](https://developer.chrome.com/docs/apps/nativeMessaging?authuser=00)  
    **Fix:** Prefer verified Web Store installation for Store extensions. Treat unpacked imports as a separate, explicitly approved trust decision. Validate host registration and executable provenance; preserve Chromium’s permission, blocklist, and incognito checks.

14. **Major — The compositor decision that the research warns can force a rewrite is absent.**  
    **Section:** §4.6, §7, §15 phase 3.  
    **Problem:** One Core Animation tree does not determine compositor ownership, frame-sink lifetime, display-link startup, occlusion, or hidden-page visibility. The proposed embedding can reproduce Ardia’s tab-switch latency despite native Swift dispatch.  
    **Evidence:** `ardia-ledger.ja.md` §1.3, §1.6, and §3 explicitly warns that changing to window-shared composition later requires a rendering rewrite.  
    **Fix:** Make compositor ownership an explicit spike decision. Measure first-frame latency, background-page activity, occlusion, resize, split panes, and display changes before accepting the embedding model.

15. **Major — Ordinary tracking areas cannot implement the complete floating-sidebar rule.**  
    **Section:** §4.6, §7.  
    **Problem:** The specified behavior depends on pointer movement after the pointer leaves the window, including movement around its other sides. `NSTrackingArea` reports entry, movement within, and exit; it does not supply continuous tracking across the desktop. Removing Cra’s panel does not remove this requirement.  
    **Evidence:** Apple defines tracking areas as regions of a view. [NSTrackingArea documentation](https://developer.apple.com/documentation/appkit/nstrackingarea?changes=latest_major)  
    **Fix:** Use tracking areas inside the window and explicitly define outside-window observation, such as scoped mouse monitoring or pointer sampling while the sidebar is exposed. Specify behavior on app deactivation, display boundaries, and unavailable global coordinates.

16. **Major — The roadmap validates the highest-risk assumptions too late and with insufficient tests.**  
    **Section:** §15.  
    **Problem:** Phase 1 completes substantial UI and persistence work before proving the engine contracts it depends on. Phase 3 accepts everything in a hidden instance, which cannot establish real focus, passkey interaction, fullscreen, accessibility, or compositor behavior. Signing arrives after credential import and daily adoption; Linux receives no exit criterion at all.  
    **Evidence:** The cited ledgers repeatedly document failures involving focus, native windows, signing identity, passkeys, and display timing. Hidden automation is useful coverage, not evidence for all those properties.  
    **Fix:** Move a minimal engine/core/UI vertical slice ahead of substantial UI work. Establish bundle/team identity, entitlements, helper signing, and credential access during that spike. Add visible integration checks, crash/relaunch tests, an offline/returning-device sync test, and separate Windows and Linux gates.

17. **Major — Helium is a plausible base, but the evidence does not establish the claimed net benefit.**  
    **Section:** §2, §4.2.  
    **Problem:** GPL compatibility and upstream platform support are valid advantages. They do not establish that Helium is cheaper to maintain after removing its updater, onboarding, services, proxy, and other product decisions. “Privacy defaults come with it” also obscures functionality that must be restored deliberately.  
    **Evidence:** `ardia-ledger.ja.md` §1.2 and §4 explicitly labels the migration rationale as inferred and records numerous counter-patches. Helium’s current build flags disable Safe Browsing and service discovery, among other choices. [Helium flags](https://github.com/imputnet/helium/blob/main/flags.gn)  
    **Fix:** Keep Helium provisional until a pinned patch inventory shows what is retained, removed, and repaired, with security consequences and one measured rebase. Identify the clean Chromium base separately from the Helium patch repository.

18. **Minor — The popup statement overstates Chromium’s navigation contract.**  
    **Section:** §4.6.  
    **Problem:** Already-created `WebContents` does not mean already-navigated `WebContents`, and ordinary modified-link navigation need not traverse the same callback as renderer-created windows. Treating them as one guaranteed path can miss creation routes or replay navigation incorrectly.  
    **Evidence:** Chromium’s `AddNewContents` contract describes an existing contents object and where navigation **will happen**. Current upstream also places the implementation in `BrowserWebContentsDelegate`, illustrating why the target revision matters. [Delegate contract](https://github.com/chromium/chromium/blob/main/content/public/browser/web_contents_delegate.h)  
    **Fix:** Describe preservation of the existing contents and pending navigation state. Enumerate creation paths on the pinned revision and test POST targets, `window.open`, modified clicks, opener relationships, and blocked popups separately.

19. **Minor — The Objective-C precedent is inaccurately summarized.**  
    **Section:** §2, §4.4.  
    **Problem:** “Dia does the same” conflates a handwritten exported Objective-C API with Dia’s generated bindings. The choice is reasonable, but the evidence does not establish equivalent maintenance cost or lifecycle behavior.  
    **Evidence:** `arc-dia-components.ja.md` §4.1 explicitly says Dia’s 146 classes and 205 headers are generated from mojom.  
    **Fix:** Correct the attribution. Specify main-thread affinity, object invalidation, callback cancellation, and ownership across Swift/Objective-C++ rather than relying on the class count as validation.

20. **Minor — The performance gate wording changes the cited methodology.**  
    **Section:** §11.  
    **Problem:** Alternating complete previous-release and candidate browsers “in one process” is not a viable general engine benchmark. Both contain process-global Chromium state.  
    **Evidence:** `ardia-ledger.ja.md` §1.9 refers to one benchmark-controller process alternating runs, not loading both browser releases into one browser process.  
    **Fix:** Say that one controller alternates isolated control/candidate processes with equivalent fixtures. Reserve same-process comparisons for genuinely isolated component benchmarks.

The main choices stand as follows:

- **Direct Chromium embedding, without CEF:** Holds for the required Chrome services and custom window model.
- **Helium:** Conditional; platform support and licence fit hold, maintenance advantage remains unverified.
- **Typed Objective-C API:** Holds for macOS, with explicit lifetime/threading contracts and corrected precedent.
- **Engine not linking Rust on macOS:** Holds; shared coordination rules must not become Swift-only behavior.
- **SQLite:** Holds. It supplies local transactions, not atomicity with Chrome or a backup policy.
- **Own blind relay with BIP-39:** Fits the account-free requirement; the present protocol is insufficient for password sync.
- **AppKit hot paths, SwiftUI settings/onboarding:** Holds. Cra’s measurements support that implementation choice, not a universal SwiftUI performance claim.
- **WKWebView on iPhone:** Holds; the stated EU/Japan engine exceptions are supported by Apple’s current documentation. [EU](https://developer.apple.com/support/alternative-browser-engines/), [Japan](https://developer.apple.com/support/alternative-browser-engines-jp/)

Could not verify:

- The intended Chromium/Helium revision, actual patch set, signing configuration, or runtime behavior.
- Yab’s outside-window behavior and permission requirements by direct observation.
- Widevine/VMP availability, credential-import coverage, and the distribution/licensing path for the iPhone build.
- The ledgers’ upstream measurements independently; no build, runtime test, or additional independent review was performed.

No files were changed. These are design findings; implementation and release safety remain unverified.