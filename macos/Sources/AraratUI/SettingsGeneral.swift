import AraratKit
import SwiftUI

/// The General pane (P5b, the E-General board's first three rows): Default browser, When Ararat
/// opens, and Save downloads to with Ask where to save each file. The rest of E-General (Warn
/// before quitting, Search engine, Show search suggestions, Check spelling) stays phase 7 and is
/// not drawn, so the pane holds no disabled rows.
struct SettingsGeneralSection: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(spacing: SettingsMetrics.cardGap) {
            SettingsGroupCard {
                SettingsCardRow(first: true, hit: model.highlighted == SettingsModel.defaultBrowserRowID,
                                marker: SettingsModel.rowMarker(SettingsModel.defaultBrowserRowID)) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Default browser")
                        if model.defaultBrowserIsDefault {
                            // The status face: the row says what is true now, and offers no
                            // button, because going back to another browser is System Settings'
                            // job.
                            Text("Ararat is your default browser").font(.caption).foregroundStyle(.secondary)
                                .background(SettingsMarker(id: SettingsModel.defaultBrowserStatusMarker))
                        } else {
                            Text("Ararat opens links from other apps").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if !model.defaultBrowserIsDefault {
                        Button("Make Default") { model.makeDefaultBrowser() }
                            .background(SettingsMarker(id: SettingsModel.makeDefaultButtonMarker))
                    }
                }.id(SettingsModel.defaultBrowserRowID)
            }
            SettingsGroupCard {
                SettingsCardRow(first: true, hit: model.highlighted == SettingsModel.startupRowID,
                                marker: SettingsModel.rowMarker(SettingsModel.startupRowID)) {
                    SettingsRowLabel(title: "When Ararat opens", subtitle: "")
                    Menu {
                        ForEach([StartupBehavior.restoreWindows, .newWindow], id: \.self) { value in
                            Button(SettingsModel.startupLabel(value)) { model.setStartup(value) }
                        }
                    } label: {
                        Text(model.startupLabel).frame(width: 170, alignment: .center)
                    }
                    .menuIndicator(.visible).fixedSize().frame(width: 194)
                    .accessibilityLabel("When Ararat opens")
                    .accessibilityValue(model.startupLabel)
                    .background(SettingsMarker(id: SettingsModel.startupMenuMarker))
                }.id(SettingsModel.startupRowID)
            }
            SettingsGroupCard(heading: "Downloads", marker: SettingsModel.rowMarker("downloads-card")) {
                SettingsCardRow(first: true, hit: model.highlighted == SettingsModel.downloadsFolderRowID,
                                marker: SettingsModel.rowMarker(SettingsModel.downloadsFolderRowID)) {
                    HStack(spacing: 8) {
                        // The folder's own icon, as the board draws it: a folder for a chosen
                        // folder, the Downloads glyph for Chromium's default.
                        Image(systemName: model.downloads.directory.isEmpty ? "arrow.down.circle" : "folder")
                            .foregroundStyle(.secondary)
                        Text(model.downloadFolderName).lineLimit(1).truncationMode(.middle)
                            .background(SettingsMarker(id: SettingsModel.downloadsFolderMarker))
                        Spacer(minLength: 12)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Choose…") { model.chooseDownloadFolder?() }
                        .background(SettingsMarker(id: SettingsModel.downloadsChooseButtonMarker))
                }.id(SettingsModel.downloadsFolderRowID)
                SettingsCardRow(hit: model.highlighted == SettingsModel.downloadsAskRowID,
                                marker: SettingsModel.rowMarker(SettingsModel.downloadsAskRowID)) {
                    Text("Ask where to save each file")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Toggle("Ask where to save each file",
                           isOn: Binding(get: { model.downloads.askWhereToSave }, set: model.setAskWhereToSave))
                        .toggleStyle(.switch).labelsHidden().fixedSize()
                        .background(SettingsMarker(id: SettingsModel.downloadsAskSwitchMarker))
                }.id(SettingsModel.downloadsAskRowID)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
