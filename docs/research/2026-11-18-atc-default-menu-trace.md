# Default destination menu diagnostics

The implementation-8 investigation cannot identify (a) no menu opening, (b) a title mismatch, (c) a disabled item, or (d) a binding failure from static inspection. Both destination Pickers use `SettingsAirTrafficSection.pickerContext`, which supplies the same `DestinationChoice.mostRecent` tag and `Most Recent Space` title. The default binding calls `AirTrafficModel.setDefault`. These paths do not establish what the VM's native menu actually exposes.

The check now records every menu beginning tracking during phases 8–10, including item titles, enabled/hidden flags, selection state and highlight. Its action observer records each match or rejection and its reason, the chosen index, and action entry/return. The check records whether the default popup click was posted. Records appear both on stdout under `atc_menu_trace` and in timeout diagnostics at `details.atc_menu_trace`.

The action still requires an exact, visible, enabled, non-separator item and runs during native menu tracking. No setter fallback or product change was added. A separate observer keeps tracing after the one-shot action observer is removed and is removed when the check is released.

The next design VM run must distinguish the four causes from these records. No host app or VM was run for this investigation. The existing `engine/patch-state.sha256` modification and `docs/HANDOVER.md` are outside this change.

Validation: full `swift test --no-parallel` passed with Xcode's `DEVELOPER_DIR` and `SDKROOT` explicitly selected: 152 PromptFixtureTests and 653 UI tests, 805 total, zero failures. Both test-process window guards reported no onscreen windows. Log: `/tmp/atcfield-10-swift-test.log`. One new test covers phase gating, selection/state serialization, and observer rejection reasons; the existing two-destination action test also asserts the match/action trace. `git diff --check` passed.
