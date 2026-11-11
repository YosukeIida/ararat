import AppKit

@MainActor
public final class SidebarContainerView: NSView {
    private let sidebar: SidebarView
    private let page: NSView
    public let findBar = FindBarView()
    private var findPageRect: NSRect?
    private let panel = SidebarPanelView()
    private let pageMask = CAShapeLayer()
    public let resizeHandle: SidebarResizeHandle
    private var state = SidebarState()
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var dwellTimer: Timer?
    private var sampling: CADisplayLink?
    private var menuTracking = false
    private var libraryRevealedSidebar = false
    private var maskingTransition = false
    private var motionGeneration = 0
    private var moving = false
    private var stateBeforeFullscreen: SidebarState?
    public var windowFullscreen = false {
        didSet {
            guard windowFullscreen != oldValue else { return }
            if windowFullscreen {
                stateBeforeFullscreen = state
                state.hideForFullscreen()
            } else if let previous = stateBeforeFullscreen {
                let selection = state.hasSelection
                state = previous
                state.hasSelection = selection
                stateBeforeFullscreen = nil
            }
            needsLayout = true
            layoutSubtreeIfNeeded()
            processPointer()
        }
    }
    public var pageFullscreen = false {
        didSet {
            guard pageFullscreen != oldValue else { return }
            if pageFullscreen {
                stopMonitoring()
                motionGeneration += 1
                moving = false
                maskingTransition = false
                panel.layer?.removeAllAnimations()
                page.layer?.removeAllAnimations()
                pageMask.removeAllAnimations()
            }
            needsLayout = true
            layoutSubtreeIfNeeded()
            if !pageFullscreen { processPointer() }
        }
    }
    private var windowButtons: SidebarWindowButtons?
    private let extensionsButton = NSButton()
    public var extensionActions: (() -> [[String: Any]])? {
        didSet { extensionsButton.isHidden = extensionActions == nil }
    }
    public var onExtensionAction: ((String) -> Void)?
    public var onExtensionAnchor: ((NSRect) -> Void)?
    var pointerLocation: () -> NSPoint = { NSEvent.mouseLocation }
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var applicationActive: () -> Bool = { NSApp.isActive }
    var windowKey: (() -> Bool)?
    var pressedButtons: () -> Int = { NSEvent.pressedMouseButtons }

