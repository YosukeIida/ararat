import AraratKit
import SwiftUI

/// The Privacy pane (U27p, the E-Privacy board): Clear browsing data, the two cookie controls and
/// Keep history for. The board's Protection card (ads and dangerous sites) is left out entirely:
/// the blocker and the reputation source are the owner's open decisions (§14), and the pane draws
/// no disabled rows.
struct SettingsPrivacySection: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(spacing: SettingsMetrics.cardGap) {
            SettingsGroupCard {
                SettingsCardRow(first: true, hit: model.highlighted == SettingsModel.privacyClearRowID,
                                marker: SettingsModel.rowMarker(SettingsModel.privacyClearRowID)) {
                    SettingsRowLabel(title: "Clear browsing data", subtitle: "History, cookies, cache")
                    Button("Clear…") { model.openClearSheet() }
                        .background(SettingsMarker(id: SettingsModel.privacyClearButtonMarker))
                }.id(SettingsModel.privacyClearRowID)
            }
            SettingsGroupCard {
                SettingsCardRow(first: true, hit: model.highlighted == SettingsModel.privacyCookiesRowID,
                                marker: SettingsModel.rowMarker(SettingsModel.privacyCookiesRowID)) {
                    SettingsRowLabel(title: "Third-party cookies", subtitle: "")
                    Menu {
                        ForEach([ThirdPartyCookies.block, .allow], id: \.self) { value in
                            Button(value.label) { model.setThirdPartyCookies(value) }
                        }
                    } label: {
                        Text(model.privacy.thirdPartyCookies.label).frame(width: 88, alignment: .center)
                    }
                    .menuIndicator(.visible).fixedSize().frame(width: 112)
                    .accessibilityLabel("Third-party cookies")
                    .accessibilityValue(model.privacy.thirdPartyCookies.label)
                    .background(SettingsMarker(id: SettingsModel.privacyCookiesMenuMarker))
                }.id(SettingsModel.privacyCookiesRowID)
                SettingsCardRow(hit: model.highlighted == SettingsModel.privacyGPCRowID,
                                marker: SettingsModel.rowMarker(SettingsModel.privacyGPCRowID)) {
                    SettingsRowLabel(title: "Ask sites not to sell or share my data",
                                     subtitle: "Sends Global Privacy Control")
                    Toggle("Ask sites not to sell or share my data",
                           isOn: Binding(get: { model.privacy.globalPrivacyControl },
                                         set: model.setGlobalPrivacyControl))
                        .toggleStyle(.switch).labelsHidden().fixedSize()
                        .background(SettingsMarker(id: SettingsModel.privacyGPCSwitchMarker))
                }.id(SettingsModel.privacyGPCRowID)
            }
            SettingsGroupCard(heading: "History", marker: SettingsModel.rowMarker(SettingsModel.privacyHistoryCardID)) {
                SettingsCardRow(first: true, hit: model.highlighted == SettingsModel.privacyHistoryRowID,
                                marker: SettingsModel.rowMarker(SettingsModel.privacyHistoryRowID)) {
                    SettingsRowLabel(title: "Keep history for", subtitle: "")
                    Menu {
                        ForEach([HistoryRetention.week, .month, .threeMonths, .year, .forever], id: \.self) { value in
                            Button(value.label) { model.setHistoryRetention(value) }
                        }
                    } label: {
                        Text(model.privacy.historyRetention.label).frame(width: 96, alignment: .center)
                    }
                    .menuIndicator(.visible).fixedSize().frame(width: 120)
                    .accessibilityLabel("Keep history for")
                    .accessibilityValue(model.privacy.historyRetention.label)
                    .background(SettingsMarker(id: SettingsModel.privacyHistoryMenuMarker))
                }.id(SettingsModel.privacyHistoryRowID)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// P4's Clear browsing data sheet, over the settings window: the range, the profile the sheet
/// clears (named, not chosen — the pane acts on the window that opened Settings), the three types
/// and Clear. Values Ararat sets are multiples of 8 (720/16/24), so the sheet's own parts follow
/// the mock-decisions rule.
struct SettingsPrivacyClearSheet: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Clear browsing data")
                .font(.system(size: 15, weight: .semibold))
                .background(SettingsMarker(id: SettingsModel.privacySheetTitleMarker))
            HStack(spacing: 8) {
                Text("From")
                Menu {
                    ForEach(ClearBrowsingRange.allCases, id: \.self) { range in
                        Button(range.title) { model.clearRange = range }
                    }
                } label: {
                    Text(model.clearRange.title).frame(width: 128, alignment: .center)
                }
                .menuIndicator(.visible).fixedSize().frame(width: 152)
                .accessibilityLabel("From")
                .accessibilityValue(model.clearRange.title)
                .background(SettingsMarker(id: SettingsModel.privacySheetRangeMenuMarker))
                Spacer(minLength: 8)
                Text("Profile").foregroundStyle(.secondary)
                Text(model.privacyProfile).lineLimit(1)
                    .background(SettingsMarker(id: SettingsModel.privacySheetProfileMarker))
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(ClearBrowsingTypes.ordered.enumerated()), id: \.offset) { index, entry in
                    Toggle(entry.1, isOn: Binding(
                        get: { model.clearTypes.contains(entry.0) },
                        set: { on in
                            if on { model.clearTypes.insert(entry.0) } else { model.clearTypes.remove(entry.0) }
                        }))
                        .toggleStyle(.checkbox)
                        .background(SettingsMarker(id: SettingsModel.privacySheetTypeMarker(index)))
                }
            }
            Text(SettingsModel.clearSheetNote)
                .font(.caption).foregroundStyle(.secondary)
                .background(SettingsMarker(id: SettingsModel.privacySheetNoteMarker))
            HStack(spacing: 8) {
                Spacer()
                // L3: the unit's rule is Cancel as the default (Return and Esc both cancel); one
                // SwiftUI button cannot take both shortcuts, so Cancel takes Return and a hidden
                // button in the row's background carries Esc.
                Button("Cancel") { model.cancelClearSheet() }
                    .keyboardShortcut(.defaultAction)
                    .background(SettingsMarker(id: SettingsModel.privacySheetCancelMarker))
                Button("Clear") { model.confirmClearSheet() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(model.clearTypes.isEmpty || model.clearing)
                    .background(SettingsMarker(id: SettingsModel.privacySheetClearMarker))
            }
            .background {
                Button("") { model.cancelClearSheet() }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
        .padding(24)
        .frame(width: 504)
        .onExitCommand { model.cancelClearSheet() }
    }
}
