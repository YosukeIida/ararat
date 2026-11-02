import AppKit

@MainActor
public final class SidebarContainerView: NSView {
    private let sidebar: SidebarView
    private let page: NSView
    private let panel = NSVisualEffectView()
    private let pageMask = CAShapeLayer()
    public let resizeHandle: SidebarResizeHandle
    private var state = SidebarState()
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var dwellTimer: Timer?
    private var sampling: CADisplayLink?
    private var menuTracking = false
    var pointerLocation: () -> NSPoint = { NSEvent.mouseLocation }
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var applicationActive: () -> Bool = { NSApp.isActive }
    var windowKey: (() -> Bool)?
    var pressedButtons: () -> Int = { NSEvent.pressedMouseButtons }

    public var sidebarState: String { state.mode.rawValue }
    override public var isFlipped: Bool { true }

    public init(sidebar: SidebarView, page: NSView) {
        self.sidebar = sidebar
        self.page = page
        let width = sidebar.widthAnchor.constraint(equalToConstant: SidebarMetrics.defaultWidth)
        resizeHandle = SidebarResizeHandle(widthConstraint: width)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        page.wantsLayer = true
        pageMask.fillRule = .evenOdd
        pageMask.actions = ["path": NSNull()]
        page.layer?.mask = pageMask
        panel.material = .sidebar
        panel.blendingMode = .behindWindow
        panel.wantsLayer = true
        panel.layer?.cornerCurve = .continuous
        addSubview(page)
        addSubview(panel)
        for view in [sidebar, resizeHandle] {
            view.translatesAutoresizingMaskIntoConstraints = false
            panel.addSubview(view)
        }
        NSLayoutConstraint.activate([
            width,
            sidebar.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: panel.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            resizeHandle.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -SidebarMetrics.grabInset),
            resizeHandle.widthAnchor.constraint(equalToConstant: SidebarMetrics.grabWidth),
            resizeHandle.topAnchor.constraint(equalTo: panel.topAnchor),
            resizeHandle.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
        ])
        sidebar.onLibraryChanged = { [weak self] open, scroll in
            guard let self else { return }
            self.render(scroll ? .spaceSwitch : open ? .dockShow : .dockHide) {
                self.resizeHandle.widthExtension = open ? SidebarMetrics.libraryWidthIncrease : 0
            }
        }
        resizeHandle.onWidthChanged = { [weak self] in
            self?.needsLayout = true
            self?.layoutSubtreeIfNeeded()
        }
        resizeHandle.onDrag = { [weak self] x in
            guard let self else { return false }
            var collapsedState = self.state
            guard collapsedState.collapseDrag(pointerX: x) else { return false }
            self.resizeHandle.sidebarWidth = SidebarMetrics.minimumWidth
            self.state = collapsedState
            self.render(.dockHide)
            self.updateMonitoring()
            return true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public func toggleSidebar() {
        state.toggle()
        render(state.mode == .docked ? .dockShow : .dockHide)
        processPointer()
    }

    override public func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if !isHiddenOrHasHiddenAncestor, bounds.contains(local), let window {
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let button = window.standardWindowButton(type), button.window === window,
                      !button.isHiddenOrHasHiddenAncestor else { continue }
                if convert(button.bounds, from: button).contains(local) { return button }
            }
        }
        return super.hitTest(point)
    }

    public func selectionChanged() {
        state.hasSelection = sidebar.selectedRowID != nil && !sidebar.createSpaceOpen
        processPointer()
    }

    override public func layout() {
        super.layout()
        let width = resizeHandle.displayedWidth
        let docked = state.mode == .docked
        let floating = state.mode == .floating
        let x: CGFloat = docked ? 0 : floating ? SidebarMetrics.floatingInset : -width
        let inset: CGFloat = docked ? 0 : SidebarMetrics.floatingInset
        panel.frame = NSRect(x: x, y: inset, width: width, height: max(0, bounds.height - inset * 2))
        let pageX: CGFloat = docked ? width : SidebarMetrics.cardInset
        page.frame = NSRect(x: pageX, y: SidebarMetrics.cardInset,
                            width: max(0, bounds.width - pageX - SidebarMetrics.cardInset),
                            height: max(0, bounds.height - SidebarMetrics.cardInset * 2))
        panel.layer?.cornerRadius = docked ? 0 : SidebarMetrics.cornerRadius
        panel.layer?.masksToBounds = !docked
        panel.layer?.borderWidth = docked ? 0 : SidebarMetrics.borderWidth
        let path = CGMutablePath()
        path.addRect(page.bounds)
        path.addRect(convert(panel.frame, to: page))
        pageMask.path = path
        panel.setAccessibilityHidden(state.mode == .hidden)
        updateBorder()
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorder()
    }

    private func updateBorder() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            panel.layer?.borderColor = NSColor.white.withAlphaComponent(SidebarMetrics.borderAlpha).cgColor
        }
    }

    private enum Motion { case dockShow, dockHide, floatingShow, floatingHide, spaceSwitch }

    private func render(_ motion: Motion, changes: () -> Void = {}) {
        let oldMaskPath = (pageMask.presentation() as? CAShapeLayer)?.path ?? pageMask.path
        let views = [panel as NSView, page]
        let old = views.map { ($0.layer?.presentation() ?? $0.layer).map { ($0.position, $0.bounds) } }
        changes()
        layout()
        pageMask.removeAnimation(forKey: "sidebar.mask")
        for (view, previous) in zip(views, old) {
            guard let layer = view.layer, let previous else { continue }
            layer.removeAnimation(forKey: "sidebar.position")
            layer.removeAnimation(forKey: "sidebar.bounds")
            for (key, from, to) in [("position", NSValue(point: previous.0), NSValue(point: layer.position)),
                                    ("bounds", NSValue(rect: previous.1), NSValue(rect: layer.bounds))] {
                let animation: CABasicAnimation
                if motion == .floatingShow || motion == .spaceSwitch {
                    let spring = CASpringAnimation(keyPath: key)
                    let omega = 2 * CGFloat.pi / (motion == .spaceSwitch ? SidebarMetrics.spaceSwitchResponse : SidebarMetrics.floatingResponse)
                    spring.mass = 1
                    spring.stiffness = omega * omega
                    spring.damping = 2 * (motion == .spaceSwitch ? SidebarMetrics.spaceSwitchDamping : SidebarMetrics.floatingDamping) * omega
                    spring.duration = spring.settlingDuration
                    animation = spring
                } else {
                    animation = CABasicAnimation(keyPath: key)
                    animation.duration = motion == .dockShow ? SidebarMetrics.dockShowDuration
                        : motion == .dockHide ? SidebarMetrics.dockHideDuration : SidebarMetrics.floatingHideDuration
                    animation.timingFunction = SidebarMetrics.easeOutCubic
                }
                animation.fromValue = from
                animation.toValue = to
                layer.add(animation, forKey: "sidebar.\(key)")
                if view === panel, key == "bounds", let oldMaskPath {
                    let maskAnimation = animation.copy() as! CABasicAnimation
                    maskAnimation.keyPath = "path"
                    maskAnimation.fromValue = oldMaskPath
                    maskAnimation.toValue = pageMask.path
                    pageMask.add(maskAnimation, forKey: "sidebar.mask")
                }
            }
        }
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        NotificationCenter.default.removeObserver(self)
        guard let window else { return }
        window.acceptsMouseMovedEvents = true
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(contextChanged), name: name, object: nil)
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didMoveNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(contextChanged), name: name, object: window)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(windowClosed), name: NSWindow.willCloseNotification, object: window)
        for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(menuChanged(_:)), name: name, object: sidebar.newSpaceMenu)
        }
        processPointer()
    }

    @objc private func menuChanged(_ notification: Notification) {
        menuTracking = notification.name == NSMenu.didBeginTrackingNotification
        processPointer()
    }

    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }

    override public func mouseMoved(with event: NSEvent) { processPointer() }
    override public func mouseEntered(with event: NSEvent) { processPointer() }
    override public func mouseExited(with event: NSEvent) { processPointer() }

    @objc private func contextChanged() { processPointer() }
    @objc private func windowClosed() {
        stopMonitoring()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func samplePointer() {
        processPointer()
    }

    func processPointer() {
        guard let window else { return }
        let old = state.mode
        state.update(pointer: pointerLocation(), now: clock(),
                     window: window.frame, width: resizeHandle.displayedWidth, active: applicationActive(), key: windowKey?() ?? window.isKeyWindow,
                     interacting: menuTracking || pressedButtons() != 0)
        if state.mode != old { render(state.mode == .floating ? .floatingShow : .floatingHide) }
        updateMonitoring()
    }

    private func updateMonitoring() {
        let enabled = (windowKey?() ?? (window?.isKeyWindow == true)) && applicationActive() && state.hasSelection
        if enabled && state.mode == .hidden {
            sampling?.invalidate()
            sampling = nil
            if localMonitor == nil {
                localMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
                    self?.processPointer()
                    return event
                }
                globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
                    MainActor.assumeIsolated { self?.processPointer() }
                }
            }
            if let start = state.dwellStartedAt, dwellTimer == nil {
                let delay = max(0, start + SidebarMetrics.revealDwell - clock())
                let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.dwellTimer = nil
                        self?.processPointer()
                    }
                }
                dwellTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            } else if state.dwellStartedAt == nil {
                dwellTimer?.invalidate()
                dwellTimer = nil
            }
        } else {
            if let localMonitor { NSEvent.removeMonitor(localMonitor) }
            if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
            localMonitor = nil
            globalMonitor = nil
            dwellTimer?.invalidate()
            dwellTimer = nil
            if enabled && state.mode == .floating {
                if sampling == nil {
                    sampling = displayLink(target: self, selector: #selector(samplePointer))
                    sampling?.add(to: .main, forMode: .common)
                }
            } else {
                sampling?.invalidate()
                sampling = nil
            }
        }
    }

    private func stopMonitoring() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        dwellTimer?.invalidate()
        dwellTimer = nil
        sampling?.invalidate()
        sampling = nil
    }
}