    public func lookCheckRendering(reduced: Bool) -> (vibrancy: Bool, glass: Bool, grain: Float, alpha: CGFloat) {
        panel.setCheckReduceTransparency(reduced)
        let glass: Bool
        if #available(macOS 26, *) { glass = panel.subviews.contains { $0 is NSGlassEffectView && !$0.isHidden } }
        else { glass = false }
        return (!panel.vibrancy.isHidden, glass, panel.grain.opacity, panel.gradient.backgroundColor?.alpha ?? -1)
    }
    public var sidebarState: String { state.mode.rawValue }
    public var sidebarAnimating: Bool { moving }
    public var sidebarCloseButton: NSButton? { windowButtons?.subviews.first as? NSButton }
    public var sidebarExtensionsButton: NSButton { extensionsButton }
    public var hasSidebarLights: Bool { windowButtons?.subviews.count == 3 }
    public var sidebarLightsHidden: Bool { windowButtons?.isHidden == true }
    public var appKitLightsHidden: Bool {
        guard let window else { return false }
        return [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].allSatisfy {
            window.standardWindowButton($0)?.isHidden == true
        }
    }
    public var appKitLightsVisible: Bool {
        guard let window else { return false }
        return [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].allSatisfy {
            guard let button = window.standardWindowButton($0) else { return false }
            return !button.isHidden
        }
    }
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
        panel.wantsLayer = true
        panel.layer?.cornerCurve = .continuous
        addSubview(page)
        findBar.isHidden = true
        addSubview(findBar)
        addSubview(panel)
        extensionsButton.image = NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: "Extensions")
        extensionsButton.isBordered = false
        extensionsButton.isHidden = true
        extensionsButton.target = self
        extensionsButton.action = #selector(showExtensions)
        for view in [sidebar, resizeHandle] {
            view.translatesAutoresizingMaskIntoConstraints = false
            panel.addSubview(view)
        }
        panel.addSubview(extensionsButton)
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
            if open && self.state.mode == .hidden {
                self.libraryRevealedSidebar = true
                self.state.toggle()
            } else if !open && self.libraryRevealedSidebar {
                self.libraryRevealedSidebar = false
                self.state.toggle()
            }
            self.render(scroll ? .spaceSwitch : open ? .dockShow : .dockHide) {
                self.resizeHandle.widthExtension = open ? SidebarMetrics.libraryWidthIncrease : 0
            }
        }
        sidebar.onLookChanged = { [weak self] from, to, fraction in
            self?.panel.updateLook(from, to, fraction: fraction)
        }
        sidebar.refreshLook()
        resizeHandle.onWidthChanged = { [weak self] in
            self?.needsLayout = true
            self?.layoutSubtreeIfNeeded()
        }
        resizeHandle.onDrag = { [weak self] x in
            guard let self else { return false }
            var collapsedState = self.state
            guard collapsedState.collapseDrag(pointerX: x) else { return false }
            self.libraryRevealedSidebar = false
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
        guard !pageFullscreen else { return }
        libraryRevealedSidebar = false
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
        if pageFullscreen {
            panel.isHidden = true
            page.frame = bounds
            page.layer?.mask = nil
            layoutFindBar()
            return
        }
        panel.isHidden = false
        let width = resizeHandle.displayedWidth
        let docked = state.mode == .docked
        let floating = state.mode == .floating
        let x: CGFloat = docked ? 0 : floating ? SidebarMetrics.floatingInset : -width
        let inset: CGFloat = docked ? 0 : SidebarMetrics.floatingInset
        panel.frame = NSRect(x: x, y: inset, width: width, height: max(0, bounds.height - inset * 2))
        windowButtons?.frame.origin = NSPoint(x: 12.5, y: panel.bounds.height - 30.5)
        extensionsButton.frame = NSRect(x: 90, y: panel.bounds.height - 34, width: 24, height: 24)
        if state.mode != .hidden {
            onExtensionAnchor?(extensionsButton.convert(extensionsButton.bounds, to: nil))
        }
        let pageX: CGFloat = docked ? width : SidebarMetrics.cardInset
        page.frame = NSRect(x: pageX, y: SidebarMetrics.cardInset,
                            width: max(0, bounds.width - pageX - SidebarMetrics.cardInset),
                            height: max(0, bounds.height - SidebarMetrics.cardInset * 2))
        layoutFindBar()
        panel.layer?.cornerRadius = docked ? 0 : SidebarMetrics.cornerRadius
        panel.layer?.masksToBounds = !docked
        panel.layer?.borderWidth = docked ? 0 : SidebarMetrics.borderWidth
        page.layer?.mask = floating || maskingTransition ? pageMask : nil
        let path = CGMutablePath()
        path.addRect(page.bounds)
        path.addRect(convert(panel.frame, to: page))
        pageMask.path = path
        panel.setAccessibilityHidden(state.mode == .hidden)
        windowButtons?.sidebarHidden = state.mode == .hidden && !moving
        windowButtons?.isHidden = window?.styleMask.contains(.fullScreen) == true || windowButtons?.sidebarHidden == true
        if let window { WindowChrome.layout(window: window, lights: windowButtons) }
        updateBorder()
    }

    private func layoutFindBar() {
        let rect = findPageRect.map { convert($0, from: page) } ?? page.frame
        let width = min(380, rect.width)
        let frame = NSRect(x: rect.maxX - width, y: rect.minY, width: width, height: 36)
        findBar.frame = findBar.superview.map { $0.convert(frame, from: self) } ?? frame
    }

    public func placeFindBarAbovePage(in root: NSView) {
        if findBar.superview !== root || root.subviews.last !== findBar {
            root.addSubview(findBar, positioned: .above, relativeTo: nil)
        }
        layoutFindBar()
    }

    public func setFindPageRect(_ rect: NSRect) {
        findPageRect = rect
        layoutFindBar()
    }

    @objc private func showExtensions() {
        onExtensionAnchor?(extensionsButton.convert(extensionsButton.bounds, to: nil))
        let menu = makeExtensionsMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: extensionsButton.bounds.minY), in: extensionsButton)
    }

    func makeExtensionsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = sidebar
        for action in extensionActions?() ?? [] {
            guard let id = action["id"] as? String, let name = action["name"] as? String else { continue }
            let item = NSMenuItem(title: name, action: #selector(runExtension(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.image = action["icon"] as? NSImage
            menu.addItem(item)
        }
        return menu
    }

    @objc private func runExtension(_ item: NSMenuItem) {
        if let id = item.representedObject as? String { onExtensionAction?(id) }
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

    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func render(_ motion: Motion, changes: () -> Void = {}) {
        moving = true
        motionGeneration += 1
        let generation = motionGeneration
        maskingTransition = page.layer?.mask != nil || state.mode == .floating
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor in
                guard let self, self.motionGeneration == generation else { return }
                self.finishMotion(scrolling: motion == .spaceSwitch)
            }
        }
        defer { CATransaction.commit() }
        let oldMaskPath = (pageMask.presentation() as? CAShapeLayer)?.path ?? pageMask.path
        let views = [panel as NSView, page]
        let old = views.map { ($0.layer?.presentation() ?? $0.layer).map { ($0.position, $0.bounds) } }
        changes()
        layout()
        if (motion == .floatingShow || motion == .floatingHide) && reduceMotion() {
            pageMask.removeAnimation(forKey: "sidebar.mask")
            for view in views {
                view.layer?.removeAnimation(forKey: "sidebar.position")
                view.layer?.removeAnimation(forKey: "sidebar.bounds")
            }
            windowButtons?.layer?.removeAnimation(forKey: "sidebar.lights")
            return
        }
        if let lights = windowButtons, let layer = lights.layer {
            let previous = layer.presentation()?.opacity ?? 1
            layer.removeAnimation(forKey: "sidebar.lights")
            if motion != .spaceSwitch {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = previous
                fade.toValue = state.mode == .hidden ? 0 : 1
                fade.duration = motion == .dockShow || motion == .floatingShow ? SidebarMetrics.dockShowDuration
                    : motion == .dockHide ? SidebarMetrics.dockHideDuration : SidebarMetrics.floatingHideDuration
                fade.timingFunction = SidebarMetrics.easeOutCubic
                fade.fillMode = .forwards
                fade.isRemovedOnCompletion = false
                layer.add(fade, forKey: "sidebar.lights")
            }
        }
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

    func finishMotion(scrolling: Bool = false) {
        moving = false
        windowButtons?.layer?.removeAnimation(forKey: "sidebar.lights")
        maskingTransition = false
        layout()
        if !scrolling { sidebar.libraryDidLand() }
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        NotificationCenter.default.removeObserver(self)
        let previousWindow = windowButtons?.browserWindow
        windowButtons?.removeFromSuperview()
        windowButtons = nil
        (previousWindow as? BrowserWindow)?.sidebarLights = nil
        if let previousWindow { WindowChrome.layout(window: previousWindow, lights: nil) }
        guard let window else { return }
        let buttons = SidebarWindowButtons(window: window)
        windowButtons = buttons
        panel.addSubview(buttons)
        (window as? BrowserWindow)?.sidebarLights = buttons
        WindowChrome.layout(window: window, lights: buttons)
        window.acceptsMouseMovedEvents = true
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(contextChanged), name: name, object: nil)
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didMoveNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(contextChanged), name: name, object: window)
        }
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(chromeChanged), name: name, object: window)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(windowClosed), name: NSWindow.willCloseNotification, object: window)
        for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(menuChanged(_:)), name: name, object: nil)
        }
        processPointer()
    }

    @objc private func chromeChanged() {
        if let window { WindowChrome.layout(window: window, lights: windowButtons) }
    }

    @objc private func menuChanged(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu, menu.delegate === sidebar else { return }
        menuTracking = notification.name == NSMenu.didBeginTrackingNotification
        sidebar.tooltip.menuTracking = menuTracking
        if !menuTracking { sidebar.refreshPointer() }
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
        guard !pageFullscreen else { return }
        guard let window else { return }
        let old = state.mode
        state.update(pointer: pointerLocation(), now: clock(),
                     window: window.frame, width: resizeHandle.displayedWidth, active: applicationActive(), key: windowKey?() ?? window.isKeyWindow,
                     interacting: menuTracking || pressedButtons() != 0 || sidebar.libraryOpen)
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
