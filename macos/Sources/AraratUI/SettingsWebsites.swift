import AraratKit
import SwiftUI

/// One row of Settings › Websites' "Sites with their own settings" (W2): a site and the profile
/// whose exceptions it holds. Chromium stores exceptions per profile, so a write has to name
/// one; the list is the union across every regular profile.
public struct SettingsSiteRow: Identifiable, Equatable {
    public var origin: String
    public var profile: String
    public var settings: [SitePermissionKind: SiteState.PermissionSetting]

    public var id: String { origin + "|" + profile }
    public var display: String { SiteOrigin.display(origin) }
    public var letter: String { SiteOrigin.letter(origin) }

    public init(origin: String, profile: String, settings: [SitePermissionKind: SiteState.PermissionSetting]) {
        self.origin = origin
        self.profile = profile
        self.settings = settings
    }
}

/// The Websites pane (U27w, the E-Websites board): the seven per-permission defaults in one
/// grouped card, then the sites Chromium says have their own settings. Values are read from the
/// core and the engine on every open; every control writes through the model.
struct SettingsWebsitesSection: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(spacing: SettingsMetrics.cardGap) {
            SettingsGroupCard(heading: "For every site", marker: SettingsModel.rowMarker(SettingsModel.websitesDefaultsCardID)) {
                ForEach(Array(SitePermissionKind.allCases.enumerated()), id: \.offset) { index, kind in
                    SettingsCardRow(first: index == 0,
                                    hit: model.highlighted == SettingsModel.websiteRowID(kind),
                                    marker: SettingsModel.rowMarker(SettingsModel.websiteRowID(kind))) {
                        Image(systemName: kind.iconName)
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        Text(kind.title)
                        Spacer(minLength: 12)
                        SitePermissionMenu(model: model, kind: kind, current: SitePermissionKind.setting(for: model.siteDefaults.value(for: kind)))
                    }.id(SettingsModel.websiteRowID(kind))
                }
            }
            SettingsGroupCard(heading: "Sites with their own settings", marker: SettingsModel.rowMarker(SettingsModel.websitesSitesCardID)) {
                if model.siteRows.isEmpty {
                    Text("No site has its own settings yet.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 22)
                        .background(SettingsMarker(id: SettingsModel.websitesEmptyMarker))
                } else {
                    ForEach(Array(model.siteRows.enumerated()), id: \.element.id) { index, row in
                        SettingsCardRow(height: 60, first: index == 0,
                                        hit: model.highlighted == SettingsModel.websiteSiteRowID(row),
                                        marker: SettingsModel.rowMarker(SettingsModel.websiteSiteRowID(row))) {
                            Button { model.openSite(origin: row.origin, profile: row.profile) } label: {
                                HStack(spacing: 12) {
                                    SiteLetter(letter: row.letter)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(row.display)
                                        Text(SettingsModel.siteSummary(row, profiles: model.siteProfiles))
                                            .font(.caption).foregroundStyle(.secondary)
                                            .lineLimit(1).truncationMode(.tail)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .accessibilityLabel(row.display + ", " + SettingsModel.siteSummary(row, profiles: model.siteProfiles))
                        }.id(SettingsModel.websiteSiteRowID(row))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// The rows above are the whole section: a defaults row on the left and its menu on the
    /// right, then the grouped card of sites.
}

/// The permission menu a defaults row and a site page row share: the value it holds and the
/// kind's own choices (Ask is not offered for pop-ups or sound, W1).
struct SitePermissionMenu: View {
    @ObservedObject var model: SettingsModel
    let kind: SitePermissionKind
    var origin: String? = nil
    var profile: String? = nil
    let current: SiteState.PermissionSetting?

    var body: some View {
        Menu {
            ForEach(Array(kind.choices.enumerated()), id: \.offset) { _, choice in
                Button(choice.title) {
                    if let origin, let profile {
                        model.setSitePermission(origin: origin, profile: profile, kind: kind, setting: choice)
                    } else if let value = SitePermissionKind.value(for: choice) {
                        model.setSiteDefault(kind, value)
                    }
                }
            }
        } label: {
            Text(current?.title ?? "Unsupported").frame(width: 64, alignment: .center)
        }
        .menuIndicator(.visible)
        .fixedSize()
        .frame(width: 88)
        .accessibilityLabel(kind.title + " permission")
        .accessibilityValue(current?.title ?? "Unsupported")
        .background(SettingsMarker(id: origin == nil
            ? SettingsModel.websiteMenuMarker(kind)
            : SettingsModel.sitePermissionMenuMarker(kind)))
    }
}

/// A site's letter in the board's rounded square, drawn by a row and by the site page's header.
struct SiteLetter: View {
    let letter: String
    var body: some View {
        Text(letter)
            .font(.system(size: 12, weight: .medium))
            .frame(width: 24, height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(SettingsColor.selected))
    }
}

/// A site's page (W3), pushed like a space page: its exceptions with the same menus, Reset
/// permissions and Clear cookies and site data.
struct SettingsSitePage: View {
    @ObservedObject var model: SettingsModel
    let origin: String
    let profile: String

    var body: some View {
        VStack(spacing: SettingsMetrics.cardGap) {
            if let row = model.siteRow(origin: origin, profile: profile) {
                SettingsGroupCard {
                    let kinds = SitePermissionKind.allCases.filter { row.settings[$0] != nil }
                    ForEach(Array(kinds.enumerated()), id: \.offset) { index, kind in
                        SettingsCardRow(height: 60, first: index == 0, marker: SettingsModel.rowMarker(SettingsModel.sitePermissionRowID(kind))) {
                            Image(systemName: kind.iconName).foregroundStyle(.secondary).frame(width: 20)
                            Text(kind.title)
                            Spacer(minLength: 12)
                            SitePermissionMenu(model: model, kind: kind, origin: origin, profile: profile,
                                               current: row.settings[kind])
                        }.id(SettingsModel.sitePermissionRowID(kind))
                    }
                }
            }
            SettingsGroupCard {
                SettingsCardRow(first: true, marker: SettingsModel.rowMarker(SettingsModel.siteResetRowID)) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Reset permissions")
                        Text("Go back to the settings for every site").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Button("Reset") { model.resetSitePermissions(origin: origin, profile: profile) }
                        .background(SettingsMarker(id: SettingsModel.siteResetButtonMarker))
                }.id(SettingsModel.siteResetRowID)
            }
            SettingsGroupCard {
                SettingsCardRow(first: true, marker: SettingsModel.rowMarker(SettingsModel.siteClearRowID)) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Clear cookies and site data")
                        Text("Signs you out of \(SiteOrigin.display(origin))").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Button("Clear…", role: .destructive) { model.clearSiteData(origin: origin, profile: profile) }
                        .background(SettingsMarker(id: SettingsModel.siteClearButtonMarker))
                }.id(SettingsModel.siteClearRowID)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
