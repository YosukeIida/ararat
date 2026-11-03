import AppKit

@MainActor
final class CreateSpaceView: NSView, NSTextFieldDelegate {
    var onCreate: ((String) -> Void)?
    var onCancel: (() -> Void)?
    private let name = CreateSpaceNameField()
    private let profile = NSTextField(labelWithString: "")
    private let profileCard = NSView()
    private let nameCard = CreateSpaceNameCard()
    private let create = SidebarDockButton(title: "Create Space", target: nil, action: nil)
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
        let profileLabels = NSStackView(views: [caption, profile])
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
        create.keyEquivalent = "\r"
        create.target = self
        create.action = #selector(submit)
        create.setAccessibilityLabel("Create Space")
        cancel.isBordered = false
        cancel.contentTintColor = .linkColor
        cancel.target = self
        cancel.action = #selector(cancelCreation)
        cancel.setAccessibilityLabel("Cancel space creation")
        for button in [create, cancel] { button.font = .systemFont(ofSize: SidebarMetrics.createSpaceBodySize) }
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
        name.isEditable = true
        cancel.isEnabled = true
        error.stringValue = message ?? ""
        error.isHidden = message == nil
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
        onCreate?(value)
    }
    @objc private func cancelCreation() { if active && !submitting { onCancel?() } }
    override func cancelOperation(_ sender: Any?) { cancelCreation() }
    override func hitTest(_ point: NSPoint) -> NSView? { active ? super.hitTest(point) : nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateFill() }
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
