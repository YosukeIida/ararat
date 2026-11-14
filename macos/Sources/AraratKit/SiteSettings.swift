import Foundation

/// U27w: the seven permissions Settings › Websites lists, in the board's order. The raw value
/// is Chromium's website-settings name, which is the name the engine's site snapshot already
/// uses for a row (`SiteState.name(for:)`), so one vocabulary reaches both surfaces.
public enum SitePermissionKind: String, CaseIterable, Sendable {
    case camera = "media-stream-camera"
    case microphone = "media-stream-mic"
    case location = "geolocation"
    case notifications = "notifications"
    case popups = "popups"
    case automaticDownloads = "automatic-downloads"
    case sound = "sound"

    public var title: String {
        switch self {
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .location: "Location"
        case .notifications: "Notifications"
        case .popups: "Pop-up windows"
        case .automaticDownloads: "Automatic downloads"
        case .sound: "Sound"
        }
    }

    /// The board's icons (E-Websites draws a camera, a microphone, a pin, a bell, two windows,
    /// a download arrow and a speaker).
    public var iconName: String {
        switch self {
        case .camera: "video"
        case .microphone: "mic"
        case .location: "location"
        case .notifications: "bell"
        case .popups: "macwindow.on.rectangle"
        case .automaticDownloads: "arrow.down.doc"
        case .sound: "speaker.wave.2"
        }
    }

    /// The values the row's menu offers. Chromium's registry lists only Allow and Block for
    /// pop-ups and sound, so Ask is not offered for those two (W1).
    public var choices: [SiteState.PermissionSetting] {
        switch self {
        case .popups, .sound: return [.content("allow"), .content("block")]
        default: return [.content("ask"), .content("allow"), .content("block")]
        }
    }

    /// The built-in default the core record holds for this kind (W1): Ask for five, Block for
    /// pop-ups and Allow for sound.
    public var builtInDefault: SitePermissionValue {
        switch self {
        case .popups: .block
        case .sound: .allow
        default: .ask
        }
    }

    /// The permission a stored default names, in the setting form a menu compares.
    public static func setting(for value: SitePermissionValue) -> SiteState.PermissionSetting {
        switch value {
        case .ask: .content("ask")
        case .allow: .content("allow")
        case .block: .content("block")
        }
    }

    /// The core value a setting corresponds to, when the menu could have chosen it.
    public static func value(for setting: SiteState.PermissionSetting?) -> SitePermissionValue? {
        guard case .content(let name)? = setting?.kind else { return nil }
        switch name {
        case "ask": return .ask
        case "allow": return .allow
        case "block": return .block
        default: return nil
        }
    }
}

/// One stored site exception as the engine lists it (W2): the profile directory (the same name a
/// space's `profileName` carries), the serialized origin, the kind and its value. Policy,
/// extension, one-time and embargo entries never reach this type.
public struct SiteException: Equatable, Sendable {
    public var profile: String
    public var origin: String
    public var kind: SitePermissionKind
    public var setting: SiteState.PermissionSetting

    public init(profile: String, origin: String, kind: SitePermissionKind, setting: SiteState.PermissionSetting) {
        self.profile = profile
        self.origin = origin
        self.kind = kind
        self.setting = setting
    }
}

/// The engine calls the Websites pane makes, behind a protocol so the Swift model tests drive a
/// fake host and the app supplies the AraratHostAPI implementation (W2, W3). All calls are
/// main-thread, like the rest of the host API.
@MainActor
public protocol SiteSettingsHost: AnyObject {
    /// Every stored user exception of the seven kinds, across regular profiles.
    func siteExceptions() -> [SiteException]
    /// Writes one origin's exception of one kind in one profile; nil resets that kind there.
    /// Returns false when the profile is not loaded or the write is refused.
    func setSiteException(profile: String, origin: String, kind: String, setting: SiteState.PermissionSetting?) -> Bool
    /// Clears the site's cookies (its registrable domain) and its storage and cache (its origin)
    /// in one profile. The reply is the number of failed removals.
    func clearSiteData(profile: String, origin: String, completion: @escaping (UInt64) -> Void)
}

/// The name a site's rows use in Settings and in the site page's title: the origin's host, or the
/// origin itself when it has no URL form (an internal scheme a user never sees).
public enum SiteOrigin {
    public static func display(_ origin: String) -> String {
        if let url = URL(string: origin), let host = url.host, !host.isEmpty { return host }
        return origin
    }

    /// The letter the site's row and page draw, as the board does (`M` for meet.example.com).
    public static func letter(_ origin: String) -> String {
        let name = display(origin)
        return name.first.map { String($0).uppercased() } ?? "?"
    }
}

/// U27w: the core's stored value in the pane's words, and the whole record's built-in values.
extension SitePermissionValue {
    public var label: String {
        switch self {
        case .ask: "Ask"
        case .allow: "Allow"
        case .block: "Block"
        }
    }

    /// The engine's request name, the same word the permission setting's content value uses.
    public var settingName: String {
        switch self {
        case .ask: "ask"
        case .allow: "allow"
        case .block: "block"
        }
    }
}

extension SiteDefaults {
    /// W1's built-in record: Ask for five kinds, Block for pop-ups, Allow for sound.
    public static var board: SiteDefaults {
        SiteDefaults(camera: .ask, microphone: .ask, location: .ask, notifications: .ask,
                     popups: .block, automaticDownloads: .ask, sound: .allow)
    }

    public func value(for kind: SitePermissionKind) -> SitePermissionValue {
        switch kind {
        case .camera: camera
        case .microphone: microphone
        case .location: location
        case .notifications: notifications
        case .popups: popups
        case .automaticDownloads: automaticDownloads
        case .sound: sound
        }
    }

    public func replacing(_ kind: SitePermissionKind, with value: SitePermissionValue) -> SiteDefaults {
        SiteDefaults(camera: kind == .camera ? value : camera,
                     microphone: kind == .microphone ? value : microphone,
                     location: kind == .location ? value : location,
                     notifications: kind == .notifications ? value : notifications,
                     popups: kind == .popups ? value : popups,
                     automaticDownloads: kind == .automaticDownloads ? value : automaticDownloads,
                     sound: kind == .sound ? value : sound)
    }

    /// The defaults as the engine's `AraratApplySiteDefaults` takes them: every kind's name to
    /// `ask`, `allow` or `block`.
    public var engineRequest: [String: String] {
        Dictionary(uniqueKeysWithValues: SitePermissionKind.allCases.map { ($0.rawValue, value(for: $0).settingName) })
    }
}
