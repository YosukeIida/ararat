import AppKit
import Foundation

/// U27x: the four states Settings › Extensions summarises in a row (X2). The raw values are the
/// engine's words; "On specific sites" is Chromium's state when sites were granted one by one and
/// is not one the pane writes, because choosing sites stays Chromium's own page.
public enum ExtensionSiteAccess: String, CaseIterable, Sendable {
    case onAllSites = "all"
    case onSpecificSites = "specific"
    case onClick = "click"

    public var title: String {
        switch self {
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
/// (Review… replaces the switch), the user site access, and the toolbar action's pin state.
public struct SettingsExtension: Identifiable {
    public var id: String
    public var name: String
    public var icon: NSImage?
    public var enabled: Bool
    public var needsReview: Bool
    public var siteAccess: ExtensionSiteAccess
    public var pinned: Bool
    public var canPin: Bool
    public var removable: Bool
    public var unpacked: Bool

    public init(id: String, name: String, icon: NSImage? = nil, enabled: Bool = true,
                needsReview: Bool = false, siteAccess: ExtensionSiteAccess = .onAllSites,
                pinned: Bool = false, canPin: Bool = false, removable: Bool = true,
                unpacked: Bool = false) {
        self.id = id
        self.name = name
        self.icon = icon
        self.enabled = enabled
        self.needsReview = needsReview
        self.siteAccess = siteAccess
        self.pinned = pinned
        self.canPin = canPin
        self.removable = removable
        self.unpacked = unpacked
    }

    /// The row's second line, in the board's words: the permissions state goes first ("Needs new
    /// permissions"), a disabled extension reads "Off", otherwise the site access does.
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

/// The engine calls the pane makes, behind a protocol so the Swift model tests drive a fake host
/// and the app supplies the AraratHostAPI implementation (X2, X3, X5). All calls are main-thread,
/// like the rest of the host API. The reply words are the engine's named results.
@MainActor
public protocol ExtensionSettingsHost: AnyObject {
    /// One profile's installed extensions, in the engine's order.
    func extensions(profile: String) -> [SettingsExtension]
    /// "done", "unchanged", "review" (only the prompt may enable it), "policy" or "unknown".
    func setEnabled(profile: String, identifier: String, enabled: Bool) -> String
    /// "done", "unsupported" or "unknown".
    func setSiteAccess(profile: String, identifier: String, access: ExtensionSiteAccess) -> String
    /// "done", "unchanged", "forced", "unknown" or "incognito".
    func setPinned(profile: String, identifier: String, pinned: Bool) -> String
    /// Chromium's re-enable prompt; `allowed` is whether it was accepted.
    func review(profile: String, identifier: String, window: NSWindow?,
                completion: @escaping (Bool) -> Void)
    /// Chromium's uninstall dialog; the reply is "removed", "notRemoved", "forced" or "unknown".
    func remove(profile: String, identifier: String, window: NSWindow?,
                completion: @escaping (String, String) -> Void)
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
