import AraratKit
import Foundation

/// The keys the rail's search field acts on: the result list's selection moves with the arrows
/// and Return opens the selected result (D7). The field's key handling and the screen check both
/// call `SettingsModel.handleSearchKey`, so a check exercises the path the window uses.
public enum SettingsSearchKey: Sendable {
    case up, down
    case `return`
}

/// The panes the boards draw, in their draw order. A built pane's raw value names its screen check
/// (`--ararat-screen=settings-tabs`), which is why Air Traffic Control is `air-traffic`.
enum SettingsPaneID: String, CaseIterable {
    case general, appearance, websites, tabs, shortcuts
    case airTraffic = "air-traffic"
    case spaces
    case littleWindow = "little-window"
    case passwords, privacy, extensions, sync, about
}

/// One pane in the settings rail. The registry below is the single list that drives the rail,
/// its order and the search index (D1): a pane is a row there, a page to open, its header copy
/// and the rows the search covers. `page` is nil for a pane the boards draw before its content
/// exists; the rail shows only panes with a page, so no empty pane ever appears, and a later
/// unit makes one built by naming its page and adding its view to the detail switch.
struct SettingsPane: Identifiable {
    let id: SettingsPaneID
    let title: String
    let icon: String
    /// The one line under the header's title. Empty until the pane's unit supplies its copy.
    let subtitle: String
    let page: SettingsModel.Page?
    let rows: @MainActor (SettingsModel) -> [SettingsModel.Row]
    var built: Bool { page != nil }
}

extension SettingsPane {
    @MainActor
    var railMarker: String { SettingsModel.railMarker(id) }
    @MainActor
    var groupMarker: String { SettingsModel.groupMarker(id) }
}

/// The registry: the boards' order, General to About. Panes are built one sub-unit at a time;
/// what is built today reads Tabs, Shortcuts, Air Traffic Control, Spaces, as §7 says.
@MainActor
enum SettingsRegistry {
    static let panes: [SettingsPane] = [
        SettingsPane(id: .general, title: "General", icon: "gearshape", subtitle: "", page: nil, rows: { _ in [] }),
        SettingsPane(id: .appearance, title: "Appearance", icon: "paintpalette", subtitle: "How the window looks.",
                     page: .appearance, rows: appearanceRows),
        SettingsPane(id: .websites, title: "Websites", icon: "globe",
                     subtitle: "What sites may do, and the sites with their own rules.",
                     page: .websites, rows: websitesRows),
        SettingsPane(id: .tabs, title: "Tabs", icon: "square.on.square", subtitle: "Make room for your tabs.",
                     page: .tabs, rows: tabsRows),
        SettingsPane(id: .shortcuts, title: "Shortcuts", icon: "keyboard",
                     subtitle: "Use the keyboard to move around Ararat.", page: .shortcuts, rows: shortcutsRows),
        SettingsPane(id: .airTraffic, title: "Air Traffic Control", icon: "paperplane",
                     subtitle: SettingsModel.airTrafficSubtitle, page: .airTraffic, rows: airTrafficRows),
        SettingsPane(id: .spaces, title: "Spaces", icon: "square.grid.2x2", subtitle: "Keep related tabs together.",
                     page: .spaces, rows: spacesRows),
        SettingsPane(id: .littleWindow, title: "Little Window", icon: "rectangle.inset.filled",
                     subtitle: "A small window for links from other apps.", page: .littleWindow, rows: littleWindowRows),
        SettingsPane(id: .passwords, title: "Passwords", icon: "key", subtitle: "", page: nil, rows: { _ in [] }),
        SettingsPane(id: .privacy, title: "Privacy", icon: "hand.raised", subtitle: "", page: nil, rows: { _ in [] }),
        SettingsPane(id: .extensions, title: "Extensions", icon: "puzzlepiece.extension", subtitle: "", page: nil, rows: { _ in [] }),
        SettingsPane(id: .sync, title: "Sync", icon: "arrow.triangle.2.circlepath", subtitle: "", page: nil, rows: { _ in [] }),
        SettingsPane(id: .about, title: "About", icon: "info.circle", subtitle: "", page: nil, rows: { _ in [] }),
    ]

    private static let byID = Dictionary(uniqueKeysWithValues: panes.map { ($0.id, $0) })

    static var built: [SettingsPane] { panes.filter(\.built) }

    static func pane(_ id: SettingsPaneID) -> SettingsPane? { byID[id] }
    static func pane(id: String) -> SettingsPane? { SettingsPaneID(rawValue: id).flatMap(pane) }
    /// The pane a page belongs to. Every `Page` case maps to a pane in the registry (the space
    /// pages map to Spaces), so this cannot miss.
    static func pane(page: SettingsModel.Page) -> SettingsPane { byID[page.paneID]! }

    /// The search index: every built pane's rows, in the rail's order.
    static func rows(_ model: SettingsModel) -> [SettingsModel.Row] { built.flatMap { $0.rows(model) } }

    static func tabsRows(_ model: SettingsModel) -> [SettingsModel.Row] {
        [SettingsModel.Row(id: "width", pane: .tabs, title: "Sidebar width",
                           subtitle: "Reset the sidebar to its default width of 240 pt."),
         SettingsModel.Row(id: "archive-after", pane: .tabs, title: "Archive Today's tabs after",
                           subtitle: model.archiveSubtitle)]
    }

