import AppKit
import SwiftUI

/// The settings frame's geometry, from Yab's measurements and the boards: cards of radius 12
/// on 10 pt gaps (§7), and the search hit's fill inside a card — the selection grey inset 3 pt
/// with radius 9, so a hit row reads as pressed inside its card rather than as the card itself
/// (D7, the board's `.rw.hit`; its rows are at least 48 pt tall, which the 54 pt row already is).
public enum SettingsMetrics {
    public static let cardRadius: CGFloat = 12
    public static let cardGap: CGFloat = 10
    public static let hitInset: CGFloat = 3
    public static let hitRadius: CGFloat = 9
    public static let hitRowHeight: CGFloat = 48
    public static let groupHeadingInset: CGFloat = 12
    public static let separatorInset: CGFloat = 10
}

/// The hit's fill. A view of its own so tests can render it alone and read where the grey
/// starts and which corner radius it takes.
struct SettingsHitFill: View {
    var body: some View {
        RoundedRectangle(cornerRadius: SettingsMetrics.hitRadius)
            .fill(SettingsColor.selected)
            .padding(SettingsMetrics.hitInset)
            .allowsHitTesting(false)
    }
}

/// A heading above a grouped card: the board's group caption (12 pt semibold, secondary,
/// 12 pt in from the card's edge).
struct SettingsGroupHeading: View {
    let title: String
    var marker: String?
    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, SettingsMetrics.groupHeadingInset)
            .background { if let marker { SettingsMarker(id: marker) } }
    }
}

/// The boards' grouped card (D6): one card holding several rows, an optional heading above it
/// and a hairline between rows, inset 10 pt from the card's edges. The panes built before U27
/// keep one card per row; the new panes group their rows this way.
struct SettingsGroupCard<Content: View>: View {
    var heading: String? = nil
    var marker: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let heading { SettingsGroupHeading(title: heading, marker: marker.map { "\($0)-heading" }) }
            VStack(spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius).fill(SettingsColor.card))
                .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius))
                .background { if let marker { SettingsMarker(id: marker) } }
        }
    }
}

/// One row inside a grouped card: the hairline above every row but the first (inset 10 pt),
/// the row's padding and height, and the search hit's fill when the row is the hit.
struct SettingsCardRow<Content: View>: View {
    var height: CGFloat = 54
    var first = false
    var hit = false
    var marker: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            if !first {
                Rectangle()
                    .fill(SettingsColor.separator)
                    .frame(height: 1)
                    .padding(.horizontal, SettingsMetrics.separatorInset)
            }
            HStack(spacing: 12) { content }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
        }
        .background {
            ZStack {
                if hit { SettingsHitFill() }
            }
        }
        .background { if let marker { SettingsMarker(id: marker) } }
    }
}

/// A marker the screen check finds by identifier in the window's view tree. The VM's
/// accessibility tree is empty in process, so every frame a check measures comes from one of
/// these, as the Look popover and the Shortcuts rows do.
struct SettingsMarker: NSViewRepresentable {
    let id: String
    func makeNSView(context: Context) -> SettingsMarkerView {
        let view = SettingsMarkerView()
        view.identifier = NSUserInterfaceItemIdentifier(id)
        return view
    }
    func updateNSView(_ view: SettingsMarkerView, context: Context) {
        view.identifier = NSUserInterfaceItemIdentifier(id)
    }
}

final class SettingsMarkerView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
