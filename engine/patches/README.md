# Engine patch set

`series` is the only source of patch order; paths in it are relative to this
directory, ungoogled/generic before ungoogled/macos. The vendored patches
come from the commits below.

| Source | Commit | Chromium |
|---|---|---|
| ungoogled-software/ungoogled-chromium, pull request #4032 (merged 2026-11-04, tag `157.0.8103.38-1`) | de09e0c70c6bc1ac83d4ecdfd0e82c7e250c9a3c | 157.0.8103.38 |
| ungoogled-software/ungoogled-chromium-macos | 31f01756a43d55b2c4211e73ca329bfab4ebfcb2 | 156.0.8078.79 |

The generic patches are byte-for-byte copies of that pull request's head,
which targets 157.0.8103.38 and applies to our 157.0.8103.39 without fuzz;
the merge commit equals the vendored head, so re-vendoring is unnecessary. Of the two macOS
patches, `add-local-network-usage-description.patch` is a copy and
`disable-crashpad-handler.patch` is rebased by hand onto 157 (crashpad's
`InitialStart` gained an `embedder_port` parameter): it keeps the original's
effect, `InitialStart` returns an empty send right and `StartHandler` returns
false.

Both projects are BSD-3-Clause; their LICENSE files are kept unchanged at
`ungoogled/generic/LICENSE` and `ungoogled/macos/LICENSE`.

## Patches in series order

| File in `series` | Origin |
|---|---|---|
| `ungoogled/generic/upstream-fixes/missing-dependencies.patch` | generic, upstream-fixes |
| `ungoogled/generic/core/inox-patchset/0003-disable-autofill-download-manager.patch` | generic, core/inox-patchset |
| `ungoogled/generic/core/inox-patchset/0021-disable-rlz.patch` | generic, core/inox-patchset |
| `ungoogled/generic/core/iridium-browser/safe_browsing-disable-incident-reporting.patch` | generic, core/iridium-browser |
| `ungoogled/generic/core/ungoogled-chromium/disable-crash-reporter.patch` | generic, core |
| `ungoogled/generic/core/ungoogled-chromium/disable-google-host-detection.patch` | generic, core |
| `ungoogled/generic/core/ungoogled-chromium/toggle-translation-via-switch.patch` | generic, core |
| `ungoogled/generic/core/ungoogled-chromium/disable-profile-avatar-downloading.patch` | generic, core |
| `ungoogled/generic/core/ungoogled-chromium/disable-gcm.patch` | generic, core |
| `ungoogled/generic/core/ungoogled-chromium/disable-domain-reliability.patch` | generic, core |
| `ungoogled/generic/core/ungoogled-chromium/disable-gaia.patch` | generic, core |
| `ungoogled/generic/core/ungoogled-chromium/disable-fonts-googleapis-references.patch` | generic, core |
| `ungoogled/generic/core/ungoogled-chromium/disable-webrtc-log-uploader.patch` | generic, core |
| `ungoogled/generic/core/ungoogled-chromium/disable-ai.patch` | generic, core |
| `ungoogled/generic/core/ungoogled-chromium/disable-network-time-tracker.patch` | generic, core |
| `ungoogled/generic/core/ungoogled-chromium/block-requests.patch` | generic, core |
| `ararat/restore-component-updater.patch` | ours |
| `ungoogled/generic/core/ungoogled-chromium/remove-navigation-source-param.patch` | generic, core |
| `ungoogled/generic/core/bromite/disable-fetching-field-trials.patch` | generic, core/bromite |
| `ungoogled/generic/extra/ungoogled-chromium/disable-intranet-redirect-detector.patch` | generic, extra |
| `ungoogled/generic/extra/ungoogled-chromium/fix-building-without-mdns-and-service-discovery.patch` | generic, extra |
| `ungoogled/generic/extra/ungoogled-chromium/disable-dial-repeating-discovery.patch` | generic, extra |
| `ungoogled/generic/extra/ungoogled-chromium/add-credits.patch` | generic, extra |
| `ungoogled/generic/extra/ungoogled-chromium/disable-ai-search-shortcuts.patch` | generic, extra |
| `ungoogled/macos/ungoogled-chromium/macos/disable-crashpad-handler.patch` | macos |
| `ungoogled/macos/ungoogled-chromium/macos/add-local-network-usage-description.patch` | macos |
| `ararat/remove-screenai-sandbox-parameter.patch` | ours |
| `ararat/link-ararat-layer.patch` | ours |
| `ararat/extra-parts-hook.patch` | ours |
| `ararat/permission-prompt-hook.patch` | ours |
| `ararat/devtools-hook.patch` | `mantrakp04/ardia` (GPL-3.0) |
| `ararat/autofill-address-bubble.patch` | `mantrakp04/ardia` (GPL-3.0) |
| `ararat/app-controller-hooks.patch` | ours |
| `ararat/browser-window-factory.patch` | ours |
| `ararat/viewless-read-anything.patch` | ours |
| `ararat/viewless-bubble-anchor.patch` | ours |
| `ararat/sad-tab-viewless.patch` | ours; Ardia has the same guard |
| `ararat/keyboard-ime-diagnostics.patch` | ours |
| `ararat/find-close-command.patch` | ours |
| `ararat/hidden-dialog-containment.patch` | ours |
| `ararat/history-deletion-hook.patch` | ours |
| `ararat/crash-lock-abandon.patch` | ours |
| `ararat/history-retention.patch` | ours |
| `ararat/command-line-urls-hook.patch` | ours |

## Why these upstream patches