    /// U27k: the board's rows whose behaviour exists, in its order — the Theme card, the Look
    /// link, then the Sidebar card. Page zoom (an engine API) has no row; a placeholder would be
    /// a dead control.
    static func appearanceRows(_ model: SettingsModel) -> [SettingsModel.Row] {
        [SettingsModel.Row(id: SettingsModel.themeRowId, pane: .appearance, title: "Theme",
                           subtitle: "Pages and settings follow it; a space’s Look can override the sidebar · " + model.theme.label),
         SettingsModel.Row(id: SettingsModel.lookRowId, pane: .appearance, title: "Look",
                           subtitle: "Customize each space in Spaces"),
         SettingsModel.Row(id: SettingsModel.newTabRowId, pane: .appearance, title: "New Tab row",
                           subtitle: "Show “New Tab” under Today"),
         SettingsModel.Row(id: SettingsModel.tooltipsRowId, pane: .appearance, title: "Tooltips",
                           subtitle: "Show a row’s full title on hover")]
    }

    static func shortcutsRows(_ model: SettingsModel) -> [SettingsModel.Row] { model.shortcuts }

    /// U27w: the seven defaults ("For every site"), then each site Chromium lists with its own
    /// settings, so the search reaches both and Return opens the site's page.
    static func websitesRows(_ model: SettingsModel) -> [SettingsModel.Row] {
        var rows = SitePermissionKind.allCases.map { kind in
            SettingsModel.Row(id: SettingsModel.websiteRowID(kind), pane: .websites, title: kind.title,
                              subtitle: "For every site · " + model.siteDefaults.value(for: kind).label)
        }
        rows += model.siteRows.map { row in
            SettingsModel.Row(id: "website-site-\(row.id)", pane: .site(row.origin, row.profile),
                              title: row.display,
                              subtitle: SettingsModel.siteSummary(row, profiles: model.siteProfiles))
        }
        return rows
    }

    static func airTrafficRows(_ model: SettingsModel) -> [SettingsModel.Row] {
        [SettingsModel.Row(id: SettingsModel.airTrafficCardId, pane: .airTraffic, title: "Air Traffic Control",
                           subtitle: SettingsModel.airTrafficSubtitle)]
    }

    /// U27i: the Little Window pane's five rows — the ATC link, the global shortcut and the
    /// three destinations/switches the board groups in one card.
    static func littleWindowRows(_ model: SettingsModel) -> [SettingsModel.Row] {
        [SettingsModel.Row(id: SettingsModel.littleWindowLinkRowId, pane: .littleWindow,
                           title: "Which links open in a Little Window",
                           subtitle: "Set in Air Traffic Control: its default destination and routes"),
         SettingsModel.Row(id: SettingsModel.littleWindowShortcutRowId, pane: .littleWindow,
                           title: "Open a Little Window from any app",
                           subtitle: "A shortcut that works while Ararat is in the background"),
         SettingsModel.Row(id: SettingsModel.littleWindowOpenInRowId, pane: .littleWindow,
                           title: "“Open in” button sends the page to",
                           subtitle: "Most Recent Space, or one space by name · " + model.littleWindowOpenInLabel),
         SettingsModel.Row(id: SettingsModel.littleWindowCloseAfterRowId, pane: .littleWindow,
                           title: "Close the Little Window after opening in a space",
                           subtitle: ""),
         SettingsModel.Row(id: SettingsModel.littleWindowRememberRowId, pane: .littleWindow,
                           title: "Remember its size and place",
                           subtitle: "")]
    }

    /// The Spaces pane's own rows, then each space's page rows: the rail groups all of them
    /// under Spaces, and a page row's title reads "row — space" in the results.
    static func spacesRows(_ model: SettingsModel) -> [SettingsModel.Row] {
        var rows: [SettingsModel.Row] = [
            SettingsModel.Row(id: SettingsModel.spaceScrollDirectionCardId, pane: .spaces,
                              title: "Scroll sideways to switch spaces",
                              subtitle: "Natural or Reversed · " + model.spaceScrollDirectionLabel),
        ]
        for space in model.snapshot.spaces {
            rows.append(SettingsModel.Row(id: space.id, pane: .spaces, title: space.title,
                                          subtitle: "\(model.tabCountLabel(space)) · \(space.profileName)"))
            rows += [
                SettingsModel.Row(id: "name", pane: .space(space.id), title: "Name",
                                  subtitle: "\(space.title) · This space"),
                SettingsModel.Row(id: "icon", pane: .space(space.id), title: "Icon",
                                  subtitle: "Choose one character · \(space.title) · This space"),
                SettingsModel.Row(id: "look", pane: .space(space.id), title: "Look",
                                  subtitle: "Colour and texture · \(space.title) · This space"),
                SettingsModel.Row(id: "profile", pane: .space(space.id), title: "Profile",
                                  subtitle: "Read-only · \(space.title) · This space · \(space.profileName)"),
                SettingsModel.Row(id: "delete", pane: .space(space.id), title: "Delete Space",
                                  subtitle: "\(space.title) · " + (model.snapshot.spaces.count == 1
                                      ? "The last space cannot be deleted."
                                      : "Move pinned and Today tabs to the Archive.")),
            ]
        }
        return rows
    }
}

extension SettingsModel.Page {
    var paneID: SettingsPaneID {
        switch self {
        case .websites, .site: .websites
        case .tabs: .tabs
        case .shortcuts: .shortcuts
        case .airTraffic: .airTraffic
        case .appearance: .appearance
        case .littleWindow: .littleWindow
        case .spaces, .space: .spaces
        }
    }

    /// Tells two panes' rows with the same id apart (every space page has a "name" row).
    var searchKey: String {
        if case .space(let id) = self { return "space-" + id }
        if case .site(let origin, let profile) = self { return "site-" + origin + "|" + profile }
        return paneID.rawValue
    }
}
