import AppKit
import AraratKit

/// U27x: the engine side of Settings › Extensions. The entry points live in AraratHostAPI.h (a
/// pane acts on a profile, not on one window's Browser), so the app resolves them from the loaded
/// framework the way the history, measure and site-settings calls are resolved. The model takes
/// this object as its `ExtensionSettingsHost`; the model tests take a fake.
@MainActor
final class EngineExtensionSettingsHost: ExtensionSettingsHost {
    static let shared = EngineExtensionSettingsHost()

    private typealias List = @convention(c) (UnsafeRawPointer) -> NSArray
    private typealias SetEnabled = @convention(c) (UnsafeRawPointer, UnsafeRawPointer, ObjCBool) -> Unmanaged<NSString>?
    private typealias SetSiteAccess = @convention(c) (UnsafeRawPointer, UnsafeRawPointer, UnsafeRawPointer) -> Unmanaged<NSString>?
    private typealias SetPinned = @convention(c) (UnsafeRawPointer, UnsafeRawPointer, ObjCBool) -> Unmanaged<NSString>?
    private typealias Review = @convention(c) (UnsafeRawPointer, UnsafeRawPointer, UnsafeRawPointer?,
                                              @escaping @convention(block) (ObjCBool) -> Void) -> Void
    private typealias Remove = @convention(c) (UnsafeRawPointer, UnsafeRawPointer, UnsafeRawPointer?,
                                               @escaping @convention(block) (NSString, NSString) -> Void) -> Void
    private typealias SetChangeHandler = @convention(c) (@escaping @convention(block) () -> Void) -> Void
    private typealias CheckLoad = @convention(c) (UnsafeRawPointer, UnsafeRawPointer,
                                                  @escaping @convention(block) (NSString) -> Void) -> Void
    private typealias CheckDisableForReview = @convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> Void

    private lazy var list: List? = Self.symbol("AraratExtensions")
    private lazy var setEnabledSymbol: SetEnabled? = Self.symbol("AraratSetExtensionEnabled")
    private lazy var setSiteAccessSymbol: SetSiteAccess? = Self.symbol("AraratSetExtensionSiteAccess")
    private lazy var setPinnedSymbol: SetPinned? = Self.symbol("AraratSetExtensionPinned")
    private lazy var reviewSymbol: Review? = Self.symbol("AraratReviewExtension")
    private lazy var removeSymbol: Remove? = Self.symbol("AraratRemoveExtension")
    private lazy var changeHandlerSymbol: SetChangeHandler? = Self.symbol("AraratSetExtensionsChangedHandler")
    private lazy var checkLoadSymbol: CheckLoad? = Self.symbol("AraratCheckLoadUnpackedExtension")
    private lazy var checkDisableForReviewSymbol: CheckDisableForReview? = Self.symbol("AraratCheckDisableExtensionForReview")

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

    private static func opaque(_ value: NSString) -> UnsafeRawPointer {
        UnsafeRawPointer(Unmanaged.passUnretained(value).toOpaque())
    }

    func extensions(profile: String) -> [SettingsExtension] {
        guard let list else { return [] }
        guard let entries = list(Self.opaque(profile as NSString)) as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
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
                removable: entry["removable"] as? Bool ?? false,
                unpacked: entry["unpacked"] as? Bool ?? false)
        }
    }

    func setEnabled(profile: String, identifier: String, enabled: Bool) -> String {
        guard let setEnabledSymbol else { return "unknown" }
        return Self.text(setEnabledSymbol(Self.opaque(profile as NSString), Self.opaque(identifier as NSString),
                                          ObjCBool(enabled)))
    }

    func setSiteAccess(profile: String, identifier: String, access: ExtensionSiteAccess) -> String {
        guard let setSiteAccessSymbol, access != .onSpecificSites else { return "unsupported" }
        return Self.text(setSiteAccessSymbol(Self.opaque(profile as NSString),
                                             Self.opaque(identifier as NSString),
                                             Self.opaque(access.rawValue as NSString)))
    }

    func setPinned(profile: String, identifier: String, pinned: Bool) -> String {
        guard let setPinnedSymbol else { return "unknown" }
        return Self.text(setPinnedSymbol(Self.opaque(profile as NSString), Self.opaque(identifier as NSString),
                                         ObjCBool(pinned)))
    }

    func review(profile: String, identifier: String, window: NSWindow?,
                completion: @escaping (Bool) -> Void) {
        guard let reviewSymbol else { completion(false); return }
        reviewSymbol(Self.opaque(profile as NSString), Self.opaque(identifier as NSString),
                     window.map { Unmanaged.passUnretained($0).toOpaque() }) { allowed in
            MainActor.assumeIsolated { completion(allowed.boolValue) }
        }
    }

    func remove(profile: String, identifier: String, window: NSWindow?,
                completion: @escaping (String, String) -> Void) {
        guard let removeSymbol else { completion("unknown", ""); return }
        removeSymbol(Self.opaque(profile as NSString), Self.opaque(identifier as NSString),
                     window.map { Unmanaged.passUnretained($0).toOpaque() }) { result, detail in
            MainActor.assumeIsolated { completion(result as String, detail as String) }
        }
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
        checkLoadSymbol(Self.opaque(profile as NSString), Self.opaque(path as NSString)) { result in
            MainActor.assumeIsolated { completion(result as String) }
        }
    }

    /// Check-only: the state Chromium sets when an update asks for more permissions.
    func checkDisableForReview(profile: String, identifier: String) {
        checkDisableForReviewSymbol?(Self.opaque(profile as NSString), Self.opaque(identifier as NSString))
    }
}
