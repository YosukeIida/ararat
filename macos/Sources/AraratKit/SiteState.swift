import AppKit
import Foundation

/// The engine's focused-site snapshot (U26e passes 1-3), parsed for the UI and the checks.
/// Every field is optional except the document id and origin: an internal page carries no
/// permission rows and no certificate chain, and an empty snapshot means "not ready yet".
public struct SiteState {
    public struct PermissionSetting: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case content(String)
            case geolocation(approximate: String, precise: String)
        }

        public let kind: Kind

        public init?(dictionary value: Any?) {
            guard let dictionary = value as? [String: Any], let kind = dictionary["kind"] as? String else { return nil }
            switch kind {
            case "content":
                guard let name = dictionary["value"] as? String else { return nil }
                self.kind = .content(name)
            case "geolocation":
                guard let approximate = dictionary["approximate"] as? String,
                      let precise = dictionary["precise"] as? String else { return nil }
                self.kind = .geolocation(approximate: approximate, precise: precise)
            default:
                return nil
            }
        }

        public static func content(_ value: String) -> PermissionSetting {
            PermissionSetting(unchecked: .content(value))
        }

        private init(unchecked kind: Kind) { self.kind = kind }

        public var request: [String: Any] {
            switch kind {
            case .content(let value):
                return ["kind": "content", "value": value]
            case .geolocation(let approximate, let precise):
                return ["kind": "geolocation", "approximate": approximate, "precise": precise]
            }
        }

        /// Allow, block and ask are the three uniform values the menu offers; session_only
        /// appears only where the engine lists it, and mixed geolocation pairs only where it
        /// lists those too (both come from `allowed`, never from a guess).
        public var title: String {
            switch kind {
            case .content(let value):
                switch value {
                case "allow": return "Allow"
                case "block": return "Block"
                case "ask": return "Ask"
                case "session_only": return "Allow for session"
                default: return "Unsupported"
                }
            case .geolocation(let approximate, let precise):
                if approximate == precise {
                    switch approximate {
                    case "allow": return "Allow"
                    case "block": return "Block"
                    case "ask": return "Ask"
                    default: return "Unsupported"
                    }
                }
                // S10: every mixed pair names both halves, so no two menu items read alike.
                func word(_ value: String) -> String {
                    switch value {
                    case "allow": return "Allow"
                    case "block": return "Block"
                    case "ask": return "Ask"
                    default: return value.capitalized
                    }
                }
                return "\(word(approximate)) approximate, \(word(precise)) precise"
            }
        }

        public var isBlock: Bool {
            switch kind {
            case .content(let value): return value == "block"
            case .geolocation(let approximate, let precise): return approximate == "block" && precise == "block"
            }
        }
    }

    public struct Permission {
        public var type: String
        public var requestingOrigin: String
        public var embeddingOrigin: String
        /// Nil when the site has no explicit setting (the engine sends NSNull); the row then
        /// shows the default and offers no Reset.
        public var setting: PermissionSetting?
        public var defaultSetting: PermissionSetting?
        public var source: String
        public var mutable: Bool
        public var allowed: [PermissionSetting]
        public var siteSpecificBlock: Bool

        public var displayName: String { SiteState.name(for: type) }
        public var iconName: String { SiteState.icon(for: type) }
        public var isExplicit: Bool { setting != nil }
        public var current: PermissionSetting? { setting ?? defaultSetting }
        public var isReadOnly: Bool { !mutable }
    }

    public var document: String
    public var origin: String
    /// "secure", "not_secure", "error" or "none" (internal pages have no connection state).
    public var security: String
    public var certificateChain: [Data]
    public var permissions: [Permission]
    /// True when this tab was refused a permission or holds a site-specific Block.
    public var blocked: Bool
    public var isInternal: Bool

    public init?(_ value: [String: Any]) {
        guard let document = value["document"] as? String, !document.isEmpty,
              let origin = value["origin"] as? String else { return nil }
        self.document = document
        self.origin = origin
        security = value["security"] as? String ?? "none"
        certificateChain = (value["certificateChain"] as? [Data]) ?? []
        blocked = value["blocked"] as? Bool ?? false
        isInternal = value["internal"] as? Bool ?? false
        permissions = ((value["permissions"] as? [[String: Any]]) ?? []).map { row in
            Permission(type: row["type"] as? String ?? "",
                       requestingOrigin: row["requestingOrigin"] as? String ?? "",
                       embeddingOrigin: row["embeddingOrigin"] as? String ?? "",
                       setting: PermissionSetting(dictionary: row["setting"]),
                       defaultSetting: PermissionSetting(dictionary: row["defaultSetting"]),
                       source: row["source"] as? String ?? "none",
                       mutable: row["mutable"] as? Bool ?? false,
                       allowed: ((row["allowed"] as? [[String: Any]]) ?? []).compactMap {
                           PermissionSetting(dictionary: $0)
                       },
                       siteSpecificBlock: row["siteSpecificBlock"] as? Bool ?? false)
        }
    }

    /// The site-controls footer's pill (P4, 2026-11-15): Arc's two words, and a quiet line for a
    /// page with no connection information (an error page, a local page).
    public var securityPillTitle: String {
        switch security {
        case "secure": return "Secure"
        case "not_secure", "error": return "Not Secure"
        default: return "No connection information"
        }
    }

    /// How the pill looks: `secure` and `neutral` take the quiet fill, `warn` and `bad` the
    /// board's amber and red. A page without connection information is `neutral`, never a
    /// warning colour (the board draws no such state).
    public enum SecurityPill: String, Equatable {
        case secure, neutral, warn, bad
    }

    public var securityPill: SecurityPill {
        switch security {
        case "secure": return .secure
        case "not_secure": return .warn
        case "error": return .bad
        default: return .neutral
        }
    }

    public var securitySymbol: String {
        switch security {
        case "secure": return "lock.fill"
        case "not_secure": return "exclamationmark.triangle.fill"
        case "error": return "xmark.octagon.fill"
        default: return "questionmark.circle"
        }
    }

    public var canShowCertificate: Bool { !certificateChain.isEmpty }
    public var isSecure: Bool { security == "secure" }

    public var buttonSymbol: String {
        switch security {
        case "secure": return "slider.horizontal.3"
        case "not_secure": return "exclamationmark.triangle"
        default: return "slider.horizontal.3"
        }
    }

    static func name(for type: String) -> String {
        switch type {
        case "notifications": return "Notifications"
        case "geolocation": return "Location"
        case "media-stream-camera": return "Camera"
        case "media-stream-mic": return "Microphone"
        case "midi-sysex", "midi": return "MIDI devices"
        case "clipboard": return "Clipboard"
        case "fullscreen": return "Full screen"
        case "popups": return "Pop-ups"
        case "javascript": return "JavaScript"
        case "images": return "Images"
        case "cookies": return "Cookies"
        case "sound": return "Sound"
        case "sensors": return "Motion sensors"
        case "payment-handler": return "Payment handlers"
        case "idle-detection": return "Idle detection"
        case "background-sync": return "Background sync"
        case "window-placement": return "Window placement"
        case "local-fonts": return "Fonts"
        case "storage-access": return "Storage access"
        case "automatic-downloads": return "Automatic downloads"
        case "protected-media-identifier": return "Protected content"
        case "serial": return "Serial ports"
        case "usb": return "USB devices"
        case "hid": return "HID devices"
        case "bluetooth-guard": return "Bluetooth"
        default:
            let words = type.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }
            return words.isEmpty ? "Permission" : words.joined(separator: " ")
        }
    }

    static func icon(for type: String) -> String {
        switch type {
        case "notifications": return "bell"
        case "geolocation": return "location"
        case "media-stream-camera": return "camera"
        case "media-stream-mic": return "mic"
        case "midi-sysex", "midi": return "pianokeys"
        case "clipboard": return "doc.on.clipboard"
        case "fullscreen": return "arrow.up.left.and.arrow.down.right"
        case "popups": return "macwindow.on.rectangle"
        case "cookies": return "circle.grid.cross"
        case "sound": return "speaker.wave.2"
        case "sensors": return "gyroscope"
        case "payment-handler": return "creditcard"
        case "local-fonts": return "textformat"
        case "serial", "usb", "hid": return "cable.connector"
        case "bluetooth-guard": return "wave.3.right"
        default: return "checkmark.shield"
        }
    }
}

