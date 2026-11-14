import AppKit
import AraratKit

/// U27w: the engine side of Settings › Websites. The four C entry points live in
/// AraratHostAPI.h (a pane acts on every profile, not on one window's Browser), so the app
/// resolves them from the loaded framework the way the history and measure calls are resolved.
/// The model takes this object as its `SiteSettingsHost`; the model tests take a fake.
@MainActor
final class EngineSiteSettingsHost: SiteSettingsHost {
    static let shared = EngineSiteSettingsHost()

    private typealias ApplyDefaults = @convention(c) (UnsafeRawPointer) -> Void
    private typealias Exceptions = @convention(c) () -> NSArray
    private typealias SetException = @convention(c) (UnsafeRawPointer, UnsafeRawPointer, UnsafeRawPointer, UnsafeRawPointer?) -> Bool
    private typealias ClearSiteData = @convention(c) (UnsafeRawPointer, UnsafeRawPointer, @escaping @convention(block) (UInt64) -> Void) -> Void

    private lazy var applyDefaults: ApplyDefaults? = Self.symbol("AraratApplySiteDefaults")
    private lazy var listExceptions: Exceptions? = Self.symbol("AraratSiteExceptions")
    private lazy var setException: SetException? = Self.symbol("AraratSetSiteException")
    private lazy var clearData: ClearSiteData? = Self.symbol("AraratClearSiteData")

    private static func symbol<T>(_ name: String) -> T? {
        guard let symbol = dlsym(Launcher.handle, name) else {
            FileHandle.standardError.write(Data("ararat-trace: missing site settings API \(name)\n".utf8))
            return nil
        }
        return unsafeBitCast(symbol, to: T.self)
    }

    /// W1: the app applies the core record at every window start and after every write, so a
    /// profile loaded later and one already loaded both hold the record. The engine also
    /// remembers it for a profile it creates later.
    static func apply(_ defaults: SiteDefaults) {
        shared.applyRequest(defaults.engineRequest as NSDictionary)
    }

    private func applyRequest(_ request: NSDictionary) {
        guard let applyDefaults else { return }
        applyDefaults(Unmanaged.passUnretained(request).toOpaque())
    }

    func siteExceptions() -> [SiteException] {
        guard let list = listExceptions?() as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let profile = entry["profile"] as? String, !profile.isEmpty,
                  let origin = entry["origin"] as? String, !origin.isEmpty,
                  let kindName = entry["kind"] as? String,
                  let kind = SitePermissionKind(rawValue: kindName),
                  let setting = SiteState.PermissionSetting(dictionary: entry["value"]) else { return nil }
            return SiteException(profile: profile, origin: origin, kind: kind, setting: setting)
        }
    }

    func setSiteException(profile: String, origin: String, kind: String,
                          setting: SiteState.PermissionSetting?) -> Bool {
        guard let setException else { return false }
        let profileObject = profile as NSString
        let originObject = origin as NSString
        let kindObject = kind as NSString
        let request = setting.map { $0.request as NSDictionary }
        return setException(Unmanaged.passUnretained(profileObject).toOpaque(),
                            Unmanaged.passUnretained(originObject).toOpaque(),
                            Unmanaged.passUnretained(kindObject).toOpaque(),
                            request.map { Unmanaged.passUnretained($0).toOpaque() } ?? nil)
    }

    func clearSiteData(profile: String, origin: String, completion: @escaping (UInt64) -> Void) {
        guard let clearData else { completion(0); return }
        let profileObject = profile as NSString
        let originObject = origin as NSString
        clearData(Unmanaged.passUnretained(profileObject).toOpaque(),
                  Unmanaged.passUnretained(originObject).toOpaque()) { failed in
            MainActor.assumeIsolated { completion(failed) }
        }
    }
}
