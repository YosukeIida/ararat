import AppKit

final class RemotePlaceholderView: NSView {
    private let imageView = NSImageView()
    private let blur = NSVisualEffectView()
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        imageView.imageScaling = .scaleAxesIndependently
        imageView.frame = bounds
        imageView.autoresizingMask = [.width, .height]
        addSubview(imageView)
        blur.material = .hudWindow
        blur.blendingMode = .withinWindow
        blur.state = .active
        blur.frame = bounds
        blur.autoresizingMask = [.width, .height]
        addSubview(blur)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(image: NSImage?, message: String) {
        imageView.image = image
        blur.isHidden = image == nil
        label.stringValue = message
        setAccessibilityLabel(message)
    }
}
