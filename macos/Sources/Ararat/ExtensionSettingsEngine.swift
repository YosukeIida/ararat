import AppKit
import AraratKit

/// U27x: the engine side of Settings › Extensions. The entry points live in AraratHostAPI.h (a
/// pane acts on a profile, not on one window's Browser), so the app resolves them from the loaded
/// framework the way the history, measure and site-settings calls are resolved. The model takes
/// this object as its `ExtensionSettingsHost`; the model tests take a fake. Every NSString
/// parameter is declared as NSString in the C signature so Swift keeps it alive across the call.
@MainActor
final class EngineExtensionSettingsHost: ExtensionSettingsHost {
    static let shared = EngineExtensionSettingsHost()

    private typealias List = @convention(c) (NSString) -> NSArray
    private typealias SetEnabled = @convention(c) (NSString, NSString, ObjCBool) -> Unmanaged<NSString>?
    private typealias SetSiteAccess = @convention(c) (NSString, NSString, NSString) -> Unmanaged<NSString>?
    private typealias SetPinned = @convention(c) (NSString, NSString, ObjCBool) -> Unmanaged<NSString>?
    private typealias Review = @convention(c) (NSString, NSString, NSWindow?,
                                              @escaping @convention(block) (ObjCBool) -> Void) -> Void
    private typealias Remove = @convention(c) (NSString, NSString) -> Unmanaged<NSString>?
    private typealias SetChangeHandler = @convention(c) (@escaping @convention(block) () -> Void) -> Void
    private typealias CheckLoad = @convention(c) (NSString, NSString,
                                                  @escaping @convention(block) (NSString) -> Void) -> Void
    private typealias CheckDisableForReview = @convention(c) (NSString, NSString) -> Void
    private typealias CheckDialog = @convention(c) (NSWindow?, NSString) -> Unmanaged<NSString>?

    private lazy var list: List? = Self.symbol("AraratExtensions")
    private lazy var setEnabledSymbol: SetEnabled? = Self.symbol("AraratSetExtensionEnabled")
    private lazy var setSiteAccessSymbol: SetSiteAccess? = Self.symbol("AraratSetExtensionSiteAccess")
    private lazy var setPinnedSymbol: SetPinned? = Self.symbol("AraratSetExtensionPinned")
    private lazy var reviewSymbol: Review? = Self.symbol("AraratReviewExtension")
    private lazy var removeSymbol: Remove? = Self.symbol("AraratRemoveExtension")
    private lazy var changeHandlerSymbol: SetChangeHandler? = Self.symbol("AraratSetExtensionsChangedHandler")
    private lazy var checkLoadSymbol: CheckLoad? = Self.symbol("AraratCheckLoadUnpackedExtension")
    private lazy var checkDisableForReviewSymbol: CheckDisableForReview? = Self.symbol("AraratCheckDisableExtensionForReview")
    private lazy var checkDialogSymbol: CheckDialog? = Self.symbol("AraratCheckExtensionDialog")

    private var changeHandler: (() -> Void)?

    private static func symbol<T>(_ name: String) -> T? {
        guard let symbol = dlsym(Launcher.handle, name) else {
            FileHandle.standardError.write(Data("ararat-trace: missing extensions API \(name)\n".utf8))
            return nil
        }
        return unsafeBitCast(symbol, to: T.self)
    }

    private static func text(_ value: Unmanaged<NSString>?) -> String {
        value?.takeUnretainedValue() as String? ?? ""
    }

    func extensions(profile: String) -> ExtensionProfileList {
        guard let list else { return .empty }
        guard let entries = list(profile as NSString) as? [[String: Any]] else { return .empty }
        // X1: one sentinel entry while an existing profile is loaded on demand.
        if entries.count == 1, entries[0]["loading"] as? Bool == true { return .loading }
        let rows = entries.compactMap { entry -> SettingsExtension? in
            guard let id = entry["id"] as? String, !id.isEmpty,
                  let name = entry["name"] as? String else { return nil }
            let access = ExtensionSiteAccess(rawValue: entry["siteAccess"] as? String ?? "") ?? .onAllSites
            return SettingsExtension(
                id: id, name: name,
                icon: entry["icon"] as? NSImage,
                enabled: entry["enabled"] as? Bool ?? false,
                needsReview: entry["needsReview"] as? Bool ?? false,
                siteAccess: access,
                pinned: entry["pinned"] as? Bool ?? false,
                canPin: entry["canPin"] as? Bool ?? false,
                canDisable: entry["canDisable"] as? Bool ?? true,
                removable: entry["removable"] as? Bool ?? false)
        }
        return ExtensionProfileList(loading: false, rows: rows)
    }

    func setEnabled(profile: String, identifier: String, enabled: Bool) -> String {
        guard let setEnabledSymbol else { return "unknown" }
        return Self.text(setEnabledSymbol(profile as NSString, identifier as NSString, ObjCBool(enabled)))
    }

    func setSiteAccess(profile: String, identifier: String, access: ExtensionSiteAccess) -> String {
        guard let setSiteAccessSymbol, access == .onAllSites || access == .onClick else { return "unsupported" }
        return Self.text(setSiteAccessSymbol(profile as NSString, identifier as NSString, access.rawValue as NSString))
    }

    func setPinned(profile: String, identifier: String, pinned: Bool) -> String {
        guard let setPinnedSymbol else { return "unknown" }
        return Self.text(setPinnedSymbol(profile as NSString, identifier as NSString, ObjCBool(pinned)))
    }

    func review(profile: String, identifier: String, window: NSWindow?,
                completion: @escaping (Bool) -> Void) {
        guard let reviewSymbol else { completion(false); return }
        reviewSymbol(profile as NSString, identifier as NSString, window) { allowed in
            MainActor.assumeIsolated { completion(allowed.boolValue) }
        }
    }

    func uninstall(profile: String, identifier: String) -> String {
        guard let removeSymbol else { return "unknown" }
        return Self.text(removeSymbol(profile as NSString, identifier as NSString))
    }

    func setChangeHandler(_ handler: (() -> Void)?) {
        changeHandler = handler
        guard let changeHandlerSymbol else { return }
        if let handler {
            changeHandlerSymbol { MainActor.assumeIsolated { handler() } }
        } else {
            changeHandlerSymbol {}
        }
    }

    /// Check-only: installs an unpacked fixture into one profile (X2's two-profile check).
    func checkLoadUnpacked(profile: String, path: String, completion: @escaping (String) -> Void) {
        guard let checkLoadSymbol else { completion("unavailable"); return }
        checkLoadSymbol(profile as NSString, path as NSString) { result in
            MainActor.assumeIsolated { completion(result as String) }
        }
    }

    /// Check-only: the state Chromium sets when an update asks for more permissions.
    func checkDisableForReview(profile: String, identifier: String) {
        checkDisableForReviewSymbol?(profile as NSString, identifier as NSString)
    }

    /// Check-only: accepts or cancels the Views dialog a Settings action opened, and returns its
    /// class name ("" when no dialog is up). It replaces the accessibility press: the VM's
    /// in-process accessibility tree is empty.
    @discardableResult
    func checkExtensionDialog(parent: NSWindow?, action: String) -> String {
        guard let checkDialogSymbol else { return "" }
        return Self.text(checkDialogSymbol(parent, action as NSString))
    }
}
