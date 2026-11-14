import AppKit
import AraratKit
import SwiftUI

/// The onboarding window's measurements: the boards' 640 × 480 sheet, its 48 pt content margins,
/// 32 pt flat buttons at an 8 pt radius, 40 pt list rows in a 12 pt card, and the five step dots.
/// Board values are kept as drawn (44 pt top, 28 pt title, 12 pt card radius, 20 pt footer gaps),
/// as the other settings and bar metrics do; only the board's 6 pt dot and 30 pt button were
/// rounded to 8 and 32, the two sizes the app sets rather than measures.
public enum OnboardingMetrics {
    public static let size = NSSize(width: 640, height: 480)
    public static let margin: CGFloat = 48
    public static let top: CGFloat = 44
    public static let footerHeight: CGFloat = 32
    public static let bottom: CGFloat = 24
    public static let gap: CGFloat = 8
    public static let titleSize: CGFloat = 22
    public static let bodySize: CGFloat = 13
    public static let titleHeight: CGFloat = 28
    public static let rowHeight: CGFloat = 40
    public static let cardRadius: CGFloat = 12
    public static let buttonHeight: CGFloat = 32
    public static let buttonRadius: CGFloat = 8
    public static let buttonPadding: CGFloat = 16
    public static let dot: CGFloat = 8
    public static let columnGap: CGFloat = 16
    public static let progressHeight: CGFloat = 8
}

public enum OnboardingColor {
    public static let background = NSColor.white
    public static let foreground = NSColor(srgbRed: 0x1D / 255, green: 0x1D / 255, blue: 0x1F / 255, alpha: 1)
    public static let secondary = NSColor(srgbRed: 0x6E / 255, green: 0x6E / 255, blue: 0x73 / 255, alpha: 1)
    public static let card = NSColor(srgbRed: 0xF7 / 255, green: 0xF7 / 255, blue: 0xF7 / 255, alpha: 1)
    public static let hairline = NSColor(white: 0, alpha: 0.08)
    public static let secondaryButton = NSColor(white: 0, alpha: 0.07)
    public static let secondaryButtonPressed = NSColor(white: 0, alpha: 0.11)
    public static let primaryButton = NSColor(srgbRed: 0x1D / 255, green: 0x1D / 255, blue: 0x1F / 255, alpha: 1)
    public static let primaryButtonPressed = NSColor(srgbRed: 0x34 / 255, green: 0x34 / 255, blue: 0x3A / 255, alpha: 1)
    public static let danger = NSColor(srgbRed: 0xC4 / 255, green: 0x00 / 255, blue: 0x1A / 255, alpha: 1)
    public static let warning = NSColor(srgbRed: 0xB2 / 255, green: 0x6A / 255, blue: 0x00 / 255, alpha: 1)
    public static let dotOff = NSColor(srgbRed: 0xC8 / 255, green: 0xC8 / 255, blue: 0xCE / 255, alpha: 1)
}

/// U27j's window: a 640 × 480 sheet whose content is redrawn for each stage. AppKit views rather
/// than SwiftUI so every element carries a marker identifier the VM check reads (the VM's
/// accessibility tree is empty in process, as `SidebarChecks.swift` says).
@MainActor
public final class OnboardingWindowController: NSWindowController {
    public let model: OnboardingModel
    private var hasOpened = false

