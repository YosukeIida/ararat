import AppKit
import AraratKit
import SwiftUI

/// U27x: Settings › Extensions (E-Extensions, X1–X3). The profile chooser names the regular
/// profiles and starts on the profile of the window that opened Settings; the Installed card lists
/// that profile's extensions with an icon (or the board's letter), the site-access summary, the
/// enable switch, Review… instead of the switch when Chromium disabled one for new permissions,
/// and the … menu. Add from Arc and Find more wait for the owner's Arc verification (§14).
struct SettingsExtensionsSection: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(spacing: SettingsMetrics.cardGap) {
            SettingsGroupCard {
                SettingsCardRow(height: 60, first: true,
                                hit: model.highlighted == SettingsModel.extensionsProfileRowID,
                                marker: SettingsModel.rowMarker(SettingsModel.extensionsProfileRowID)) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Profile")
                        Text("Extensions are installed per profile")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Picker("Profile", selection: Binding(get: { model.extensionProfile },
                                                         set: model.selectExtensionProfile)) {
                        ForEach(model.extensionProfiles, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(width: 120)
                    .background(SettingsMarker(id: SettingsModel.extensionsProfileMenuMarker))
                    .accessibilityLabel("Profile")
                }.id(SettingsModel.extensionsProfileRowID)
            }
            SettingsGroupCard(heading: "Installed", marker: SettingsModel.rowMarker(SettingsModel.extensionsListCardID)) {
                if model.extensionsLoading && model.extensions.isEmpty {
                    Text("Loading extensions…")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 22)
                        .background(SettingsMarker(id: SettingsModel.extensionsLoadingMarker))
                } else if model.extensions.isEmpty {
                    Text("No extensions in this profile yet.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 22)
                        .background(SettingsMarker(id: SettingsModel.extensionsEmptyMarker))
                } else {
                    ForEach(Array(model.extensions.enumerated()), id: \.element.id) { index, row in
                        SettingsCardRow(height: 60, first: index == 0,
                                        hit: model.highlighted == SettingsModel.extensionRowID(row.id),
                                        marker: SettingsModel.rowMarker(SettingsModel.extensionRowID(row.id))) {
                            ExtensionIconView(row: row)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.name).lineLimit(1)
                                if !row.summary.isEmpty {
                                    Text(row.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            if row.needsReview {
                                Button("Review…") { model.reviewExtension(row.id) }
                                    .background(SettingsMarker(id: SettingsModel.extensionReviewMarker(row.id)))
                                    .accessibilityLabel("Review new permissions for \(row.name)")
                            } else if row.canDisable {
                                // X2 (design): an extension Chromium does not let the user switch
                                // shows no switch, as chrome://extensions draws it.
                                Toggle("Enable \(row.name)", isOn: Binding(
                                    get: { row.enabled },
                                    set: { model.setExtensionEnabled(row.id, enabled: $0) }))
                                    .toggleStyle(.switch).labelsHidden().fixedSize()
                                    .background(SettingsMarker(id: SettingsModel.extensionSwitchMarker(row.id)))
                                    .accessibilityLabel("Enable \(row.name)")
                            }
                            ExtensionMenu(model: model, row: row)
                        }.id(SettingsModel.extensionRowID(row.id))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// The … menu of one installed extension (X2): the site access, Pin/Unpin, Manage Extension and
/// Remove…. The entries come from `SettingsModel.extensionMenu`, so the menu and the model tests
/// agree about what a row can do.
private struct ExtensionMenu: View {
    @ObservedObject var model: SettingsModel
    let row: SettingsExtension

    var body: some View {
        Menu {
            ForEach(Array(SettingsModel.extensionMenu(row).enumerated()), id: \.offset) { _, entry in
                switch entry {
                case .separator:
                    Divider()
                case .siteAccess(let access):
                    Button {
                        model.setExtensionSiteAccess(row.id, access: access)
                    } label: {
                        if row.siteAccess == access {
                            Label(access.title, systemImage: "checkmark")
                        } else {
                            Text(access.title)
                        }
                    }
                    .disabled(access == .onSpecificSites)
                case .pin, .unpin:
                    Button(entry.title) { model.toggleExtensionPin(row.id) }
                case .manage:
                    Button(entry.title) { model.manageExtension(row.id) }
                case .remove:
                    Button(entry.title, role: .destructive) { model.requestRemoveExtension(row.id) }
                }
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 30)
        }
        .menuIndicator(.hidden).menuStyle(.borderlessButton).fixedSize()
        .background(SettingsMarker(id: SettingsModel.extensionMenuMarker(row.id)))
        .accessibilityLabel("More actions for \(row.name)")
    }
}

/// The extension's icon in the board's 32 pt slot; an extension without one draws its first
/// letter in the same rounded square the site rows use.
private struct ExtensionIconView: View {
    let row: SettingsExtension

    var body: some View {
        Group {
            if let icon = row.icon {
                Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
            } else {
                Text(row.letter)
                    .font(.system(size: 14, weight: .medium))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 6).fill(SettingsColor.selected))
            }
        }
        .frame(width: 32, height: 32)
    }
}
