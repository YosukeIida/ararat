import AppKit
import AraratKit

/// U27p: the engine side of Settings › Privacy. The four C entry points live in AraratHostAPI.h
/// (a pane acts on every profile, not on one window's Browser), so the app resolves them from the
/// loaded framework the way the sites and extensions calls are resolved. The model takes this
/// object as its `PrivacySettingsHost`; the model tests take a fake.
@MainActor
final class EnginePrivacySettingsHost: PrivacySettingsHost {
    static let shared = EnginePrivacySettingsHost()

    private typealias Apply = @convention(c) (UnsafeRawPointer) -> Void
    private typealias Clear = @convention(c) (UnsafeRawPointer, Double, UInt64,
                                              @escaping @convention(block) (UInt64) -> Void) -> Void

    private lazy var applySettings: Apply? = Self.symbol("AraratApplyPrivacySettings")
    private lazy var clearData: Clear? = Self.symbol("AraratClearBrowsingData")

    private static func symbol<T>(_ name: String) -> T? {
        guard let symbol = dlsym(Launcher.handle, name) else {
            FileHandle.standardError.write(Data("ararat-trace: missing privacy settings API \(name)\n".utf8))
            return nil
        }
        return unsafeBitCast(symbol, to: T.self)
    }

    /// P2/P3: the app applies the core record at every window start and after every write, so a
    /// profile loaded later and one already loaded both hold the record. The engine also remembers
    /// it for a profile it creates later.
    static func apply(_ settings: PrivacySettings) {
        shared.applyRecord(settings)
    }

    private func applyRecord(_ settings: PrivacySettings) {
        guard let applySettings else { return }
        let request = settings.engineRequest as NSDictionary
        applySettings(Unmanaged.passUnretained(request).toOpaque())
    }

    func applyPrivacy(_ settings: PrivacySettings) { applyRecord(settings) }

    /// P4: the range's start is seconds since 1970; 0 means the beginning of time, and the engine
    /// ends at Chromium's Time::Max() as Chrome's own dialog does. The engine clears the three
    /// types through BrowsingDataRemover and answers the failed types bitmask; a missing symbol
    /// answers every requested type as failed, so the pane does not read 0 as success.
    func clearBrowsingData(profile: String, range: ClearBrowsingRange, types: ClearBrowsingTypes,
                           completion: @escaping (UInt64) -> Void) {
        guard let clearData else { completion(types.rawValue); return }
        let begin = range.start(now: Date())?.timeIntervalSince1970 ?? 0
        let profileObject = profile as NSString
        clearData(Unmanaged.passUnretained(profileObject).toOpaque(), begin, types.rawValue) { failed in
            MainActor.assumeIsolated { completion(failed) }
        }
    }
}

/// The Privacy screen check's history fixtures: a visit at a chosen age and the visit times a URL
/// holds today. The two entries are check-gated engine calls like `AraratCheckDeleteHistory`, used
/// only by `--ararat-screen=settings-privacy`.
@MainActor
enum PrivacyCheckEngine {
    private typealias Seed = @convention(c) (UnsafeRawPointer, UnsafeRawPointer, Double,
                                             @escaping @convention(block) (Bool) -> Void) -> Void
    private typealias Times = @convention(c) (UnsafeRawPointer, UnsafeRawPointer,
                                              @escaping @convention(block) (NSArray) -> Void) -> Void

    private static func symbol<T>(_ name: String) -> T? {
        guard let symbol = dlsym(Launcher.handle, name) else {
            FileHandle.standardError.write(Data("ararat-trace: missing privacy check API \(name)\n".utf8))
            return nil
        }
        return unsafeBitCast(symbol, to: T.self)
    }

    /// Adds one visit at `daysAgo` (0.02 for a visit twenty minutes old).
    static func seedVisit(profile: String, url: String, daysAgo: Double,
                          completion: @escaping (Bool) -> Void) {
        guard let seed: Seed = symbol("AraratCheckSeedHistoryVisit") else { completion(false); return }
        let profileObject = profile as NSString
        let urlObject = url as NSString
        seed(Unmanaged.passUnretained(profileObject).toOpaque(),
             Unmanaged.passUnretained(urlObject).toOpaque(), daysAgo) { ok in
            MainActor.assumeIsolated { completion(ok) }
        }
    }

    /// The URL's visit times, seconds since 1970, oldest first.
    static func visitTimes(profile: String, url: String,
                           completion: @escaping ([Double]) -> Void) {
        guard let times: Times = symbol("AraratCheckHistoryVisitTimes") else { completion([]); return }
        let profileObject = profile as NSString
        let urlObject = url as NSString
        times(Unmanaged.passUnretained(profileObject).toOpaque(),
              Unmanaged.passUnretained(urlObject).toOpaque()) { list in
            let values = (list as? [NSNumber])?.map(\.doubleValue) ?? []
            MainActor.assumeIsolated { completion(values) }
        }
    }
}