    public init(model: OnboardingModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: OnboardingMetrics.size),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Ararat"
        window.isReleasedWhenClosed = false
        window.backgroundColor = OnboardingColor.background
        window.contentMinSize = OnboardingMetrics.size
        window.contentMaxSize = OnboardingMetrics.size
        let content = OnboardingContentView(model: model)
        content.autoresizingMask = [.width, .height]
        window.contentView = content
        super.init(window: window)
        model.onChange = { [weak content] in content?.render() }
        // The close button ends the flow the way "Start Fresh" does, so the check that walks the
        // window sees the same end state either way.
        model.onFinish = { [weak self] in self?.window?.performClose(nil) }
        content.render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public func open() {
        guard let window else { return }
        if !hasOpened {
            window.center()
            hasOpened = true
        }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    public func checkProbe() -> OnboardingCheckProbe? {
        guard let window, let content = window.contentView as? OnboardingContentView else { return nil }
        return OnboardingCheckProbe(controller: self, window: window, content: content)
    }

    @discardableResult
    public func checkClick(_ id: String) -> Bool {
        guard let content = window?.contentView as? OnboardingContentView, let button = content.button(id) else { return false }
        button.performClick(nil)
        content.render()
        return true
    }

    public func checkRender() {
        (window?.contentView as? OnboardingContentView)?.render()
    }
}

/// What the VM check reads: the stage and its copy, the rows, the frames the markers name, and
/// the buttons (clicked through the same action a pointer runs).
@MainActor
public final class OnboardingCheckProbe {
    private let controller: OnboardingWindowController
    private let window: NSWindow
    private let content: OnboardingContentView

    init(controller: OnboardingWindowController, window: NSWindow, content: OnboardingContentView) {
        self.controller = controller
        self.window = window
        self.content = content
    }

    public var model: OnboardingModel { controller.model }
    public var windowFrame: NSRect { window.frame }
    public var contentSize: NSSize { content.bounds.size }
    public var isVisible: Bool { window.isVisible }
    public var stage: OnboardingModel.Stage { model.stage }
    public var stageName: String { OnboardingCheckProbe.name(stage) }
    public var title: String { content.text("onboarding-title") }
    public var subtitle: String { content.text("onboarding-subtitle") }
    public var summaryLine: String { content.text("onboarding-summary") }
    public var errorMessage: String { content.text("onboarding-error") }
    public var warningMessage: String { content.text("onboarding-warning") }
    public var reportLines: [String] { content.texts(prefix: "onboarding-line-") }
    public var sourceRows: [(id: String, text: String, later: Bool)] {
        content.markers(prefix: "onboarding-source-").map { ($0.id, content.text($0.id), $0.id.contains("-later-")) }
    }
    public var spaceRows: [(id: String, text: String)] {
        content.markers(prefix: "onboarding-space-").map { ($0.id, content.text($0.id)) }
    }
    public var alsoRows: [(id: String, text: String)] {
        content.markers(prefix: "onboarding-also-").map { ($0.id, content.text($0.id)) }
    }
    public var progressRows: [(id: String, text: String)] {
        content.markers(prefix: "onboarding-progress-").map { ($0.id, content.text($0.id)) }
    }
    public var dots: Int { content.markers(prefix: "onboarding-dot-").count }
    public var filledDot: Int? {
        content.markers(prefix: "onboarding-dot-").firstIndex { content.dotIsFilled($0.id) }
    }
    public var buttons: [String] { content.markers(prefix: "onboarding-").filter { content.button($0.id) != nil }.map(\.id) }

    public func frame(_ id: String) -> NSRect? { content.markerFrame(id) }
    public func layout() { content.layoutSubtreeIfNeeded() }
    public func render() { controller.checkRender() }

    @discardableResult
    public func click(_ id: String) -> Bool {
        let clicked = controller.checkClick(id)
        content.layoutSubtreeIfNeeded()
        return clicked
    }

    /// `welcome`, `source`, `what-to-import`, `default-browser`, `progress`, `sibling-file`, `done`,
    /// `error`: the ledger's stage names.
    public static func name(_ stage: OnboardingModel.Stage) -> String {
        switch stage {
        case .welcome: return "welcome"
        case .source: return "source"
        case .whatToImport: return "what-to-import"
        case .defaultBrowser: return "default-browser"
        case .progress: return "progress"
        case .siblingFile: return "sibling-file"
        case .done: return "done"
        case .error: return "error"
        }
    }
}

// MARK: - The drawing

/// The window's one content view: `render()` clears and rebuilds the stage's views, so every
/// frame and marker the check reads is the state the model is in.
@MainActor
final class OnboardingContentView: NSView {
    let model: OnboardingModel
    private var dotFilled = Set<String>()

