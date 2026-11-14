import Foundation

/// U27p: the words the Privacy pane and its check use for the core's values.
extension ThirdPartyCookies {
    public var label: String {
        switch self {
        case .block: "Block"
        case .allow: "Allow"
        }
    }

    /// The engine's word for the request dictionary.
    public var engineName: String {
        switch self {
        case .block: "block"
        case .allow: "allow"
        }
    }
}

extension HistoryRetention {
    public var label: String {
        switch self {
        case .week: "One week"
        case .month: "One month"
        case .threeMonths: "Three months"
        case .year: "One year"
        case .forever: "Forever"
        }
    }

    /// The days the engine's expiry thresholds to; nil means every visit stays.
    public var days: Int? {
        switch self {
        case .week: 7
        case .month: 30
        case .threeMonths: 90
        case .year: 365
        case .forever: nil
        }
    }
}

extension PrivacySettings {
    /// The board's built-in record: Block third-party cookies, GPC on, One year of history.
    public static var board: PrivacySettings {
        PrivacySettings(thirdPartyCookies: .block, globalPrivacyControl: true, historyRetention: .year)
    }

    /// The engine's request dictionary: the cookie mode's word, the GPC switch and the retention
    /// in days (0 for Forever, the engine's "never expire").
    public var engineRequest: [String: Any] {
        ["cookies": thirdPartyCookies.engineName,
         "gpc": globalPrivacyControl,
         "history_days": historyRetention.days ?? 0]
    }
}

/// U27p P4: the sheet's time range, the board's five choices. `allTime` has no start.
public enum ClearBrowsingRange: String, CaseIterable, Sendable {
    case lastHour, last24Hours, last7Days, last4Weeks, allTime

    public var title: String {
        switch self {
        case .lastHour: "Last hour"
        case .last24Hours: "Last 24 hours"
        case .last7Days: "Last 7 days"
        case .last4Weeks: "Last 4 weeks"
        case .allTime: "All time"
        }
    }

    /// The start of the range; nil is the beginning of time.
    public func start(now: Date) -> Date? {
        switch self {
        case .lastHour: now.addingTimeInterval(-3600)
        case .last24Hours: now.addingTimeInterval(-86400)
        case .last7Days: now.addingTimeInterval(-7 * 86400)
        case .last4Weeks: now.addingTimeInterval(-28 * 86400)
        case .allTime: nil
        }
    }
}

/// U27p P4: the three types the sheet clears. The raw value is the engine's bit, so the app sends
/// the record's choice unchanged.
public struct ClearBrowsingTypes: OptionSet, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let history = ClearBrowsingTypes(rawValue: 1)
    public static let cookies = ClearBrowsingTypes(rawValue: 2)
    public static let cache = ClearBrowsingTypes(rawValue: 4)

    /// The sheet's defaults and its order: History, Cookies and other site data, Cached images and
    /// files, all three on as Chromium's own dialog opens.
    public static let all: ClearBrowsingTypes = [.history, .cookies, .cache]
    public static let ordered: [(ClearBrowsingTypes, String)] = [
        (.history, "History"),
        (.cookies, "Cookies and other site data"),
        (.cache, "Cached images and files"),
    ]
}

/// The engine calls the Privacy pane makes, behind a protocol so the model tests drive a fake host
/// and the app supplies the AraratHostAPI implementation. All calls are main-thread.
@MainActor
public protocol PrivacySettingsHost: AnyObject {
    /// Applies the whole record to every regular profile now and to a profile created later: the
    /// cookie-controls pref, the GPC pref and the history retention.
    func applyPrivacy(_ settings: PrivacySettings)
    /// Clears the chosen types for the range in one profile; the reply is the failed data types
    /// bitmask, not a count, and is always called.
    func clearBrowsingData(profile: String, range: ClearBrowsingRange, types: ClearBrowsingTypes,
                           completion: @escaping (UInt64) -> Void)
}
