import AppKit

@MainActor
public final class SidebarContainerView: NSView {
    private let sidebar: SidebarView
    private let page: NSView
    private let panel = NSVisualEffectView()
    public let resizeHandle: SidebarResizeHandle
    private var state = SidebarState()
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var dwellTimer: Timer?
    private var sampling: CADisplayLink?

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

    public func selectionChanged() {
        state.hasSelection = sidebar.selectedRowID != nil
        processPointer()
    }

    override public func layout() {
        super.layout()
        let width = resizeHandle.sidebarWidth
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

    private enum Motion { case dockShow, dockHide, floatingShow, floatingHide }

    private func render(_ motion: Motion) {
        let views = [panel as NSView, page]
        let old = views.map { ($0.layer?.presentation() ?? $0.layer).map { ($0.position, $0.bounds) } }
        layout()
        for (view, previous) in zip(views, old) {
            guard let layer = view.layer, let previous else { continue }
            layer.removeAnimation(forKey: "sidebar.position")
            layer.removeAnimation(forKey: "sidebar.bounds")
            for (key, from, to) in [("position", NSValue(point: previous.0), NSValue(point: layer.position)),
                                    ("bounds", NSValue(rect: previous.1), NSValue(rect: layer.bounds))] {
                let animation: CABasicAnimation
                if motion == .floatingShow {
                    let spring = CASpringAnimation(keyPath: key)
                    let omega = 2 * CGFloat.pi / SidebarMetrics.floatingResponse
                    spring.mass = 1
                    spring.stiffness = omega * omega
                    spring.damping = 2 * SidebarMetrics.floatingDamping * omega
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
        guard let window, !window.frame.contains(NSEvent.mouseLocation) else { return }
        processPointer()
    }

    private func processPointer() {
        guard let window else { return }
        let old = state.mode
        state.update(pointer: NSEvent.mouseLocation, now: ProcessInfo.processInfo.systemUptime,
                     window: window.frame, width: resizeHandle.sidebarWidth, active: NSApp.isActive, key: window.isKeyWindow)
        if state.mode != old { render(state.mode == .floating ? .floatingShow : .floatingHide) }
        updateMonitoring()
    }

    private func updateMonitoring() {
        let enabled = window?.isKeyWindow == true && NSApp.isActive && state.hasSelection
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
                let delay = max(0, start + SidebarMetrics.revealDwell - ProcessInfo.processInfo.systemUptime)
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