    init(model: OnboardingModel) {
        self.model = model
        super.init(frame: NSRect(origin: .zero, size: OnboardingMetrics.size))
        wantsLayer = true
        layer?.backgroundColor = OnboardingColor.background.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    // MARK: rendering

    func render() {
        subviews.forEach { $0.removeFromSuperview() }
        dotFilled.removeAll()
        let width = bounds.width > 0 ? bounds.width : OnboardingMetrics.size.width
        let height = bounds.height > 0 ? bounds.height : OnboardingMetrics.size.height
        let contentWidth = width - OnboardingMetrics.margin * 2
        let footerY = height - OnboardingMetrics.bottom - OnboardingMetrics.footerHeight
        var y = OnboardingMetrics.top

        switch model.stage {
        case .welcome:
            glyph(y: &y, width: width)
            title("Welcome to Ararat", width: width, y: &y, centered: true)
            body("Vertical tabs, spaces and a command bar, on Chromium.", width: width, y: &y, centered: true)
        case .source:
            title("Bring your browser with you", width: width, y: &y)
            body("Ararat imports the spaces, tabs and looks you have in Arc. Nothing in Arc is changed.", width: width, y: &y)
            y += 16
            let rows = sourceRows()
            let card = card(rows: rows, x: OnboardingMetrics.margin, y: y, width: contentWidth)
            addSubview(card)
        case .whatToImport:
            title("Choose what comes along", width: width, y: &y)
            body("Spaces keep their order, folders and looks. Keyboard shortcuts are counted in the report, not imported.", width: width, y: &y)
            y += 16
            let column = (contentWidth - OnboardingMetrics.columnGap) / 2
            let leftHeading = label("Spaces, with their profiles", size: 11, weight: .semibold, color: OnboardingColor.secondary)
            leftHeading.frame = NSRect(x: OnboardingMetrics.margin, y: y, width: column, height: 16)
            addSubview(leftHeading)
            let rightHeading = label("Also", size: 11, weight: .semibold, color: OnboardingColor.secondary)
            rightHeading.frame = NSRect(x: OnboardingMetrics.margin + column + OnboardingMetrics.columnGap, y: y, width: column, height: 16)
            addSubview(rightHeading)
            y += 20
            let spaceCard = card(rows: spaceRows(), x: OnboardingMetrics.margin, y: y, width: column)
            addSubview(spaceCard)
            let alsoCard = card(rows: alsoRows(), x: OnboardingMetrics.margin + column + OnboardingMetrics.columnGap, y: y, width: column)
            addSubview(alsoCard)
        case .defaultBrowser:
            glyph(y: &y, width: width)
            title("Make Ararat your default browser?", width: width, y: &y, centered: true)
            body("Links from other apps open in the space that Air Traffic Control picks.", width: width, y: &y, centered: true)
        case .progress:
            title("Importing from Arc", width: width, y: &y)
            body("The workspace is written in one step at the end.", width: width, y: &y)
            y += 16
            let track = NSView(frame: NSRect(x: OnboardingMetrics.margin, y: y, width: contentWidth, height: OnboardingMetrics.progressHeight))
            track.wantsLayer = true
            track.layer?.backgroundColor = OnboardingColor.dotOff.cgColor
            track.layer?.cornerRadius = OnboardingMetrics.progressHeight / 2
            addSubview(track)
            y += OnboardingMetrics.progressHeight + 16
            let card = card(rows: progressRows(), x: OnboardingMetrics.margin, y: y, width: contentWidth)
            addSubview(card)
        case .done:
            title("Your spaces are here", width: width, y: &y)
            if let summary = model.summary {
                body(summary.line, width: width, y: &y, id: "onboarding-summary")
            }
            y += 16
            if !model.lines.isEmpty {
                let heading = label("Imported differently", size: 11, weight: .semibold, color: OnboardingColor.secondary)
                heading.frame = NSRect(x: OnboardingMetrics.margin + 12, y: y, width: contentWidth - 12, height: 16)
                addSubview(heading)
                y += 20
                addSubview(card(rows: model.lines.map { lineRow($0) }, x: OnboardingMetrics.margin, y: y, width: contentWidth, rowHeight: 28))
            }
        case .siblingFile(let message):
            title("One file could not be read", width: width, y: &y)
            body("The spaces came in. This file did not, so the rest of the import went on without it.", width: width, y: &y)
            y += 16
            addSubview(detail(message, id: "onboarding-warning", color: OnboardingColor.warning, y: y, width: contentWidth))
        case .error(let message):
            title("The import stopped", width: width, y: &y, centered: true)
            body("Nothing was imported. Nothing in Arc was changed.", width: width, y: &y, centered: true)
            y += 16
            addSubview(detail(message, id: "onboarding-error", color: OnboardingColor.danger, y: y, width: contentWidth))
        }

        addSubview(footer(width: width, y: footerY))
    }

    // MARK: pieces

    private func title(_ text: String, width: CGFloat, y: inout CGFloat, centered: Bool = false) {
        let field = label(text, size: OnboardingMetrics.titleSize, weight: .bold, color: OnboardingColor.foreground)
        field.identifier = NSUserInterfaceItemIdentifier("onboarding-title")
        field.frame = NSRect(x: OnboardingMetrics.margin, y: y, width: width - OnboardingMetrics.margin * 2, height: OnboardingMetrics.titleHeight)
        field.alignment = centered ? .center : .left
        addSubview(field)
        y += OnboardingMetrics.titleHeight
    }

    private func glyph(y: inout CGFloat, width: CGFloat) {
        let view = NSImageView()
        view.image = OnboardingGlyph.mountain(size: 64, color: OnboardingColor.foreground)
        view.frame = NSRect(x: (width - 64) / 2, y: y, width: 64, height: 64)
        addSubview(view)
        y += 64 + 8
    }

    private func body(_ text: String, width: CGFloat, y: inout CGFloat, centered: Bool = false, id: String = "onboarding-subtitle") {
        let field = label(text, size: OnboardingMetrics.bodySize, weight: .regular, color: OnboardingColor.secondary)
        field.identifier = NSUserInterfaceItemIdentifier(id)
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 2
        let height: CGFloat = 36
        field.frame = NSRect(x: OnboardingMetrics.margin, y: y + 4, width: width - OnboardingMetrics.margin * 2, height: height)
        field.alignment = centered ? .center : .left
        addSubview(field)
        y += 4 + height
    }

    private func button(_ id: String, _ title: String, primary: Bool, action: Selector, x: CGFloat, y: CGFloat) -> OnboardingButton {
        let button = OnboardingButton(title: title, primary: primary, identifier: id, target: model, action: action)
        button.frame = NSRect(x: x, y: y, width: button.fittingWidth, height: OnboardingMetrics.buttonHeight)
        return button
    }

    private func footer(width: CGFloat, y: CGFloat) -> NSView {
        let footer = NSView(frame: NSRect(x: OnboardingMetrics.margin, y: y, width: width - OnboardingMetrics.margin * 2, height: OnboardingMetrics.footerHeight))
        let dotY = (OnboardingMetrics.footerHeight - OnboardingMetrics.dot) / 2
        for index in 0..<5 {
            let dot = NSView(frame: NSRect(x: CGFloat(index) * (OnboardingMetrics.dot + OnboardingMetrics.gap), y: dotY,
                                           width: OnboardingMetrics.dot, height: OnboardingMetrics.dot))
            dot.identifier = NSUserInterfaceItemIdentifier("onboarding-dot-\(index)")
            dot.wantsLayer = true
            dot.layer?.cornerRadius = OnboardingMetrics.dot / 2
            let filled = model.dotIndex.map { index <= $0 } ?? false
            dot.layer?.backgroundColor = (filled ? OnboardingColor.foreground : OnboardingColor.dotOff).cgColor
            if filled { dotFilled.insert("onboarding-dot-\(index)") }
            footer.addSubview(dot)
        }
        var trailing = footer.bounds.width
        func place(_ button: OnboardingButton) {
            trailing -= button.frame.width
            button.frame.origin = NSPoint(x: trailing, y: (OnboardingMetrics.footerHeight - OnboardingMetrics.buttonHeight) / 2)
            footer.addSubview(button)
            trailing -= OnboardingMetrics.gap
        }
        // The specs are the board's left-to-right order; place runs from the right edge, so it
        // walks them backwards to leave the first spec leftmost.
        for spec in footerButtons().reversed() {
            place(button(spec.id, spec.title, primary: spec.primary, action: spec.action, x: 0, y: 0))
        }
        return footer
    }

    private struct ButtonSpec {
        let id: String
        let title: String
        let primary: Bool
        let action: Selector
    }

    /// Back on the left, the primary action rightmost: the board's footer order.
    private func footerButtons() -> [ButtonSpec] {
        switch model.stage {
        case .welcome:
            return [ButtonSpec(id: "onboarding-start-fresh", title: "Start Fresh", primary: false, action: #selector(OnboardingModel.startFreshFromWindow(_:))),
                    ButtonSpec(id: "onboarding-next", title: "Import from Another Browser", primary: true, action: #selector(OnboardingModel.next(_:)))]
        case .source, .whatToImport:
            let primary = model.stage == .source ? "Continue" : "Import"
            return [ButtonSpec(id: "onboarding-back", title: "Back", primary: false, action: #selector(OnboardingModel.back(_:))),
                    ButtonSpec(id: "onboarding-next", title: primary, primary: true, action: #selector(OnboardingModel.next(_:)))]
        case .defaultBrowser:
            return [ButtonSpec(id: "onboarding-not-now", title: "Not Now", primary: false, action: #selector(OnboardingModel.notNowFromWindow(_:))),
                    ButtonSpec(id: "onboarding-set-default", title: "Set as Default", primary: true, action: #selector(OnboardingModel.setDefaultFromWindow(_:)))]
        case .progress:
            return []
        case .done:
            return [ButtonSpec(id: "onboarding-continue", title: "Continue", primary: true, action: #selector(OnboardingModel.finishFromWindow(_:)))]
        case .siblingFile:
            return [ButtonSpec(id: "onboarding-start-fresh", title: "Start Fresh", primary: false, action: #selector(OnboardingModel.startFreshFromWindow(_:))),
                    ButtonSpec(id: "onboarding-continue", title: "Continue", primary: true, action: #selector(OnboardingModel.continueFromWindow(_:)))]
        case .error:
            return [ButtonSpec(id: "onboarding-copy-details", title: "Copy Details", primary: false, action: #selector(OnboardingModel.copyDetailsFromWindow(_:))),
                    ButtonSpec(id: "onboarding-start-fresh", title: "Start Fresh", primary: false, action: #selector(OnboardingModel.startFreshFromWindow(_:))),
                    ButtonSpec(id: "onboarding-retry", title: "Try Again", primary: true, action: #selector(OnboardingModel.retryFromWindow(_:)))]
        }
    }

    private func sourceRows() -> [OnboardingRowView] {
        var rows: [OnboardingRowView] = []
        if model.arcInstalled {
            rows.append(OnboardingRowView(id: "onboarding-source-arc", title: "Arc",
                                          subtitle: "Found on this Mac · \(model.arcSpaceCount) \(model.arcSpaceCount == 1 ? "space" : "spaces")",
                                          dimmed: false))
        }
        for name in model.laterBrowsers {
            rows.append(OnboardingRowView(id: "onboarding-source-later-\(name.lowercased())", title: name, subtitle: "Later", dimmed: true))
        }
        return rows
    }

    private func spaceRows() -> [OnboardingRowView] {
        model.spaceRows.map { space in
            OnboardingRowView(id: "onboarding-space-\(space.id)", title: space.title,
                              subtitle: "Profile \(space.profileName) · \(space.pinnedCount) pinned", dimmed: false)
        }
    }

    private func alsoRows() -> [OnboardingRowView] {
        model.alsoRows.enumerated().map { index, title in
            OnboardingRowView(id: "onboarding-also-\(index)", title: title, subtitle: "", dimmed: false)
        }
    }

    /// One row per step, the step's name only: the board's rows carry counts the call cannot
    /// know before it runs, and a status word ('Waiting') would be copy with no producer.
    private func progressRows() -> [OnboardingRowView] {
        OnboardingModel.progressSteps.enumerated().map { index, title in
            OnboardingRowView(id: "onboarding-progress-\(index)", title: title, subtitle: "", dimmed: false)
        }
    }

    private func lineRow(_ line: OnboardingReportLine) -> OnboardingRowView {
        let row = OnboardingRowView(id: "onboarding-line-\(line.id)", title: line.text, subtitle: "", dimmed: false, wraps: true)
        return row
    }

    private func card(rows: [NSView], x: CGFloat, y: CGFloat, width: CGFloat, rowHeight: CGFloat = OnboardingMetrics.rowHeight) -> NSView {
        let height = CGFloat(rows.count) * rowHeight + 2
        let card = OnboardingFlippedView(frame: NSRect(x: x, y: y, width: width, height: height))
        card.wantsLayer = true
        card.layer?.backgroundColor = OnboardingColor.card.cgColor
        card.layer?.cornerRadius = OnboardingMetrics.cardRadius
        card.layer?.masksToBounds = true
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: 0, y: 1 + CGFloat(index) * rowHeight, width: width, height: rowHeight)
            card.addSubview(row)
            if index > 0 {
                let hairline = NSView(frame: NSRect(x: 12, y: 1 + CGFloat(index) * rowHeight, width: width - 24, height: 1))
                hairline.wantsLayer = true
                hairline.layer?.backgroundColor = OnboardingColor.hairline.cgColor
                card.addSubview(hairline)
            }
        }
        return card
    }

    private func detail(_ message: String, id: String, color: NSColor, y: CGFloat, width: CGFloat) -> NSView {
        let box = OnboardingFlippedView(frame: NSRect(x: OnboardingMetrics.margin, y: y, width: width, height: 56))
        box.wantsLayer = true
        box.layer?.backgroundColor = OnboardingColor.card.cgColor
        box.layer?.cornerRadius = 8
        let field = label(message, size: 11, weight: .regular, color: color)
        field.identifier = NSUserInterfaceItemIdentifier(id)
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 3
        field.frame = NSRect(x: 12, y: 8, width: width - 24, height: 40)
        box.addSubview(field)
        return box
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.isEditable = false
        field.isSelectable = false
        field.drawsBackground = false
        field.isBordered = false
        return field
    }

    // MARK: the check's reads

    func button(_ id: String) -> NSButton? {
        descendants(of: self).first { $0.identifier?.rawValue == id } as? NSButton
    }

    func text(_ id: String) -> String {
        guard let view = descendants(of: self).first(where: { $0.identifier?.rawValue == id }) else { return "" }
        if let field = view as? NSTextField { return field.stringValue }
        return descendants(of: view).compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: " ")
    }

    func texts(prefix: String) -> [String] {
        markers(prefix: prefix).map { text($0.id) }
    }

    func markers(prefix: String) -> [(id: String, frame: NSRect)] {
        descendants(of: self).compactMap { view in
            guard let id = view.identifier?.rawValue, id.hasPrefix(prefix) else { return nil }
            return (id, markerFrame(id) ?? .zero)
        }.sorted { $0.frame.minY < $1.frame.minY }
    }

    func markerFrame(_ id: String) -> NSRect? {
        guard let view = descendants(of: self).first(where: { $0.identifier?.rawValue == id }) else { return nil }
        return view.convert(view.bounds, to: self)
    }

    func dotIsFilled(_ id: String) -> Bool { dotFilled.contains(id) }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}

/// A 40 pt list row: title, optional 11 pt subtitle, the board's 16 pt inset. Flipped, so the
/// title sits above the subtitle and a card's rows run top-down in the order it is given.
@MainActor
final class OnboardingRowView: NSView {
    override var isFlipped: Bool { true }

    init(id: String, title: String, subtitle: String, dimmed: Bool, wraps: Bool = false) {
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier(id)
        alphaValue = dimmed ? 0.45 : 1
        let titleField = NSTextField(wrappingLabelWithString: title)
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.textColor = OnboardingColor.foreground
        titleField.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        titleField.maximumNumberOfLines = wraps ? 2 : 1
        titleField.frame = NSRect(x: 16, y: subtitle.isEmpty ? 12 : 4, width: 232, height: 17)
        titleField.autoresizingMask = [.width]
        addSubview(titleField)
        if !subtitle.isEmpty {
            let subtitleField = NSTextField(wrappingLabelWithString: subtitle)
            subtitleField.font = .systemFont(ofSize: 11)
            subtitleField.textColor = OnboardingColor.secondary
            subtitleField.maximumNumberOfLines = 1
            subtitleField.frame = NSRect(x: 16, y: 21, width: 232, height: 14)
            subtitleField.autoresizingMask = [.width]
            addSubview(subtitleField)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// A top-down container for the cards and the error/warning box.
@MainActor
final class OnboardingFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The flat 32 pt button the boards draw.
@MainActor
final class OnboardingButton: NSButton {
    private let primary: Bool
    private let resting: NSColor

    init(title: String, primary: Bool, identifier: String, target: AnyObject?, action: Selector) {
        self.primary = primary
        self.resting = primary ? OnboardingColor.primaryButton : OnboardingColor.secondaryButton
        super.init(frame: .zero)
        self.title = title
        self.identifier = NSUserInterfaceItemIdentifier(identifier)
        self.target = target
        self.action = action
        isBordered = false
        wantsLayer = true
        font = .systemFont(ofSize: 13, weight: .medium)
        contentTintColor = primary ? .white : OnboardingColor.foreground
        layer?.backgroundColor = resting.cgColor
        layer?.cornerRadius = OnboardingMetrics.buttonRadius
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isHighlighted: Bool {
        didSet { layer?.backgroundColor = (isHighlighted ? (primary ? OnboardingColor.primaryButtonPressed : OnboardingColor.secondaryButtonPressed) : resting).cgColor }
    }

    var fittingWidth: CGFloat {
        let width = (title as NSString).size(withAttributes: [.font: font ?? .systemFont(ofSize: 13)]).width
        return max(88, ceil(width) + OnboardingMetrics.buttonPadding * 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
    }
}

enum OnboardingGlyph {
    static func mountain(size: CGFloat, color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let path = NSBezierPath()
            path.lineWidth = 2.4
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: rect.width * x / 64, y: rect.height * y / 64) }
            path.move(to: point(6, 50)); path.line(to: point(22, 22)); path.line(to: point(30, 34))
            path.line(to: point(36, 25)); path.line(to: point(58, 50)); path.close()
            path.move(to: point(17.5, 30)); path.line(to: point(22, 34)); path.line(to: point(26, 31))
            color.setStroke()
            path.stroke()
            return true
        }
        return image
    }
}

// MARK: - The model's window actions

/// The buttons are the model's targets, so a click runs the same method a test calls. The selectors
/// exist only to give NSButton its action; they forward to the model's public methods.
extension OnboardingModel {
    @objc public func next(_ sender: Any?) { advance() }
    @objc public func back(_ sender: Any?) { goBack() }
    @objc public func startFreshFromWindow(_ sender: Any?) { startFresh() }
    @objc public func setDefaultFromWindow(_ sender: Any?) { setAsDefault() }
    @objc public func notNowFromWindow(_ sender: Any?) { notNow() }
    @objc public func continueFromWindow(_ sender: Any?) { continueAfterSiblingWarning() }
    @objc public func finishFromWindow(_ sender: Any?) { startFresh() }
    @objc public func retryFromWindow(_ sender: Any?) { retry() }
    @objc public func copyDetailsFromWindow(_ sender: Any?) { copyDetails() }
}
