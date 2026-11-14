import AppKit
import Foundation

/// U27x: the states Settings › Extensions summarises in a row (X2). The raw values are the
/// engine's words; "On specific sites" is Chromium's state when sites were granted one by one and
/// is not one the pane writes (choosing sites stays Chromium's own page), and "none" is an
/// extension that requests no site access at all, whose rows offer no site-access menu.
public enum ExtensionSiteAccess: String, CaseIterable, Sendable {
    case noSiteAccess = "none"
    case onAllSites = "all"
    case onSpecificSites = "specific"
    case onClick = "click"

    public var title: String {
        switch self {
        case .noSiteAccess: ""
        case .onAllSites: "On all sites"
        case .onSpecificSites: "On specific sites"
        case .onClick: "On click"
        }
    }

    /// The choices the … menu writes. A site-by-site choice needs Chromium's site picker, which
    /// the pane opens through Manage Extension instead (X2).
    public static let writable: [ExtensionSiteAccess] = [.onAllSites, .onClick]
}

/// One installed extension as the engine lists it (X2): the id, the name, the icon (nil draws the
/// board's letter), whether it is enabled, whether Chromium disabled it for a permissions increase
/// (Review… replaces the switch), the user site access, the toolbar action's pin state, and whether
/// Chromium offers the enable switch and Remove… at all.
public struct SettingsExtension: Identifiable {
    public var id: String
    public var name: String
    public var icon: NSImage?
    public var enabled: Bool
    public var needsReview: Bool
    public var siteAccess: ExtensionSiteAccess
    public var pinned: Bool
    public var canPin: Bool
    public var canDisable: Bool
    public var removable: Bool

    public init(id: String, name: String, icon: NSImage? = nil, enabled: Bool = true,
                needsReview: Bool = false, siteAccess: ExtensionSiteAccess = .onAllSites,
                pinned: Bool = false, canPin: Bool = false, canDisable: Bool = true,
                removable: Bool = true) {
        self.id = id
        self.name = name
        self.icon = icon
        self.enabled = enabled
        self.needsReview = needsReview
        self.siteAccess = siteAccess
        self.pinned = pinned
        self.canPin = canPin
        self.canDisable = canDisable
        self.removable = removable
    }

    /// The row's second line, in the board's words: the permissions state goes first ("Needs new
    /// permissions"), a disabled extension reads "Off", otherwise the site access does (an
    /// extension with no site access has no second line).
    public var summary: String {
        if needsReview { return "Needs new permissions" }
        if !enabled { return "Off" }
        return siteAccess.title
    }

    /// The letter the row draws when the extension ships no icon.
    public var letter: String {
        name.first.map { String($0).uppercased() } ?? "?"
    }
}

/// One profile's list as the engine answered: the rows, or `loading` while a profile that exists
/// but is not loaded yet is being loaded (X1). The model keeps its rows across a loading answer.
public struct ExtensionProfileList {
    public var loading: Bool
    public var rows: [SettingsExtension]

    public init(loading: Bool, rows: [SettingsExtension]) {
        self.loading = loading
        self.rows = rows
    }

    public static let empty = ExtensionProfileList(loading: false, rows: [])
    public static let loading = ExtensionProfileList(loading: true, rows: [])
}

/// The engine calls the pane makes, behind a protocol so the Swift model tests drive a fake host
/// and the app supplies the AraratHostAPI implementation (X1–X3, X5). All calls are main-thread,
/// like the rest of the host API. The reply words are the engine's named results.
@MainActor
public protocol ExtensionSettingsHost: AnyObject {
    /// One profile's installed extensions, in the engine's order, or a loading answer.
    func extensions(profile: String) -> ExtensionProfileList
    /// "done", "unchanged", "review" (only the prompt may enable it), "policy" or "unknown".
    func setEnabled(profile: String, identifier: String, enabled: Bool) -> String
    /// "done", "unsupported" or "unknown".
    func setSiteAccess(profile: String, identifier: String, access: ExtensionSiteAccess) -> String
    /// "done", "unchanged", "forced", "unknown" or "incognito".
    func setPinned(profile: String, identifier: String, pinned: Bool) -> String
    /// Chromium's re-enable prompt; `allowed` is whether it was accepted.
    func review(profile: String, identifier: String, window: NSWindow?,
                completion: @escaping (Bool) -> Void)
    /// The engine uninstalls through the registrar; "" on success, or "unknown", "forced" or an
    /// error text. The pane asks in its own AppKit sheet before calling it.
    func uninstall(profile: String, identifier: String) -> String
    /// X5: the registry observer's callback, called when an extension is installed, removed,
    /// enabled or disabled in any profile.
    func setChangeHandler(_ handler: (() -> Void)?)
}

/// The entry a row's … menu draws, in the board's order (E-Extensions): the site-access choice,
/// the pin, then Manage Extension and Remove…. The model builds these so the pane and its tests
/// agree about what a row can do.
public enum ExtensionMenuEntry: Equatable, Sendable {
    case siteAccess(ExtensionSiteAccess)
    case pin
    case unpin
    case manage
    case remove
    case separator

    public var title: String {
        switch self {
        case .siteAccess(let access): access.title
        case .pin: "Pin to Sidebar"
        case .unpin: "Unpin from Sidebar"
        case .manage: "Manage Extension"
        case .remove: "Remove…"
        case .separator: ""
        }
    }
}