/// One toolbar action as the engine reports it. The image is Chromium's rendered action icon,
/// which already carries the badge, so the UI never paints a second one.
public struct ExtensionActionItem {
    public var id: String
    public var name: String
    public var tooltip: String
    public var icon: NSImage
    public var enabled: Bool
    public var pinned: Bool
    public var pinMutable: Bool
    public var removable: Bool
    public var badgeText: String
    public var focusedTabId: Int
    public var badgeBackgroundColor: UInt32
    public var badgeTextColor: UInt32

    public init?(_ value: [String: Any]) {
        guard let id = value["id"] as? String, !id.isEmpty else { return nil }
        self.id = id
        name = value["name"] as? String ?? id
        tooltip = value["tooltip"] as? String ?? name
        icon = value["icon"] as? NSImage ?? NSImage()
        enabled = value["enabled"] as? Bool ?? false
        pinned = value["pinned"] as? Bool ?? false
        pinMutable = value["pinMutable"] as? Bool ?? false
        removable = value["removable"] as? Bool ?? false
        badgeText = value["badgeText"] as? String ?? ""
        focusedTabId = (value["focusedTabId"] as? NSNumber)?.intValue ?? -1
        badgeBackgroundColor = (value["badgeBackgroundColor"] as? NSNumber)?.uint32Value ?? 0
        badgeTextColor = (value["badgeTextColor"] as? NSNumber)?.uint32Value ?? 0
    }
}
