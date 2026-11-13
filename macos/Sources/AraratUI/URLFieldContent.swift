import Foundation

/// D1/D2: what the URL field shows for the selected tab, as one rule with no view state.
/// The board's content states (C-UrlField): a URL with a host shows the host; `file:` the file
/// name; `data:` just the scheme; `about:blank` and the new-tab page the placeholder (with the
/// buttons); other internal pages a gear and the full URL; no tab the placeholder without
/// buttons. An error page reports its failed URL, so it falls into the host case.
public struct URLFieldContent: Equatable {
    public enum Kind: Equatable {
        /// No tab is selected: the placeholder, and neither Copy Link nor the site controls.
        case noTab
        /// A URL with a host: the host only.
        case host(String)
        /// A `file:` URL: its file name.
        case file(String)
        /// `about:blank` or the new-tab page: the placeholder, with both buttons.
        case placeholder
        /// `chrome://`, `about:` other than blank, and any other hostless page: gear + full URL.
        case internalPage(String)
        /// A `data:` URL: the scheme and nothing after it.
        case data
    }

    public static let placeholderText = "Search or enter URL"

    public let kind: Kind

    public init(url: String?, hasTab: Bool) {
        guard hasTab else {
            kind = .noTab
            return
        }
        guard let url, !url.isEmpty, let parsed = URL(string: url) else {
            // A tab that has no URL yet (an uncommitted New Tab row) reads as the placeholder.
            kind = .placeholder
            return
        }
        let scheme = parsed.scheme?.lowercased() ?? ""
        switch scheme {
        case "chrome", "chrome-untrusted", "devtools", "chrome-extension":
            // chrome://newtab/ carries the host "newtab", so the scheme is checked before the host.
            if scheme == "chrome", parsed.host?.lowercased() == "newtab" {
                kind = .placeholder
            } else {
                kind = .internalPage(url)
            }
        case "about":
            let page = parsed.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
            kind = page.isEmpty || page == "blank" ? .placeholder : .internalPage(url)
        case "data":
            kind = .data
        case "file":
            let name = parsed.lastPathComponent
            kind = .file(name.isEmpty ? url : name)
        default:
            if let host = parsed.host, !host.isEmpty {
                kind = .host(host)
            } else {
                // blob:, view-source: and any other scheme without an authority: no site, so the
                // field behaves like the other internal pages rather than showing nothing.
                kind = .internalPage(url)
            }
        }
    }

    /// The field's text. For the placeholder kinds the view draws `placeholderText` instead.
    public var text: String {
        switch kind {
        case .noTab, .placeholder: return ""
        case .host(let host): return host
        case .file(let name): return name
        case .internalPage(let url): return url
        case .data: return "data:"
        }
    }

    public var showsPlaceholder: Bool {
        switch kind {
        case .noTab, .placeholder: return true
        default: return false
        }
    }

    public var showsGear: Bool {
        if case .internalPage = kind { return true }
        return false
    }

    /// D2: only the no-tab state removes the buttons. A tab whose content is the placeholder
    /// keeps them.
    public var hidesButtons: Bool { kind == .noTab }

    /// Copy Link has something to copy whenever a tab (and so a URL) is present.
    public var canCopy: Bool { kind != .noTab }

    /// What VoiceOver reads for the field; the placeholder text when there is nothing to show.
    public var accessibilityValue: String { showsPlaceholder ? Self.placeholderText : text }
}
