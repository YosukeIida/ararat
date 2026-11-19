import AppKit

@MainActor
final class CreateSpaceView: NSView, NSTextFieldDelegate {
    static let primaryFill = NSColor(srgbRed: 29 / 255, green: 29 / 255, blue: 31 / 255, alpha: 1)
    /// The button's title while the core runs; the mock's wording.
    static let creatingTitle = "Creating…"
    var onCreate: ((String) -> Void)?
    var onCancel: (() -> Void)?
    private let name = CreateSpaceNameField()
    private let profile = NSTextField(labelWithString: "")
    private let profileCard = NSView()
    private let nameCard = CreateSpaceNameCard()
    private let create = SidebarDockButton(title: "Create Space", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private var spinnerLeading: NSLayoutConstraint!
    private var pendingCreatingStart: DispatchWorkItem?
    /// Tests inject this to run the 250 ms delay by hand, as `FindBarView` does for its spinner.
    var scheduleCreatingStart: (TimeInterval, DispatchWorkItem) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    private let cancel = SidebarDockButton(title: "Cancel", target: nil, action: nil)
    private let error = NSTextField(wrappingLabelWithString: "")
    private(set) var submitting = false
    var active = false {
        didSet {
            setAccessibilityHidden(!active)
            for control in [name as NSControl, create, cancel] { control.refusesFirstResponder = !active }
        }
    }
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        let heading = NSTextField(labelWithString: "Create a Space")
        heading.font = .systemFont(ofSize: SidebarMetrics.createSpaceHeadingSize, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Keep related tabs together.")
        subtitle.font = .systemFont(ofSize: SidebarMetrics.createSpaceCaptionSize)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        name.placeholderString = "Name"
        name.font = .systemFont(ofSize: SidebarMetrics.createSpaceBodySize)
        name.isBordered = false
        name.isBezeled = false
        name.focusRingType = .none
        name.drawsBackground = false
        name.setAccessibilityLabel("Space name")
        name.delegate = self
        name.target = self
        name.action = #selector(submit)
        nameCard.wantsLayer = true
        nameCard.layer?.cornerRadius = SidebarMetrics.createSpaceCardRadius
        nameCard.layer?.cornerCurve = .continuous
        nameCard.addSubview(name)
        profileCard.wantsLayer = true
        profileCard.layer?.cornerRadius = SidebarMetrics.createSpaceCardRadius
        profileCard.layer?.cornerCurve = .continuous
        let caption = NSTextField(labelWithString: "Profile")
        caption.font = .systemFont(ofSize: SidebarMetrics.createSpaceCaptionSize)
        caption.textColor = .secondaryLabelColor
        profile.font = .systemFont(ofSize: SidebarMetrics.createSpaceBodySize)
        let person = NSImageView()
        person.image = NSImage(systemSymbolName: "person", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: SidebarMetrics.createSpaceBodySize, weight: .regular))
        person.contentTintColor = .secondaryLabelColor
        person.setAccessibilityHidden(true)
        let profileValue = NSStackView(views: [person, profile])
        profileValue.alignment = .centerY
        profileValue.spacing = SidebarMetrics.createSpaceGap
        let profileLabels = NSStackView(views: [caption, profileValue])
        profileLabels.orientation = .vertical
        profileLabels.alignment = .leading
        profileLabels.spacing = SidebarMetrics.createSpaceGap
        profileCard.addSubview(profileLabels)
        error.font = .systemFont(ofSize: SidebarMetrics.createSpaceCaptionSize)
        error.textColor = .systemRed
        error.isHidden = true
        let form = NSStackView(views: [nameCard, profileCard, error])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = SidebarMetrics.createSpaceGap
        create.bezelStyle = .rounded
        create.bezelColor = Self.primaryFill
        create.keyEquivalent = "\r"
        create.target = self
        create.action = #selector(submit)
        create.setAccessibilityLabel("Create Space")
        cancel.isBordered = false
        cancel.contentTintColor = .labelColor
        cancel.target = self
        cancel.action = #selector(cancelCreation)
        cancel.setAccessibilityLabel("Cancel space creation")
        for button in [create, cancel] { button.font = .systemFont(ofSize: SidebarMetrics.createSpaceBodySize) }
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        spinner.setAccessibilityHidden(true)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        create.addSubview(spinner)
        spinnerLeading = spinner.leadingAnchor.constraint(equalTo: create.centerXAnchor)
        for view in [heading, subtitle, form, create, cancel] { addSubview(view) }
        for view in [heading, subtitle, form, nameCard, name, profileCard, profileLabels, error, create, cancel] { view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SidebarMetrics.createSpaceInset),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -SidebarMetrics.createSpaceInset),
            heading.topAnchor.constraint(equalTo: topAnchor, constant: SidebarMetrics.createSpaceTopInset),
            subtitle.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SidebarMetrics.createSpaceInset),
            subtitle.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: SidebarMetrics.createSpaceGap),
            form.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SidebarMetrics.createSpaceInset),
            form.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: SidebarMetrics.createSpaceHeaderGap),
            nameCard.widthAnchor.constraint(equalTo: form.widthAnchor),
            nameCard.heightAnchor.constraint(equalToConstant: SidebarMetrics.createSpaceFieldHeight),
            name.leadingAnchor.constraint(equalTo: nameCard.leadingAnchor, constant: 10),
            name.trailingAnchor.constraint(equalTo: nameCard.trailingAnchor, constant: -10),
            name.centerYAnchor.constraint(equalTo: nameCard.centerYAnchor),
            profileCard.widthAnchor.constraint(equalTo: form.widthAnchor),
            profileCard.heightAnchor.constraint(equalToConstant: SidebarMetrics.createSpaceProfileHeight),
            profileLabels.leadingAnchor.constraint(equalTo: profileCard.leadingAnchor, constant: SidebarMetrics.createSpaceCardInset),
            profileLabels.trailingAnchor.constraint(lessThanOrEqualTo: profileCard.trailingAnchor, constant: -SidebarMetrics.createSpaceCardInset),
            profileLabels.centerYAnchor.constraint(equalTo: profileCard.centerYAnchor),
            error.widthAnchor.constraint(equalTo: form.widthAnchor),
            create.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            create.trailingAnchor.constraint(equalTo: form.trailingAnchor),
            create.heightAnchor.constraint(equalToConstant: SidebarMetrics.createSpaceButtonHeight),
            create.bottomAnchor.constraint(equalTo: cancel.topAnchor, constant: -SidebarMetrics.createSpaceGap),
            cancel.centerXAnchor.constraint(equalTo: centerXAnchor),
            cancel.heightAnchor.constraint(equalToConstant: SidebarMetrics.createSpaceCancelHeight),
            cancel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -SidebarMetrics.createSpaceInset),
            spinner.centerYAnchor.constraint(equalTo: create.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: SidebarMetrics.createSpaceSpinnerSize),
            spinner.heightAnchor.constraint(equalToConstant: SidebarMetrics.createSpaceSpinnerSize),
            spinnerLeading,
        ])
        refresh()
        updateFill()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func prepare(profileName: String) {
        profile.stringValue = profileName
        profile.setAccessibilityLabel("Current profile: \(profileName)")
    }

    func begin(profileName: String) {
        prepare(profileName: profileName)
        name.stringValue = ""
        finish(error: nil)
        window?.makeFirstResponder(name)
    }

    func finish(error message: String?) {
        submitting = false
        pendingCreatingStart?.cancel()
        pendingCreatingStart = nil
        name.isEditable = true
        cancel.isEnabled = true
        error.stringValue = message ?? ""
        error.isHidden = message == nil
        setCreating(false)
        refresh()
    }

    func controlTextDidChange(_ notification: Notification) { refresh() }
    private func refresh() { create.isEnabled = !submitting && !name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    @objc private func submit() {
        let value = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard active, !submitting, !value.isEmpty else { return }
        submitting = true
        name.isEditable = false
        cancel.isEnabled = false
        refresh()
        scheduleCreating()
        onCreate?(value)
    }
    @objc private func cancelCreation() { if active && !submitting { onCancel?() } }
    override func cancelOperation(_ sender: Any?) { cancelCreation() }
    override func hitTest(_ point: NSPoint) -> NSView? { active ? super.hitTest(point) : nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateFill() }

    /// The find bar's rule: a creation that answers quickly never flashes the state. The button is
    /// disabled from the press either way, so the wait itself still reads as busy.
    private func scheduleCreating() {
        pendingCreatingStart?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.submitting else { return }
            self.pendingCreatingStart = nil
            self.setCreating(true)
        }
        pendingCreatingStart = work
        scheduleCreatingStart(0.25, work)
    }

    /// The mock's submitting state, drawn as one centred group: a 14 pt spinner, 7 pt, then
    /// "Creating…". NSButton centres the title alone, so the title carries a transparent leading
    /// attachment as wide as the spinner plus the gap, and the spinner is laid out in that
    /// attachment's first 14 pt. Cancel is disabled too — `cancelCreation` refuses while the core
    /// runs, so an enabled Cancel would offer a press that does nothing.
    private func setCreating(_ creating: Bool) {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        guard creating else {
            create.title = "Create Space"
            return
        }
        let slot = SidebarMetrics.createSpaceSpinnerSize + SidebarMetrics.createSpaceSpinnerGap
        let attachment = NSTextAttachment()
        attachment.image = NSImage(size: NSSize(width: slot, height: SidebarMetrics.createSpaceSpinnerSize))
        attachment.bounds = NSRect(x: 0, y: 0, width: slot, height: SidebarMetrics.createSpaceSpinnerSize)
        let font = create.font ?? .systemFont(ofSize: SidebarMetrics.createSpaceBodySize)
        let title = NSMutableAttributedString(attachment: attachment)
        title.append(NSAttributedString(string: Self.creatingTitle, attributes: [.font: font]))
        create.attributedTitle = title
        let width = (Self.creatingTitle as NSString).size(withAttributes: [.font: font]).width
        spinnerLeading.constant = -(slot + width) / 2
        spinner.isHidden = false
        spinner.startAnimation(nil)
    }

    // MARK: P4 item 6 check seams

    /// The page's state as the create-space check reads it. `submitting` is what greys the
    /// button and locks the name; it must drop when the core answers either way.
    var checkState: (open: Bool, submitting: Bool, buttonEnabled: Bool, name: String, error: String, errorShown: Bool) {
        (active, submitting, create.isEnabled, name.stringValue, error.stringValue, !error.isHidden)
    }

    func checkType(_ text: String) {
        name.stringValue = text
        refresh()
    }

    /// The submitting state as the mock draws it: the drawn title (the attachment is the spinner's
    /// slot, not text), whether the spinner is up, and whether Cancel is still offered. The state
    /// that drives it is `checkState.submitting`.
    var checkCreating: (title: String, spinnerShown: Bool, cancelEnabled: Bool) {
        (create.attributedTitle.string.replacingOccurrences(of: "\u{FFFC}", with: ""), !spinner.isHidden, cancel.isEnabled)
    }

    /// The same path a Return takes (the button's key equivalent and the field's action), so a
    /// second press while the first is in flight is refused by the same guard.
    @discardableResult
    func checkSubmit() -> Bool {
        let before = submitting
        submit()
        return !before && submitting
    }
    private func updateFill() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            profileCard.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            nameCard.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        }
    }
}

private final class CreateSpaceNameField: NSTextField {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
}

private final class CreateSpaceNameCard: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === self ? subviews.first : hit
    }
}