Every per-patch keep/skip/counter-patch decision and its security consequence
is in `docs/research/ungoogled-inventory.md` §8.

## Notes on our patches

`ararat/sad-tab-viewless.patch` returns without installing a stock sad-tab view when a hosted window has no `BrowserView`. Ardia (`mantrakp04/ardia`, GPL-3.0) has the same guard in `engine/ardiacore/apply.sh`. This patch was written independently against Chromium's source.

`ararat/history-deletion-hook.patch` calls an optional hook before HistoryService schedules a deletion, allowing Ararat to invalidate tab history on the file sequence.
The mode 1 check requests `DeleteURLs` and waits for the file-sequence barrier. It confirms that the request hook queued invalidation; it does not wait for the history backend or its later deletion notification.

`ararat/history-retention.patch` adds an atomic retention in days to `ExpireHistoryBackend::GetCurrentExpirationTime()`, so the app's Privacy pane replaces Chromium's fixed 90-day threshold on every expiry pass; a value of 0 (the pane's Forever and the state before the first apply) makes `DoExpireIteration()` return before any reader or the segment cleanup and restarts the queue at the five-minute cadence, so nothing expires, no deletion runs on a null `Time`'s `LocalMidnight`, and a retention set later takes effect within about five minutes.

`ararat/crash-lock-abandon.patch` lets the host release a crash lock without acknowledging the crash when its profile is destroyed before workspace recovery completes.

`ararat/command-line-urls-hook.patch` forwards a second launch's URL arguments, after Chromium loads its startup profile, to the app's external-open entry before `--no-startup-window` suppresses the stock launch. An unset hook keeps Chromium's path.

`ararat/permission-prompt-hook.patch` calls our hook from `ChromePermissionsClient::CreatePrompt`; an unset hook or a null result keeps Chrome's prompt. `link-ararat-layer.patch` adds `//ararat/core:hooks` to the permissions build target.

`ararat/devtools-hook.patch` adapts `mantrakp04/ardia`'s `engine/patches/chromium-window-docked-devtools.patch` (GPL-3.0). It reports `DevtoolsUIController::UpdateDevtools` through an optional hook; unset leaves Chrome's behavior intact. `link-ararat-layer.patch` adds `//ararat/core:hooks` to the DevTools build target.

`ararat/autofill-address-bubble.patch` comes from `mantrakp04/ardia`'s `engine/patches/chromium-autofill-address-bubble-window.patch` (GPL-3.0). It finds the Autofill handler on the Browser's unowned user data, guards the address promo's `AsBrowserView()` call and returns early from two card-controller checks.

`ararat/keyboard-ime-diagnostics.patch` records bounded browser target and forwarding observations for the keyboard checks without recording input text.

`ararat/hidden-dialog-containment.patch` lets the hidden-check layer reject unexpected ordinary JavaScript dialogs and validate beforeunload admission and completion at the WebContents boundary.

`ararat/find-close-command.patch` refreshes command state after ending a find session, when the find UI is no longer active.

`ararat/app-controller-hooks.patch` routes Dock reopen and menu actions, external URLs and the shown Browser through our hooks, leaving stock behavior when the hooks are unset. Native openURLs and Handoff normalize the last profile to its original regular profile, preserving forced-incognito policy, so an active private window does not divert external links away from Air Traffic Control.

`ararat/remove-screenai-sandbox-parameter.patch` deletes the ScreenAI branch of
the sandbox parameters in `chrome/browser/chrome_content_browser_client.cc`:
with ScreenAI removed by `disable-ai`, that branch's
`ScreenAIInstallState::GetInstance()` is an undefined symbol and the link fails.


`ararat/restore-component-updater.patch` reverses only `block-requests`'s hunk
in `components/update_client/update_checker.cc`, so the component updater
performs its network update checks again; every other hunk of that patch stays
in force. Google Safe Browsing likewise stays in the build:
`fix-building-without-safebrowsing` is not vendored and `engine/args.gn` does
not set `safe_browsing_mode=0` (no API key is set either way).

`ararat/link-ararat-layer.patch` adds `//ararat/core` to the framework's deps,
passes `ararat.exports` to the linker and adds our symbols to
`chrome/app/framework.order`. `ararat/extra-parts-hook.patch` calls
`g_ararat_add_browser_main_extra_parts` at the end of
`ChromeContentBrowserClient::CreateBrowserMainParts` when it is set; unset,
Chrome runs stock. `ararat/browser-window-factory.patch` calls our window
factory in the `Browser` constructor when it is set; if unset or it returns
null, Chrome creates the stock window. It also skips saving location-bar state when a window has no location bar. architecture §4.3 lists the hooks.

When the factory hook is set, the patch disables Chrome session restore before
`BrowserInitState` captures its flags, including for Browsers using stock windows.
Ararat restores its own workspace from the core in U17.

`ararat/viewless-read-anything.patch` skips side-panel cleanup for our viewless windows when there is no side panel.

`ararat/viewless-bubble-anchor.patch` returns an empty page-info anchor after checking the location bar's chip when there is no `BrowserView`. The chooser and file-system restore bubbles then use a fallback at the host window's leading top edge, offset by Chromium's no-toolbar value and mirrored in RTL. Missing or empty hosts return an empty rectangle; stock `BrowserView` paths are unchanged. Runtime bubble placement remains to be verified.

U14's extension action container and popup anchor are in our layer and add no Chromium patch. The external-install error dialog still assumes a `BrowserView`; supporting external installs requires a guard or patch (ours).
