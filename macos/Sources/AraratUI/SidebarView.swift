import AppKit
import AraratKit
import SwiftUI

@MainActor
public final class SidebarView: NSView {
    public var onEditURL: (() -> Void)?
    public var onLinkCopied: (() -> Void)?
    public var onRetryHistory: (() -> Void)?
    public var onDismissHistory: (() -> Void)?
    private let historyBanner = NSStackView()
    private let historyMessage = NSTextField(wrappingLabelWithString: "History could not be deleted.")
    private let historyRetryButton = NSButton()
    private let historyDismissButton = NSButton()
    var historyFailureVisible: Bool { !historyBanner.isHidden }
    public var checkHistoryVisible: Bool { !historyBanner.isHidden }
    public var checkHistoryContext: (space: String?, profileID: String?, profile: String?, message: String) {
        (snapshotSpace?.id, snapshotSpace?.profileKey, snapshotSpace?.profileName, historyMessage.stringValue)
    }
    public var checkHistoryAnnouncement: ((String) -> Void)?
    public func checkClickCopyLink() { copyLinkButton.performClick(nil) }
    public func checkClickHistoryRetry() { historyRetryButton.performClick(nil) }
    public func checkClickHistoryDismiss() { historyDismissButton.performClick(nil) }
    public func checkCopyMenu(row: Row) -> Bool {
        let item = copyItem(row)
        guard item.isEnabled, let action = item.action else { return false }
        return NSApp.sendAction(action, to: item.target, from: item)
    }
    private let copyLinkButton = NSButton()
    private var historySession: WorkspaceSession?
    private var historyObserver: NSObjectProtocol?
    public var onRenameSpace: ((String, String, @escaping (Bool) -> Void) -> Void)?
    public var onDeleteSpace: ((String) -> Void)?
    public var onSpaceSettings: ((String) -> Void)?
    public var lookSettings: SettingsModel?
    private var spaceRenameField: SidebarRenameField?
    private let dockLookPopover = NSPopover()
    private var dockLookEditor: LookEditorModel?
    public var onCreateSpace: ((String) -> Void)?
    public var onCreatePageChanged: (() -> Void)?
    private(set) public var createSpaceOpen = false
    private let creation = CreateSpaceView(frame: .zero)
    private let plusButton = SidebarDockButton()
    let newSpaceMenu = NSMenu()
    private var scrollPageIndex: Int { libraryOpen ? -1 : createSpaceOpen ? snapshot.spaces.count : spaceIndex }
    public var onItemEdit: ((SidebarItemEdit, @escaping (WorkspaceSnapshot?) -> Void) -> Void)?
    public var confirmFolderDeletion: ((Row, @escaping (Bool) -> Void) -> Void)?
    public var pasteboard: NSPasteboard = .general
    private(set) var renamingID: String?
    public var onSelect: ((Row) -> Void)?
    public var onClose: ((String) -> Void)?
    public var onCloseSelected: (() -> Void)?
    public var onArchive: ((String) -> Void)?
    let tooltip = SidebarTooltip()
    private var clickMonitor: Any?
    var removeClickMonitor: (Any) -> Void = NSEvent.removeMonitor
    public var onRestore: ((String) -> Void)?
    public var onArchiveDelete: ((String) -> Void)?
    var onLibraryChanged: ((Bool, Bool) -> Void)?
    private(set) public var libraryOpen = false
    private var libraryNeedsFocus = false
    private let library = LibraryView(frame: .zero)
    let libraryButton = DownloadsButton()
    private var downloadsModel: DownloadsModel?
    private var downloadsHoverFired = false
    var downloadsPopover: DownloadsPopover?
    public var checkLibraryButtonFrame: NSRect { convert(libraryButton.bounds, from: libraryButton) }
    private let libraryFill = CALayer()
    private var refusedDockIndex: Int?
    var dockCursor: (Bool) -> Void = { refused in (refused ? NSCursor.operationNotAllowed : NSCursor.arrow).set() }
    public private(set) var libraryOpenFraction: CGFloat = 0
    private var mainColumn: NSStackView!
    var libraryPage: String { library.page.rawValue }
    public var onShowSpace: ((String) -> Void)?

    var onLookChanged: ((Look?, Look?, Double) -> Void)?
    private(set) var lookSampling: CADisplayLink?
    private var libraryLookSpaceID: String?
    private var creationLookSpaceID: String?

    private var lookPreview: (spaceID: String, look: Look?)?
    private let shortcutMenus = NSHashTable<NSMenu>.weakObjects()
    public var keyBindings = defaultKeyBindings() {
        didSet {
            for menu in shortcutMenus.allObjects { KeyBindingsModel.apply(keyBindings, to: menu) }
            let caps = closeCaps
            for view in rowViews.values { view.closeCaps = caps }
        }
    }

    // The ⌘W caps follow the close_tab binding; the Shortcuts pane can rebind it.
    private var closeCaps: [String] {
        // The effective key: a cleared or conflicting binding has none, and then no caps.
        guard let binding = keyBindings.first(where: { $0.command == "close_tab" }),
              let key = binding.key else { return [] }
        return SidebarTooltip.caps(for: key)
    }

    public var onMove: ((String, String, Int, Bool, @escaping (WorkspaceSnapshot?) -> Void) -> Void)?
    public var onFirstFavorite: ((String, String, Int, @escaping (WorkspaceSnapshot?) -> Void) -> Void)?
    public var onOpenFolder: ((String, @escaping (WorkspaceSnapshot?) -> Void) -> Void)?
    private(set) var drag: SidebarDragState?
    private(set) var dropTarget = SidebarDrop.refused
    private(set) var dragCopyView: SidebarRowView?
    private(set) var dragSettling = false
    let dropIndicator = CAShapeLayer()
    var dragClock: () -> TimeInterval = CACurrentMediaTime
    var dragReduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var dragTimer: Timer?
    private var dragLastTick: TimeInterval = 0
    private var dragFavoriteIndex: Int?
    private var dragGeneration = 0
    private var snapshot: WorkspaceSnapshot
    private var spaceIndex = 0
    private var spaceListOrigins: [String: CGFloat] = [:]
    private var selectedID: String?
    public var focusedPane: (id: String, url: String)?

    public let spaceNameRow = SidebarSpaceNameRow(frame: .zero)
    let urlField = NSButton()
    private let host = NSTextField(labelWithString: "")
    private let favorites = NSStackView()
    private var favoriteColumns = 0
    private var favoritesHeight: NSLayoutConstraint!
    private let listScroll = SidebarScrollView()
    private let rows = NSStackView()
    private var hintSpaceID: String?
    var renameHintClock: () -> CFTimeInterval = CACurrentMediaTime
    private var rowViews: [String: SidebarRowView] = [:]
    private var noTabsRows: [String: SidebarNoTabsRow] = [:]
    private var retiringRows: [String: SidebarRowView] = [:]
    private var fadeFrame: (id: String, frame: NSRect)?
    private var favoriteTiles: [String: FavoriteTile] = [:]
    private weak var organizeCheckSource: SidebarRowView?
    private var organizeCheckPoint = CGPoint.zero
    private lazy var todayDivider = SidebarTodayDivider(frame: .zero)
    private lazy var newTabRow: SidebarNewTabRow = {
        let row = SidebarNewTabRow(frame: .zero)
        row.onPress = { [weak self] in self?.onNewTab?() }
        return row
    }()
    private let dock = SpaceDockView()
    private let spaceViewport = NSView()
    private let spaceColumn = NSStackView()
    private var spaceScroll = SpaceScrollState()
    private let pullIndicator = SpacePullIndicator(frame: .zero)
    private var pullTimer: Timer?
    var pullClock: () -> CFTimeInterval = CACurrentMediaTime
    private var pullStep: (() -> Void)?
    private var wheelPullPlaying = false
    // U25b: the app’s per-window row state — the row switch from the core’s settings record
    // and the live strip’s crashed and unread tabs. The section’s chevron rides in the space
    // snapshot (pinned_collapsed), so every window shows the same one.
    public var newTabRowShown = true { didSet { reload() } }
    public var rowStates: [String: EngineAdapter.RowState] = [:] { didSet { applyRowStatus() } }
    public var onMute: ((String, Bool) -> Void)?
    public var crashedItems: Set<String> = [] { didSet { applyRowStatus() } }
    public var unreadItems: Set<String> = [] { didSet { applyRowStatus() } }
    public var onNewTab: (() -> Void)?
    public var onClearToday: (() -> Void)?
    private enum ScrollOrigin { case page, rail, list }
    private enum ScrollAxis { case horizontal, vertical }
    private var scrollOrigin: ScrollOrigin?
    private var scrollAxis: ScrollAxis?
    private weak var gestureScroll: NSScrollView?
    private var scrollPreviews: [SidebarView] = []
    private var showingScrollPages = false
    private var scrollGestureActive = false
    private var lastScrollEventAt: CFTimeInterval = 0
    private var momentumQuietDeadline: CFTimeInterval = 0
    private var momentumQuietTimer: Timer?
    public var onAutoArchiveReady: (() -> Void)?
    public var canPublishAutoArchive: Bool {
        // A pending momentum quiet blocks deliver like an active gesture: publication is left to
        // the step that ends the quiet, not to the staleness expiry, whose retry would wait for
        // the next AutoArchive tick (up to 60 s).
        let gestureActive = (scrollGestureActive || momentumQuietTimer != nil) && pullClock() - lastScrollEventAt < 2
        return renamingID == nil && spaceRenameField == nil && !tooltip.menuTracking && drag == nil && !dragSettling && !gestureActive && !showingScrollPages && !wheelPullPlaying && !listScroll.isRevealing
    }
    private func notifyAutoArchiveReady() {
        if canPublishAutoArchive { onAutoArchiveReady?() }
    }
    // Momentum can follow an ended gesture with no flag from AppKit; a publish at the gesture end
    // moves rows while momentum is still scrolling.
    private func armMomentumQuiet() {
        momentumQuietTimer?.invalidate()
        momentumQuietDeadline = pullClock() + SidebarMetrics.momentumQuiet
        let timer = Timer(timeInterval: SidebarMetrics.momentumQuiet, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepMomentumQuiet() }
        }
        RunLoop.main.add(timer, forMode: .common)
        momentumQuietTimer = timer
    }
    func stepMomentumQuiet() {
        guard momentumQuietTimer != nil, pullClock() >= momentumQuietDeadline else { return }
        cancelMomentumQuiet()
        notifyAutoArchiveReady()
    }
    private func cancelMomentumQuiet() {
        momentumQuietDeadline = 0
        momentumQuietTimer?.invalidate()
        momentumQuietTimer = nil
    }
    private var scrollGeneration = 0
    private var isScrollPreview = false
    private var laidOutSidebarWidth: CGFloat = 0
    private var spacePagePitch: Double { Double(bounds.width) }

    public init(snapshot: WorkspaceSnapshot) {
        self.snapshot = snapshot
        self.selectedID = Self.sidebarSelection(snapshot)
        self.spaceIndex = snapshot.spaces.firstIndex { $0.id == snapshot.shownSpaceId } ?? 0
        super.init(frame: .zero)
        build()
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc public func showCreateSpace(_ sender: Any? = nil) { setCreateSpaceOpen(true) }

    public func setCreateSpaceOpen(_ open: Bool, scrolling: Bool = false) {
        guard open != createSpaceOpen else { return }
        if open && libraryOpen { setLibraryOpen(false, scrolling: scrolling) }
        finishRowMotion()
        if !scrolling { clearScrollPresentation(); spaceScroll = SpaceScrollState() }
        if open { creationLookSpaceID = snapshotSpace?.id }
        createSpaceOpen = open
        updateDockSelection()
        if open && creation.superview == nil { addSubview(creation, positioned: .below, relativeTo: libraryButton); creation.frame = bounds }
        if !open && !scrolling { creation.removeFromSuperview() }
        creation.isHidden = !open
        creation.active = open
        mainColumn.isHidden = open || libraryOpen
        if open { creation.begin(profileName: snapshotSpace?.profileName ?? "Default") }
        refreshLook()
        onCreatePageChanged?()
    }

    public func applyCreatedSpace(snapshot: WorkspaceSnapshot) {
        creation.finish(error: nil)
        applySelection(snapshot: snapshot)
        if let index = snapshot.spaces.firstIndex(where: { $0.id == snapshot.shownSpaceId }) { showSpace(at: index) }
        setCreateSpaceOpen(false)
    }

    public func creationFailed(_ message: String) { creation.finish(error: message) }

    @objc private func showNewSpaceMenu(_ sender: NSButton) {
        tooltip.dismiss()
        newSpaceMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
    }

    @objc public func toggleLibrary(_ sender: Any? = nil) { setLibraryOpen(!libraryOpen) }

    public func setDownloadsModel(_ model: DownloadsModel) {
        downloadsModel = model
        library.setDownloadsModel(model)
        let popover = DownloadsPopover(model: model, anchor: libraryButton)
        popover.openLibrary = { [weak self] in self?.setLibraryOpen(true, downloads: true) }
        downloadsPopover = popover
        libraryButton.onHover = { [weak self] in self?.downloadsPopover?.show() }
        model.onChange = { [weak self, weak model] in
            guard let self, let model else { return }
            self.libraryButton.progress = model.progress
            self.library.refreshDownloads()
            if !model.hasSessionDownloads { self.downloadsPopover?.close() }
            else if self.downloadsPopover?.isShown == true { self.downloadsPopover?.show() }
        }
        libraryButton.progress = model.progress
    }

    @objc private func libraryButtonClicked(_ sender: Any?) {
        if downloadsModel?.hasSessionDownloads == true { downloadsPopover?.show(focus: true) }
        else { toggleLibrary(sender) }
    }

    public func flyDownload(from source: NSView, name: String) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let window, source.window === window, let root = window.contentView else { return }
        let origin = root.convert(NSPoint(x: source.bounds.midX, y: source.bounds.midY), from: source)
        let destination = root.convert(NSPoint(x: libraryButton.bounds.midX, y: libraryButton.bounds.midY), from: libraryButton)
        let icon = NSImageView(frame: NSRect(x: origin.x - 12, y: origin.y - 12, width: 24, height: 24))
        icon.image = downloadIcon(name)
        icon.identifier = NSUserInterfaceItemIdentifier("download-flight")
        icon.setAccessibilityHidden(true)
        icon.wantsLayer = true
        root.addSubview(icon, positioned: .above, relativeTo: nil)
        icon.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        icon.layer?.position = destination
        let path = CGMutablePath()
        path.move(to: origin)
        path.addQuadCurve(to: destination, control: CGPoint(x: (origin.x + destination.x) / 2, y: max(origin.y, destination.y) + 80))
        let flight = CAKeyframeAnimation(keyPath: "position")
        flight.path = path; flight.duration = 0.4
        flight.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { icon.removeFromSuperview() }
        icon.layer?.add(flight, forKey: "flight")
        CATransaction.commit()
    }

    private var downloadsCheckEnabled: Bool {
        CommandLine.arguments.contains("--ararat-check=downloads") || CommandLine.arguments.contains("--ararat-screen=downloads")
    }
    public func downloadsCheckState() -> [String: Any] {
        guard downloadsCheckEnabled else { return [:] }
        let progress: String
        switch libraryButton.progress {
        case .none: progress = "none"
        case .indeterminate: progress = "indeterminate"
        case .fraction: progress = "fraction"
        }
        let flight = window?.contentView?.subviews.contains { $0.identifier?.rawValue == "download-flight" } ?? false
        let ring = libraryButton.ring
        let ringVisible = !ring.isHidden && ring.superlayer != nil && ring.bounds.width > 0 && ring.bounds.height > 0 && ring.opacity > 0 && ring.strokeEnd > 0 && ring.path != nil
        let panel = downloadsPopover?.checkWindow
        let buttonFrame = window.map { $0.convertToScreen(libraryButton.convert(libraryButton.bounds, to: nil)) } ?? .zero
        let panelFrame = panel?.frame ?? .zero
        let inside = window.map { $0.frame.insetBy(dx: -1, dy: -1).contains(panelFrame) } ?? false
        let fittingHeight = DownloadsPopover.headerHeight + CGFloat(downloadsPopover?.rows.count ?? 0) * DownloadsPopover.rowHeight
        let metrics = downloadsPopover?.checkMetrics ?? [:]
        return ["progress": progress, "ring_visible": ringVisible, "items": downloadsModel?.items.map { ["id": $0.id, "name": $0.name, "state": $0.state, "received": $0.received, "total": $0.total, "restored": $0.restored, "actions": $0.actions] as [String: Any] } ?? [],
                "list": downloadsPopover?.isShown ?? false, "first": downloadsPopover?.library.title ?? "",
                "rows": downloadsPopover?.rows.mapValues { UInt(bitPattern: ObjectIdentifier($0)) } ?? [:],
                "popover_inside_above": panel != nil && inside && panelFrame.minY >= buttonFrame.maxY - 1,
                "popover_readable": panel != nil && panelFrame.width >= SidebarMetrics.defaultWidth && panelFrame.height >= fittingHeight,
                "popover_metrics": metrics, "hover_fired": downloadsHoverFired,
                "page_actions_fit": library.downloadsPage.actionButtonsFit,
                "page_rows_layout": library.downloadsPage.rowsLeadingAndStatusFit,
                "library_open": libraryOpen, "library_page": library.page.rawValue,
                "page_ids": library.downloadsPage.entries.map(\.id), "flight": flight]
    }
    public func downloadsCheckHover() {
        guard downloadsCheckEnabled else { return }
        downloadsHoverFired = false
        libraryButton.checkHover { [weak self] in
            guard let self else { return }
            self.downloadsHoverFired = true
            FileHandle.standardError.write(Data("ararat-trace: downloads hover seam: popover shown=\(self.downloadsPopover?.isShown ?? false)\n".utf8))
        }
    }
    public func downloadsCheckClosePopover() { if downloadsCheckEnabled { downloadsPopover?.close() } }
    public func downloadsCheckOpenLibrary() { if downloadsCheckEnabled { downloadsPopover?.library.performClick(nil) } }
    public func downloadsCheckShowPage() { if downloadsCheckEnabled { library.downloadsButton.performClick(nil) } }
    public var downloadsCheckPopoverWindow: NSWindow? { downloadsCheckEnabled ? downloadsPopover?.checkWindow : nil }

    public func searchArchive(_ query: String) -> Int {
        library.setSearchQuery(query)
        return library.filteredEntries.count
    }

    public func setLibraryOpen(_ open: Bool, scrolling: Bool = false, downloads: Bool = false) {
        if open { if downloads { library.showDownloads() } else { library.showArchive() } }
        guard open != libraryOpen else { return }
        if open && createSpaceOpen { setCreateSpaceOpen(false, scrolling: scrolling) }
        finishRowMotion()
        if !scrolling { clearScrollPresentation(); spaceScroll = SpaceScrollState() }
        if open { libraryLookSpaceID = snapshotSpace?.id }
        libraryOpen = open
        libraryNeedsFocus = open
        if open && library.superview == nil { addSubview(library, positioned: .below, relativeTo: libraryButton) }
        if !open && !scrolling { library.removeFromSuperview() }
        library.isHidden = !open
        library.update(archive: snapshot.archive)
        tooltip.capture(in: library)
        mainColumn.isHidden = open || createSpaceOpen
        libraryButton.libraryOpen = open
        updateDockSelection()
        if open { window?.makeFirstResponder(self) }
        refreshLook()
        onLibraryChanged?(open, scrolling)
    }

    func libraryDidLand() {
        if libraryOpen && libraryNeedsFocus && !showingScrollPages {
            libraryNeedsFocus = false
            library.focusSearch()
        }
    }

    public func applyRestore(snapshot: WorkspaceSnapshot) {
        applySelection(snapshot: snapshot)
        if let index = snapshot.spaces.firstIndex(where: { $0.id == snapshot.shownSpaceId }) { showSpace(at: index) }
        setLibraryOpen(false)
    }

    override public var acceptsFirstResponder: Bool { true }
    override public func cancelOperation(_ sender: Any?) {
        if drag != nil { cancelDrag(); return }
        if createSpaceOpen { if !creation.submitting { setCreateSpaceOpen(false) } }
        else if libraryOpen { setLibraryOpen(false) } else { _ = nextResponder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: sender) }
    }

    public var spaceShown: Int { spaceIndex }
    public var selectedRowID: String? { selectedID }

    public func organizeCheckBegin(id: String, destination: String) -> Bool {
        layoutSubtreeIfNeeded()
        guard let window, let source = rowViews[id], let geometry = dragGeometry(),
              let origin = geometry.rows.first(where: { $0.row.id == id })?.frame else { return false }
        let target: CGPoint
        if destination == "favorites" { target = CGPoint(x: geometry.favorites.midX, y: geometry.favorites.midY) }
        else if destination == "today" { target = CGPoint(x: geometry.list.midX, y: geometry.list.maxY - 2) }
        else if destination == "dock" || destination.hasPrefix("dock:") {
            let id = destination == "dock" ? "organize-other" : String(destination.dropFirst(5))
            guard let cell = geometry.dock.first(where: { $0.space.id == id }) else { return false }
            target = CGPoint(x: cell.frame.midX, y: cell.frame.midY)
        } else {
            guard let entry = geometry.rows.first(where: { $0.row.id == destination }) else { return false }
            target = destination == "organize-inner" ? CGPoint(x: entry.frame.midX, y: entry.frame.midY) : CGPoint(x: entry.frame.midX, y: entry.frame.minY + 0.5)
        }
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent? {
            let native = convert(CGPoint(x: point.x, y: bounds.height - point.y), to: nil)
            return NSEvent.mouseEvent(with: type, location: native, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        let start = CGPoint(x: origin.midX, y: origin.midY)
        guard let down = event(.leftMouseDown, start), let moved = event(.leftMouseDragged, CGPoint(x: start.x + 4, y: start.y)), let over = event(.leftMouseDragged, target) else { return false }
        organizeCheckSource = source
        organizeCheckPoint = target
        source.mouseDown(with: down)
        source.mouseDragged(with: moved)
        source.mouseDragged(with: over)
        return true
    }

    public func dockCheckEnableDragAnimation() {
        guard CommandLine.arguments.contains(where: { $0 == "--ararat-check=dock" || $0 == "--ararat-screen=dock" }) else { return }
        dragReduceMotion = { false }
    }
    public var organizeCheckSettleDuration: CFTimeInterval? { dragCopyView?.layer?.animation(forKey: "drag.settle")?.duration }
    public var organizeCheckDragging: Bool { drag?.active == true }
    public var organizeCheckIdle: Bool { drag == nil && !dragSettling }
    public var organizeCheckDropLine: Bool { dropIndicator.superlayer != nil }
    public func organizeCheckHint(id: String) -> Bool { rowViews[id]?.hintTimer != nil }

    public func organizeCheckEnd(cancel: Bool = false) -> Bool {
        guard let source = organizeCheckSource, let window else { return false }
        if cancel {
            guard let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) else { return false }
            interpretKeyEvents([key])
            return true
        }
        let native = convert(CGPoint(x: organizeCheckPoint.x, y: bounds.height - organizeCheckPoint.y), to: nil)
        guard let up = NSEvent.mouseEvent(with: .leftMouseUp, location: native, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return false }
        source.mouseUp(with: up)
        organizeCheckSource = nil
        return true
    }

    private static func sidebarSelection(_ snapshot: WorkspaceSnapshot) -> String? {
        guard let selected = snapshot.selectedId else { return nil }
        let rows = snapshot.spaces.flatMap { $0.today + $0.pinned + $0.favorites }
        var current = rows.first { $0.id == selected }
        var result = selected
        for _ in rows.indices {
            guard let row = current, let parent = rows.first(where: { $0.id == row.parentId }) else { break }
            if parent.kind == .split { result = parent.id }
            current = parent
        }
        return result
    }

    public func update(snapshot: WorkspaceSnapshot) {
        finishRowMotion()
        replaceSnapshot(snapshot)
        library.update(archive: snapshot.archive)
        tooltip.capture(in: library)
        layoutSubtreeIfNeeded()
        rowViews.values.forEach { $0.refreshHover() }
    }

    public func updateSelection(id: String?) {
        guard selectedID != id else { return }
        selectedID = id
        snapshot.selectedId = id
        reload()
        revealSelection()
    }

    public func previewLook(spaceID: String, look: Look?, active: Bool = true) {
        guard let index = snapshot.spaces.firstIndex(where: { $0.id == spaceID }) else { return }
        if active { lookPreview = (spaceID, look) }
        else if lookPreview?.spaceID == spaceID { lookPreview = nil }
        snapshot.spaces[index].look = look
        refreshLook()
    }

    private func keepingLookPreview(_ snapshot: WorkspaceSnapshot) -> WorkspaceSnapshot {
        guard let preview = lookPreview else { return snapshot }
        var snapshot = snapshot
        guard let index = snapshot.spaces.firstIndex(where: { $0.id == preview.spaceID }) else {
            lookPreview = nil
            return snapshot
        }
        snapshot.spaces[index].look = preview.look
        return snapshot
    }

    public func applySelection(snapshot: WorkspaceSnapshot) {
        let snapshot = keepingLookPreview(snapshot)
        let selected = Self.sidebarSelection(snapshot)
        let selectionChanged = selectedID != selected
        let focusedPaneChanged = self.snapshot.selectedId != snapshot.selectedId
        if self.snapshot.spaces == snapshot.spaces {
            self.snapshot = snapshot
            if selectionChanged || focusedPaneChanged { selectedID = selected; reload() }
        }
        else { replaceSnapshot(snapshot) }
        library.update(archive: snapshot.archive)
        tooltip.capture(in: library)
        if selectionChanged { revealSelection() }
    }

    private func replaceSnapshot(_ snapshot: WorkspaceSnapshot) {
        let snapshot = keepingLookPreview(snapshot)
        layoutSubtreeIfNeeded()
        listScroll.stopReveal()
        let wasScrolled = listScroll.contentView.bounds.minY > 0.5
        let anchors = rowViews.values.map { ($0.row.id, listScroll.documentView!.convert($0.bounds, from: $0)) }
            .filter { $0.1.intersects(listScroll.contentView.bounds) && $0.0 != drag?.row.id }
            .sorted { $0.1.minY < $1.1.minY }
            .map { ($0.0, $0.1.minY - listScroll.contentView.bounds.minY) }
        let shownID = snapshotSpace?.id
        clearScrollPresentation()
        spaceScroll = SpaceScrollState()
        self.snapshot = snapshot
        spaceListOrigins = spaceListOrigins.filter { id, _ in snapshot.spaces.contains { $0.id == id } }
        spaceIndex = snapshot.spaces.firstIndex { $0.id == shownID }
            ?? (shownID == nil ? snapshot.spaces.firstIndex { $0.id == snapshot.shownSpaceId } : nil)
            ?? min(spaceIndex, max(0, snapshot.spaces.count - 1))
        selectedID = Self.sidebarSelection(snapshot)
        library.update(archive: snapshot.archive)
        tooltip.capture(in: library)
        reload()
        layoutSubtreeIfNeeded()
        if wasScrolled, let anchor = anchors.first(where: { rowViews[$0.0] != nil }), let row = rowViews[anchor.0] {
            listScroll.move(to: listScroll.documentView!.convert(row.bounds, from: row).minY - anchor.1)
        }
        refreshPointer()
    }

    public func applyClose(id: String, snapshot: WorkspaceSnapshot) {
        let selectionChanged = selectedID != Self.sidebarSelection(snapshot)
        clearScrollPresentation()
        layoutSubtreeIfNeeded()
        let oldFrames = rowViews.mapValues { presentedFrame($0) }
        if let last = snapshotSpace?.today.last,
           snapshotSpace?.today.contains(where: { $0.id == id }) == true,
           !(snapshot.spaces.first { $0.id == snapshotSpace?.id }?.today.contains { $0.id == last.id } ?? false),
           let frame = oldFrames[last.id] {
            fadeFrame = (last.id, frame)
        }
        for view in rowViews.values { view.layer?.removeAnimation(forKey: "row.close.move") }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        replaceSnapshot(snapshot)
        fadeFrame = nil
        layoutSubtreeIfNeeded()
        for (id, view) in rowViews {
            view.refreshHover()
            guard let old = oldFrames[id], let parent = view.superview else { continue }
            let offset = parent.convert(old, from: self).minY - view.frame.minY
            guard abs(offset) > 0.01 else { continue }
            let animation = CABasicAnimation(keyPath: "transform.translation.y")
            animation.fromValue = offset
            animation.toValue = 0
            animation.duration = SidebarMetrics.rowCloseMoveDuration
            animation.timingFunction = SidebarMetrics.easeOutCubic
            view.layer?.add(animation, forKey: "row.close.move")
        }
        CATransaction.commit()
        if selectionChanged { revealSelection() }
    }

    private func presentedFrame(_ view: NSView) -> NSRect {
        let frame = view.layer?.animation(forKey: "row.close.move") == nil
            ? view.frame : (view.layer?.presentation()?.frame ?? view.frame)
        return convert(frame, from: view.superview)
    }

    private func finishRowMotion() {
        for view in rowViews.values { view.layer?.removeAnimation(forKey: "row.close.move") }
        for id in Array(retiringRows.keys) { removeRow(id: id) }
    }

    private var snapshotSpace: SpaceSnapshot? {
        snapshot.spaces.indices.contains(spaceIndex) ? snapshot.spaces[spaceIndex] : nil
    }

    public func selectRow(id: String) -> Bool {
        guard snapshot.spaces.indices.contains(spaceIndex) else { return false }
        let space = snapshot.spaces[spaceIndex]
        guard let row = (space.favorites + space.pinned + space.today).first(where: { $0.id == id }) else { return false }
        select(row)
        return true
    }

    // The ⌘W command carries no row: the adapter applies the R1/D2 rule to the core’s
    // current selection, so presses queued in one run-loop turn act in order.
    @objc public func closeSelectedTab(_ sender: Any?) {
        guard pageCommandsAllowed, let id = selectedID,
              snapshot.spaces.contains(where: { ($0.favorites + $0.pinned + $0.today).contains { $0.id == id && ($0.kind == .tab || $0.kind == .split) } }) else { return }
        onCloseSelected?()
    }

    public var pageCommandsAllowed: Bool {
        !createSpaceOpen && renamingID == nil && WorkspaceCommands.allowsPageCommand(window?.firstResponder)
    }

    public var canPinSelectedTab: Bool {
        guard pageCommandsAllowed, let space = snapshotSpace, let id = selectedID else { return false }
        return (space.today + space.pinned).contains { $0.id == id && $0.kind == .tab }
    }

    @objc public func pinSelectedTab(_ sender: Any?) {
        guard let onMove else { return }
        pinSelectedTab(using: onMove)
    }

    public func pinSelectedTab(using move: (String, String, Int, Bool, @escaping (WorkspaceSnapshot?) -> Void) -> Void) {
        guard canPinSelectedTab, let space = snapshotSpace, let id = selectedID else { return }
        let pinning = space.today.contains { $0.id == id }
        move(id, pinning ? space.pinnedId : space.todayId, 0, false) { [weak self] snapshot in
            guard let self, let snapshot else { return }
            self.replaceSnapshot(snapshot)
            if pinning { self.showPinHint(id: id, space: space.id) }
        }
    }

    public var selectedTabIsPinned: Bool {
        snapshotSpace?.pinned.contains { $0.id == selectedID && $0.kind == .tab } == true
    }

    public func showSpace(at index: Int) {
        showSpace(at: index, animatedReveal: true)
    }

    public func restoreShownSpace() {
        guard let index = snapshot.spaces.firstIndex(where: { $0.id == snapshot.shownSpaceId }) else { return }
        showSpace(at: index, animatedReveal: false, notify: false)
    }

    public func showSpaceWithoutNotification(at index: Int) {
        showSpace(at: index, animatedReveal: false, notify: false)
    }

    private func showSpace(at index: Int, animatedReveal: Bool, notify: Bool = true) {
        guard snapshot.spaces.indices.contains(index) else { return }
        if drag != nil { cancelDrag() }
        if index != spaceIndex { spaceRenameField?.finish(commit: true) }
        listScroll.stopReveal()
        if !isScrollPreview, let id = snapshotSpace?.id { spaceListOrigins[id] = listScroll.contentView.bounds.minY }
        finishRowMotion()
        clearScrollPresentation()
        spaceScroll = SpaceScrollState()
        spaceIndex = index
        reload()
        layoutSubtreeIfNeeded()
        listScroll.move(to: spaceListOrigins[snapshot.spaces[index].id] ?? 0)
        revealSelection(animated: animatedReveal)
        refreshPointer()
        if notify { onShowSpace?(snapshot.spaces[index].id) }
    }

    public var urlFieldCheckFrame: NSRect { urlField.convert(urlField.bounds, to: nil) }
    public func clickURLForCheck() { urlField.performClick(nil) }
    public var urlHostForCheck: String { host.stringValue }
    @objc private func editURLClicked() { onEditURL?() }
    @objc private func copySelectedLink() {
        guard let url = selectedURL else { return }
        copyLink(url)
    }
    private var selectedURL: String? {
        guard let space = snapshotSpace, let selectedID else { return nil }
        let rows = space.favorites + space.pinned + space.today
        guard rows.contains(where: { $0.id == selectedID }) else { return nil }
        let member = snapshot.selectedId.flatMap { id in rows.first { $0.id == id } }
        guard let member, Self.sidebarSelection(snapshot) == selectedID else { return rows.first { $0.id == selectedID }?.url }
        return focusedPane?.id == member.id ? focusedPane?.url : member.url
    }
    private func copyLink(_ url: String) {
        pasteboard.clearContents()
        if pasteboard.setString(url, forType: .string) { onLinkCopied?() }
    }
    public func copySelectedLinkForCommand() { copySelectedLink() }
    @objc private func retryHistory() { onRetryHistory?() }
    @objc private func dismissHistory() { onDismissHistory?() }
    public func showHistoryFailure(_ visible: Bool) {
        guard historyBanner.isHidden != !visible else { return }
        historyBanner.isHidden = !visible
        if visible, let profile = snapshotSpace?.profileName,
           historySession?.claimHistoryFailureAnnouncement(profile: profile) == true {
            checkHistoryAnnouncement?("History could not be deleted.")
            NSAccessibility.post(element: historyBanner, notification: .announcementRequested, userInfo: [.announcement: "History could not be deleted.", .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }
    public func observeHistoryFailures(_ session: WorkspaceSession) {
        historySession = session
        if let profile = snapshotSpace?.profileName { showHistoryFailure(session.historyPurgeFailed(profile: profile)) }
        historyObserver = NotificationCenter.default.addObserver(forName: WorkspaceSession.historyPurgeChanged, object: nil, queue: .main) { [weak self, weak session] notification in
            guard let source = notification.object as? WorkspaceSession, source === session,
                  let profile = notification.userInfo?["profile"] as? String,
                  let visible = notification.userInfo?["visible"] as? Bool else { return }
            MainActor.assumeIsolated {
                guard let self, profile == self.snapshotSpace?.profileName else { return }
                self.showHistoryFailure(visible)
            }
        }
        onRetryHistory = { [weak session] in session?.retryHistoryPurges() }
        onDismissHistory = { [weak self, weak session] in
            guard let profile = self?.snapshotSpace?.profileName else { return }
            session?.dismissHistoryPurgeFailure(profile: profile)
        }
    }

    private func build() {
        wantsLayer = true
        layer?.masksToBounds = true
        library.onScroll = { [weak self] event, scroll in self?.handleSpaceScroll(event, from: scroll) ?? false }
        urlField.title = ""
        urlField.isBordered = false
        urlField.target = self
        urlField.action = #selector(editURLClicked)
        urlField.setAccessibilityLabel("Edit URL")
        urlField.wantsLayer = true
        urlField.layer?.cornerRadius = 11
        urlField.layer?.cornerCurve = .continuous
        host.font = .systemFont(ofSize: 13)
        host.lineBreakMode = .byTruncatingTail
        host.setAccessibilityElement(false)
        host.translatesAutoresizingMaskIntoConstraints = false
        urlField.addSubview(host)
        spaceNameRow.translatesAutoresizingMaskIntoConstraints = false
        spaceNameRow.menuProvider = { [weak self] in
            guard let self, let id = self.snapshotSpace?.id else { return nil }
            return self.spaceMenu(spaceID: id, anchor: self.spaceNameRow)
        }
        spaceNameRow.onToggle = { [weak self] in self?.toggleSection() }
        spaceNameRow.onRenameEnded = { [weak self] in self?.spaceRenameEnded() }
        copyLinkButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy Link")
        copyLinkButton.isBordered = false
        copyLinkButton.target = self
        copyLinkButton.action = #selector(copySelectedLink)
        copyLinkButton.setAccessibilityLabel("Copy Link")
        copyLinkButton.translatesAutoresizingMaskIntoConstraints = false
        urlField.addSubview(copyLinkButton)

        favorites.orientation = .vertical
        favorites.spacing = 8
        favorites.alignment = .leading

        rows.orientation = .vertical
        rows.spacing = 0
        rows.alignment = .width

        let scroll = listScroll
        scroll.onBoundsChanged = { [weak self] in
            guard let self else { return }
            self.refreshPointer()
            if self.drag?.active == true && !self.dragSettling { self.resolveDrag() }
        }
        scroll.onScroll = { [weak self, weak scroll] event in self?.handleSpaceScroll(event, from: scroll) ?? false }
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let document = FlippedView()
        document.addSubview(rows)
        scroll.documentView = document
        rows.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false


        spaceViewport.wantsLayer = true
        spaceViewport.layer?.masksToBounds = true
        spaceColumn.wantsLayer = true
        spaceColumn.orientation = .vertical
        spaceColumn.alignment = .leading
        spaceColumn.spacing = 0
        for view in [favorites, spaceNameRow, scroll] { spaceColumn.addArrangedSubview(view) }
        spaceColumn.setCustomSpacing(22, after: favorites)
        spaceColumn.translatesAutoresizingMaskIntoConstraints = false
        spaceViewport.addSubview(spaceColumn)

        dock.translatesAutoresizingMaskIntoConstraints = false
        let bottomBar = NSView()
        bottomBar.addSubview(dock)
        NSLayoutConstraint.activate([
            dock.topAnchor.constraint(equalTo: bottomBar.topAnchor), dock.bottomAnchor.constraint(equalTo: bottomBar.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: SidebarMetrics.libraryButtonSize),
        ])
        historyRetryButton.title = "Retry"
        historyRetryButton.target = self
        historyRetryButton.action = #selector(retryHistory)
        historyDismissButton.title = "Dismiss"
        historyDismissButton.target = self
        historyDismissButton.action = #selector(dismissHistory)
        historyBanner.orientation = .vertical
        historyBanner.alignment = .leading
        historyBanner.spacing = 4
        historyBanner.addArrangedSubview(historyMessage)
        historyBanner.addArrangedSubview(NSStackView(views: [historyRetryButton, historyDismissButton]))
        historyBanner.isHidden = true
        let column = NSStackView(views: [urlField, spaceViewport, historyBanner, bottomBar])
        mainColumn = column
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.setCustomSpacing(8, after: urlField)
        column.setCustomSpacing(10, after: spaceViewport)
        column.edgeInsets = NSEdgeInsets(top: 46, left: 8, bottom: 8, right: 8)
        addSubview(column)
        column.translatesAutoresizingMaskIntoConstraints = false
        favoritesHeight = favorites.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            urlField.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -16),
            bottomBar.widthAnchor.constraint(equalTo: urlField.widthAnchor),
            urlField.heightAnchor.constraint(equalToConstant: 36),
            host.leadingAnchor.constraint(equalTo: urlField.leadingAnchor, constant: 12),
            host.trailingAnchor.constraint(equalTo: copyLinkButton.leadingAnchor, constant: -4),
            copyLinkButton.trailingAnchor.constraint(equalTo: urlField.trailingAnchor, constant: -4),
            copyLinkButton.centerYAnchor.constraint(equalTo: urlField.centerYAnchor),
            copyLinkButton.widthAnchor.constraint(equalToConstant: 24),
            copyLinkButton.heightAnchor.constraint(equalToConstant: 24),
            host.centerYAnchor.constraint(equalTo: urlField.centerYAnchor),
            spaceViewport.widthAnchor.constraint(equalTo: urlField.widthAnchor),
            spaceColumn.leadingAnchor.constraint(equalTo: spaceViewport.leadingAnchor),
            spaceColumn.trailingAnchor.constraint(equalTo: spaceViewport.trailingAnchor),
            spaceColumn.topAnchor.constraint(equalTo: spaceViewport.topAnchor),
            spaceColumn.bottomAnchor.constraint(equalTo: spaceViewport.bottomAnchor),
            favorites.widthAnchor.constraint(equalTo: urlField.widthAnchor),
            favoritesHeight,
            spaceNameRow.widthAnchor.constraint(equalTo: urlField.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: urlField.widthAnchor),
            rows.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rows.topAnchor.constraint(equalTo: document.topAnchor),
            rows.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: rows.heightAnchor),
        ])
        library.isHidden = true
        library.update(archive: snapshot.archive)
        tooltip.capture(in: library)
        library.autoresizingMask = [.width, .height]
        library.onRestore = { [weak self] id in self?.onRestore?(id) }
        library.onDelete = { [weak self] id in self?.onArchiveDelete?(id) }
        library.onExit = { [weak self] in self?.setLibraryOpen(false) }
        libraryButton.image = NSImage(systemSymbolName: "books.vertical", accessibilityDescription: "Library")?.withSymbolConfiguration(.init(pointSize: SidebarMetrics.libraryIconSize, weight: .regular))
        libraryButton.imagePosition = .imageOnly
        libraryButton.isBordered = false
        libraryButton.wantsLayer = true
        libraryFill.cornerRadius = 6
        libraryButton.layer?.insertSublayer(libraryFill, at: 0)
        libraryButton.target = self
        libraryButton.action = #selector(libraryButtonClicked(_:))
        libraryButton.toolTip = "Library"
        libraryButton.setAccessibilityLabel("Library")
        libraryButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(libraryButton)
        NSLayoutConstraint.activate([
            libraryButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SidebarMetrics.libraryButtonLeading),
            libraryButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -SidebarMetrics.libraryButtonBottom),
            libraryButton.widthAnchor.constraint(equalToConstant: SidebarMetrics.libraryButtonSize),
            libraryButton.heightAnchor.constraint(equalToConstant: SidebarMetrics.libraryButtonSize),
        ])
        creation.autoresizingMask = [.width, .height]
        creation.onCreate = { [weak self] name in self?.onCreateSpace?(name) }
        creation.onCancel = { [weak self] in self?.setCreateSpaceOpen(false) }
        creation.active = false
        newSpaceMenu.delegate = self
        let newFolder = newSpaceMenu.addItem(withTitle: "New Folder", action: #selector(newFolder(_:)), keyEquivalent: "")
        newFolder.target = self
        let newSpace = newSpaceMenu.addItem(withTitle: "New Space", action: #selector(showCreateSpace(_:)), keyEquivalent: "")
        newSpace.target = self
        newSpaceMenu.removeItem(newSpace)
        newSpaceMenu.insertItem(newSpace, at: 0)
        plusButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Space")?.withSymbolConfiguration(.init(pointSize: SidebarMetrics.libraryIconSize, weight: .regular))
        plusButton.imagePosition = .imageOnly
        plusButton.isBordered = false
        plusButton.target = self
        plusButton.action = #selector(showNewSpaceMenu(_:))
        plusButton.toolTip = "New Space"
        plusButton.setAccessibilityLabel("New Space menu")
        plusButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(plusButton)
        NSLayoutConstraint.activate([
            plusButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SidebarMetrics.createSpacePlusTrailing),
            plusButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -SidebarMetrics.libraryButtonBottom),
            plusButton.widthAnchor.constraint(equalToConstant: SidebarMetrics.libraryButtonSize),
            plusButton.heightAnchor.constraint(equalToConstant: SidebarMetrics.libraryButtonSize),
            dock.leadingAnchor.constraint(equalTo: libraryButton.trailingAnchor),
            dock.trailingAnchor.constraint(equalTo: plusButton.leadingAnchor),
        ])
        updateFill()
        addSubview(pullIndicator)
    }

    isolated deinit {
        if let historyObserver { NotificationCenter.default.removeObserver(historyObserver) }
        if let clickMonitor { removeClickMonitor(clickMonitor) }
        tooltip.dismiss()
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scrollGestureActive = false
        cancelMomentumQuiet()
        if window == nil, drag != nil {
            dragTimer?.invalidate()
            dragTimer = nil
            dropIndicator.removeFromSuperlayer()
            dragFavoriteIndex = nil
            finishDrag()
        }
        if let clickMonitor { removeClickMonitor(clickMonitor); self.clickMonitor = nil }
        tooltip.dismiss()
        guard window != nil && !isScrollPreview else {
            lookSampling?.invalidate()
            lookSampling = nil
            return
        }
        tooltip.capture(in: self)
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .flagsChanged]) { [weak self] event in
            MainActor.assumeIsolated {
                if event.window === self?.window {
                    if event.type == .flagsChanged { self?.tooltip.flagsChanged(with: event) }
                    else { self?.tooltip.dismiss() }
                }
            }
            return event
        }
    }

    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override public func mouseMoved(with event: NSEvent) { refreshPointer() }
    override public func mouseEntered(with event: NSEvent) { refreshPointer() }
    override public func mouseExited(with event: NSEvent) { tooltip.update(target: nil, point: nil) }

    func refreshPointer() {
        guard drag?.active != true && !dragSettling else { tooltip.dismiss(); return }
        for row in rowViews.values { row.refreshHover() }
        let point = window?.isKeyWindow == true ? window?.mouseLocationOutsideOfEventStream : nil
        let hit = point.flatMap { point in
            guard let root = window?.contentView else { return nil as NSView? }
            return root.hitTest(root.superview?.convert(point, from: nil) ?? point)
        }
        tooltip.update(target: tooltipTarget(for: hit), point: point)
    }

    func tooltipTarget(for hit: NSView?) -> NSView? {
        guard let hit else { return nil }
        let target = tooltip.target(at: hit)
        guard let id = renamingID else { return target }
        return target === rowViews[id] || target === favoriteTiles[id] ? nil : target
    }

    override public func layout() {
        super.layout()
        library.frame = bounds
        libraryFill.frame = CGRect(x: 0, y: (libraryButton.bounds.height - 24) / 2, width: libraryButton.bounds.width, height: 24)
        creation.frame = bounds
        pullIndicator.frame = bounds
        dock.layoutSubtreeIfNeeded()
        if bounds.width != laidOutSidebarWidth {
            finishRowMotion()
            if showingScrollPages { spaceScroll.cancelGesture() }
            clearScrollPresentation()
            laidOutSidebarWidth = bounds.width
        }
        let columns = SidebarDragMetrics.favoriteColumns(width: bounds.width - 16, slots: 4)
        if columns != favoriteColumns {
            favoriteColumns = columns
            reloadFavorites()
        }
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill()
        updateDockSelection()
    }

    private func updateFill() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            urlField.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        }
    }

    private func reload() {
        defer { refreshLook() }
        let space = snapshotSpace
        if let session = historySession, let profile = space?.profileName { showHistoryFailure(session.historyPurgeFailed(profile: profile)) }
        if space?.id != hintSpaceID {
            rowViews.values.forEach { $0.hideRenameHint() }
            hintSpaceID = space?.id
        }
        lookSettings?.update(snapshot: snapshot)
        spaceNameRow.space = space
        let pinned = space?.pinned ?? []
        let today = space?.today ?? []
        let selected = ((space?.favorites ?? []) + pinned + today).first { $0.id == selectedID }
        let url = selected == nil ? nil : selectedURL
        copyLinkButton.isEnabled = url != nil
        host.stringValue = url.flatMap { URL(string: $0)?.host } ?? ""
        urlField.setAccessibilityValue(host.stringValue)

        reloadFavorites()

        let allRows = pinned + today
        let splitIDs = Set(allRows.filter { $0.kind == .split }.map(\.id))
        let hidden = Set(allRows.filter { row in
            var parent = row.parentId
            while let ancestor = allRows.first(where: { $0.id == parent }) {
                if splitIDs.contains(ancestor.id) { return true }
                parent = ancestor.parentId
            }
            return false
        }.map(\.id))
        let ids = Set(allRows.map(\.id)).subtracting(hidden)
        for id in Array(rowViews.keys) where !ids.contains(id) { removeRow(id: id) }
        for id in Array(noTabsRows.keys) where !ids.contains(id) {
            noTabsRows.removeValue(forKey: id)?.removeFromSuperview()
        }
        var ordered: [NSView] = pinned.filter { !hidden.contains($0.id) }.map { listView(for: $0) }
        if today.isEmpty {
            todayDivider.removeFromSuperview()
        } else {
            if todayDivider.superview == nil {
                todayDivider.onClear = { [weak self] in self?.onClearToday?() }
            }
            ordered.append(todayDivider)
        }
        if newTabRowShown {
            ordered.append(newTabRow)
        } else {
            newTabRow.removeFromSuperview()
        }
        ordered.append(contentsOf: today.filter { !hidden.contains($0.id) }.map { listView(for: $0) })
        arrange(ordered, in: rows)

        if dock.subviews.compactMap({ ($0 as? SpaceDockButton)?.spaceID }) != snapshot.spaces.map(\.id) {
            dockLookPopover.performClose(nil)
            dock.subviews.forEach { $0.removeFromSuperview() }
            for space in snapshot.spaces {
                let button = SpaceDockButton(title: "", target: self, action: #selector(dockClicked(_:)))
                button.spaceID = space.id
                button.isBordered = false
                button.menuProvider = { [weak self] in self?.spaceMenu(spaceID: space.id) }
                dock.addSubview(button)
            }
        }
        for (index, space) in snapshot.spaces.enumerated() {
            let button = dock.subviews[index] as! SpaceDockButton
            button.title = space.icon ?? String(space.title.prefix(1))
            button.tag = index
            button.toolTip = space.title
            button.setAccessibilityLabel(space.title)
            button.setAccessibilityHelp(space.title)
            button.font = .systemFont(ofSize: 15, weight: index == spaceIndex ? .bold : .regular)
        }
        dock.selectedIndex = spaceIndex
        updateDockSelection()
        dock.layoutSubtreeIfNeeded()
        tooltip.capture(in: self)
    }

    private func reloadFavorites() {
        var models: [Row?] = (snapshotSpace?.favorites ?? []).map { $0 }
        if let index = dragFavoriteIndex, let drag {
            models.removeAll { $0?.id == drag.row.id }
            models.insert(nil, at: min(index, models.count))
        }
        let ids = Set(models.compactMap { $0?.id })
        let focused = window?.firstResponder as? FavoriteTile
        for id in Array(favoriteTiles.keys) where !ids.contains(id) {
            favoriteTiles.removeValue(forKey: id)?.removeFromSuperview()
        }
        let columns = SidebarDragMetrics.favoriteColumns(width: bounds.width - 16, slots: dragFavoriteIndex == nil ? 4 : models.count)
        let lineCount = (models.count + columns - 1) / columns
        favoritesHeight.constant = CGFloat(lineCount * 47 + max(0, lineCount - 1) * 8)
        spaceColumn.setCustomSpacing(models.isEmpty ? 0 : 22, after: favorites)
        var lines = favorites.arrangedSubviews.compactMap { $0 as? NSStackView }
        while lines.count < lineCount {
            let line = NSStackView()
            line.distribution = .fillEqually
            line.spacing = 8
            favorites.addArrangedSubview(line)
            NSLayoutConstraint.activate([
                line.heightAnchor.constraint(equalToConstant: 47),
                line.widthAnchor.constraint(equalTo: favorites.widthAnchor),
            ])
            lines.append(line)
        }
        for index in 0..<lineCount {
            let line = lines[index]
            line.arrangedSubviews.filter { !($0 is FavoriteTile) }.forEach { $0.removeFromSuperview() }
            let start = index * columns
            var tiles: [NSView] = models[start..<min(start + columns, models.count)].map { row in
                guard let row else { return NSView() }
                let tile = favoriteTiles[row.id] ?? FavoriteTile(row: row) { [weak self] row in self?.select(row) }
                favoriteTiles[row.id] = tile
                wireDrag(tile)
                tile.menuProvider = { [weak self, weak tile] in
                    guard let self, !self.isScrollPreview, let tile else { return nil }
                    return self.favoriteMenu(row: tile.row)
                }
                tile.update(row: row)
                tile.refusesFirstResponder = isScrollPreview
                return tile
            }
            while tiles.count < columns { tiles.append(NSView()) }
            arrange(tiles, in: line)
        }
        lines.dropFirst(lineCount).forEach { $0.removeFromSuperview() }
        if let focused, favoriteTiles[focused.row.id] === focused, window?.firstResponder !== focused {
            window?.makeFirstResponder(focused)
        }
        tooltip.capture(in: favorites)
    }

    private func rowView(for row: Row) -> SidebarRowView {
        let view: SidebarRowView
        if let existing = rowViews[row.id] {
            view = existing
        } else {
            view = SidebarRowView(row: row, selected: row.id == selectedID) { [weak self] row in self?.select(row) }
            rowViews[row.id] = view
            rows.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
        view.hintClock = { [weak self] in self?.renameHintClock() ?? CACurrentMediaTime() }
        view.hintReduceMotion = { [weak self] in self?.dragReduceMotion() ?? true }
        wireDrag(view)
        view.menuProvider = { [weak self, weak view] in
            guard let self, let row = view?.row else { return nil }
            return row.kind == .folder ? self.folderMenu(row: row) : row.kind == .tab ? (view?.pinned == true ? self.pinnedMenu(row: row) : self.todayMenu(row: row)) : nil
        }
        view.onRename = { [weak self] row in self?.beginRename(id: row.id) }
        view.onRenameCommit = { [weak self] row, title, done in self?.commitRename(row: row, title: title, completion: done) }
        view.onRenameEnd = { [weak self] in
            guard let self, self.renamingID == row.id else { return }
            self.renamingID = nil; self.notifyAutoArchiveReady()
        }
        view.pinned = snapshotSpace?.pinned.contains { $0.id == row.id } == true
        view.onClose = { [weak self] id in
            guard let self, let target = self.closeTarget(for: id) else { return }
            // R1/D2: the button showed Close (a loaded pin’s −) or Archive; it passes that and the
            // id it showed, so a stale click cannot be upgraded in the queue.
            if target.action == .archive { self.onArchive?(target.id) } else { self.onClose?(target.id) }
        }
        view.onMute = { [weak self] id, muted in self?.onMute?(id, muted) }
        view.status = rowStates[row.id]
        view.closeCaps = closeCaps
        view.update(row: row, selected: row.id == selectedID)
        view.crashed = crashedItems.contains(row.id)
        view.unread = unreadItems.contains(row.id)
        if row.kind == .split {
            let all = (snapshotSpace?.pinned ?? []) + (snapshotSpace?.today ?? [])
            func leaves(_ id: String) -> [Row] {
                all.filter { $0.parentId == id }.flatMap { $0.kind == .split ? leaves($0.id) : ($0.kind == .tab ? [$0] : []) }
            }
            view.updateSegments(leaves(row.id), active: snapshot.selectedId, crashed: crashedItems)
        } else { view.updateSegments([], active: nil) }
        view.acceptsKeyboardFocus = !isScrollPreview
        return view
    }

    // F3: the open, empty folder's line. It is not in rowViews: nothing selects, renames or
    // drags it; SidebarDrag resolves a drop on it into the folder it names.
    private func noTabsView(for row: Row) -> SidebarNoTabsRow {
        if let existing = noTabsRows[row.id], existing.row.parentId == row.parentId { return existing }
        noTabsRows.removeValue(forKey: row.id)?.removeFromSuperview()
        let view = SidebarNoTabsRow(row: row)
        view.translatesAutoresizingMaskIntoConstraints = false
        noTabsRows[row.id] = view
        return view
    }

    private func applyRowStatus() {
        for (id, view) in rowViews {
            view.status = rowStates[id]
            view.crashed = crashedItems.contains(id)
            view.unread = unreadItems.contains(id)
        }
    }

    // The row the core says is a folder's empty line is drawn by its own view, so the rows
    // stack needs that view instead of a SidebarRowView.
    private func listView(for row: Row) -> NSView {
        row.kind == .noTabs ? noTabsView(for: row) : rowView(for: row)
    }

    private func removeRow(id: String) {
        if let retired = retiringRows.removeValue(forKey: id) {
            retired.layer?.removeAnimation(forKey: "row.close.fade")
            retired.removeFromSuperview()
            return
        }
        guard let view = rowViews.removeValue(forKey: id) else { return }
        guard let fadeFrame, fadeFrame.id == id else { view.removeFromSuperview(); return }
        rows.removeArrangedSubview(view)
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = true
        addSubview(view)
        view.frame = fadeFrame.frame
        view.acceptsKeyboardFocus = false
        view.setAccessibilityHidden(true)
        retiringRows[id] = view
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak view] in
            Task { @MainActor in
                guard let self, let view, self.retiringRows[id] === view else { return }
                self.removeRow(id: id)
            }
        }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = 0
        animation.duration = SidebarMetrics.rowCloseFadeDuration
        animation.timingFunction = SidebarMetrics.easeOutCubic
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        view.layer?.add(animation, forKey: "row.close.fade")
        CATransaction.commit()
    }

    private func arrange(_ views: [NSView], in stack: NSStackView) {
        for (index, view) in views.enumerated() {
            if index >= stack.arrangedSubviews.count || stack.arrangedSubviews[index] !== view {
                stack.insertArrangedSubview(view, at: index)
            }
        }
    }

    private func select(_ row: Row) {
        if row.kind == .noTabs { return }
        if row.kind == .folder {
            performEdit(.collapse(id: row.id, collapsed: !row.collapsed))
            return
        }
        snapshot.selectedId = row.id
        selectedID = Self.sidebarSelection(snapshot)
        reload()
        revealSelection()
        onSelect?(row)
    }

    // Why not close a member: the split is one row and ⌘W closes the split in the adapter.
    public enum RowCloseAction { case close, archive }

    public func closeTarget(for id: String) -> (id: String, action: RowCloseAction)? {
        guard let space = snapshotSpace,
              let row = (space.today + space.pinned + space.favorites).first(where: { $0.id == id }) else { return nil }
        return (id, rowCloseArchives(row, in: space) ? .archive : .close)
    }

    public func revealSelection(animated: Bool = true) {
        guard let id = selectedID, let row = rowViews[id] else { return }
        layoutSubtreeIfNeeded()
        listScroll.reveal(listScroll.documentView!.convert(row.bounds, from: row), animated: animated)
    }

    @objc private func dockClicked(_ sender: NSButton) {
        setLibraryOpen(false)
        setCreateSpaceOpen(false)
        showSpace(at: sender.tag)
    }

    override public func scrollWheel(with event: NSEvent) {
        if !handleSpaceScroll(event) { super.scrollWheel(with: event) }
    }

    override public func hitTest(_ point: NSPoint) -> NSView? {
        isScrollPreview ? nil : super.hitTest(point)
    }

    override public func accessibilityChildren() -> [Any]? {
        isScrollPreview ? [] : super.accessibilityChildren()
    }

    private func handleSpaceScroll(_ event: NSEvent, from source: NSScrollView? = nil) -> Bool {
        guard !isScrollPreview else { return false }
        defer {
            if !event.momentumPhase.isEmpty {
                if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
                    cancelMomentumQuiet()
                    notifyAutoArchiveReady()
                } else {
                    cancelMomentumQuiet()
                }
            } else if event.phase.contains(.ended) {
                armMomentumQuiet()
            } else if event.phase.contains(.cancelled) {
                cancelMomentumQuiet()
                notifyAutoArchiveReady()
            } else {
                cancelMomentumQuiet()
            }
        }
        lastScrollEventAt = pullClock()
        if !event.momentumPhase.isEmpty {
            scrollGestureActive = !event.momentumPhase.contains(.ended)
        } else if !event.phase.isEmpty {
            scrollGestureActive = !event.phase.contains(.ended) && !event.phase.contains(.cancelled)
        }
        layoutSubtreeIfNeeded()
        let phase: SpaceScrollEvent.Phase
        if event.phase.contains(.began) { phase = .began }
        else if event.phase.contains(.ended) { phase = .ended }
        else if event.phase.contains(.cancelled) { phase = .cancelled }
        else if event.phase.contains(.mayBegin) { phase = .mayBegin }
        else if event.phase.isEmpty { phase = .none }
        else { phase = .changed }
        let input = SpaceScrollEvent(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY, phase: phase,
                                     momentum: !event.momentumPhase.isEmpty,
                                     inverted: event.isDirectionInvertedFromDevice, time: event.timestamp)
        if input.kind == .wheel && wheelPullPlaying { return true }
        let origin: ScrollOrigin = libraryOpen ? (library.isOverRail(event) ? .rail : .list) : .page
        if phase == .began {
            scrollOrigin = origin
            scrollAxis = nil
            gestureScroll = source
        }
        let owner = input.kind == .wheel ? origin : (scrollOrigin ?? origin)
        let axis: ScrollAxis?
        if input.kind == .wheel {
            axis = abs(input.dx) > abs(input.dy) ? .horizontal : .vertical
        } else {
            if scrollAxis == nil && (input.dx != 0 || input.dy != 0) {
                scrollAxis = abs(input.dx) > abs(input.dy) ? .horizontal : .vertical
            }
            axis = scrollAxis
        }
        if (drag != nil || dragSettling) && axis != .vertical { return true }
        if owner == .list || axis == .vertical {
            if axis == .horizontal { return true }
            if input.kind == .trackpad, let scroll = gestureScroll, scroll !== source {
                scroll.scrollWheel(with: event)
                return true
            }
            return false
        }
        let layer = libraryOpen ? library.layer : createSpaceOpen ? creation.layer : spaceColumn.layer
        let offset = layer?.animation(forKey: "space.scroll") == nil
            ? layer?.transform.m41 : (layer?.presentation()?.transform.m41 ?? layer?.transform.m41)
        let logicalIndex = scrollPageIndex
        let action = spaceScroll.handle(input, index: logicalIndex, count: snapshot.spaces.count,
                                        pitch: spacePagePitch, presentationOffset: Double(offset ?? 0))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        switch action {
        case .vertical: return false
        case .ignored: return true
        case .pull:
            playWheelPull(from: Double(offset ?? 0))
        case .follow(let offset):
            lookSampling?.invalidate()
            lookSampling = nil
            listScroll.stopReveal()
            stopPullAnimation()
            scrollGeneration += 1
            for (view, _) in scrollPages { view.layer?.removeAnimation(forKey: "space.scroll") }
            prepareScrollPages(offset: offset)
            refreshLook(offset: offset)
            updateDockSelection(offset: offset)
            for (view, origin) in scrollPages { view.layer?.transform = CATransform3DMakeTranslation(origin + offset, 0, 0) }
            pullIndicator.update(excess: spaceScroll.followedExcess)
        case .settle(let index, let offset, let switched):
            if index == snapshot.spaces.count && switched {
                openCreationAfterPull()
                return true
            }
            let excess = pullIndicator.excess
            let from = offset + Double(index - logicalIndex) * spacePagePitch
            if switched {
                if index == -1 { setLibraryOpen(true, scrolling: true) }
                else { setLibraryOpen(false, scrolling: true); setCreateSpaceOpen(false, scrolling: true); scrollToSpace(at: index) }
            }
            prepareScrollPages(offset: from, departingIndex: logicalIndex)
            settleScroll(from: from, switched: switched)
            if excess > 0 { returnPullIndicator(excess: excess) }
        }
        return true
    }

    private var libraryPageOrigin: Double { Double(-1 - scrollPageIndex) * spacePagePitch }

    private var scrollPages: [(NSView, Double)] {
        [(spaceColumn, Double(spaceIndex - scrollPageIndex) * spacePagePitch), (library, libraryPageOrigin),
         (creation, Double(snapshot.spaces.count - scrollPageIndex) * spacePagePitch)] + scrollPreviews.compactMap { preview in
            preview.superview.map { ($0, Double(preview.spaceIndex - scrollPageIndex) * spacePagePitch) }
        }
    }

    private func scrollToSpace(at index: Int) {
        let decision = spaceScroll
        showSpace(at: index, animatedReveal: false)
        spaceScroll = decision
    }

    private func prepareScrollPages(offset: Double, departingIndex: Int? = nil) {
        guard !spaceViewport.bounds.isEmpty, spacePagePitch > 0 else { return }
        let libraryX = libraryPageOrigin + offset
        if !libraryOpen && libraryX > -spacePagePitch && libraryX < spacePagePitch {
            if library.isHidden || library.superview == nil { libraryLookSpaceID = snapshotSpace?.id }
            if library.superview == nil { addSubview(library, positioned: .below, relativeTo: libraryButton); library.frame = bounds }
            library.isHidden = false
            library.update(archive: snapshot.archive)
            tooltip.capture(in: library)
        }
        if (libraryOpen && offset < 0) || (createSpaceOpen && offset > 0) { mainColumn.isHidden = false }
        let center = min(snapshot.spaces.count - 1, max(0, spaceIndex - Int((offset / spacePagePitch).rounded())))
        let indices = Set((center - 1...center + 1).filter { snapshot.spaces.indices.contains($0) && $0 != spaceIndex })
        guard !showingScrollPages || Set(scrollPreviews.map(\.spaceIndex)) != indices else { return }
        showingScrollPages = true
        layoutSubtreeIfNeeded()
        for preview in scrollPreviews where !indices.contains(preview.spaceIndex) { preview.superview?.removeFromSuperview() }
        scrollPreviews.removeAll { !indices.contains($0.spaceIndex) }
        for index in indices.sorted() {
            guard !scrollPreviews.contains(where: { $0.spaceIndex == index }) else { continue }
            let preview = SidebarView(snapshot: snapshot)
            preview.isScrollPreview = true
            preview.spaceListOrigins = spaceListOrigins
            preview.selectedID = selectedID
            preview.showSpace(at: index, animatedReveal: false)
            preview.wantsLayer = true
            preview.setAccessibilityHidden(true)
            let page = NSView(frame: spaceViewport.bounds)
            page.wantsLayer = true
            page.layer?.masksToBounds = true
            page.setAccessibilityHidden(true)
            preview.frame = spaceViewport.convert(bounds, from: self)
            page.addSubview(preview)
            spaceViewport.addSubview(page, positioned: .below, relativeTo: spaceColumn)
            preview.layoutSubtreeIfNeeded()
            preview.listScroll.move(to: spaceListOrigins[snapshot.spaces[index].id] ?? 0)
            if index != departingIndex { preview.revealSelection(animated: false) }
            var descendants = preview.subviews
            while let view = descendants.popLast() {
                (view as? NSControl)?.refusesFirstResponder = true
                (view as? SidebarRowView)?.acceptsKeyboardFocus = false
                descendants.append(contentsOf: view.subviews)
            }
            scrollPreviews.append(preview)
        }
        // Don't translate fresh backing layers before AppKit synchronizes their view geometry.
        window?.displayIfNeeded()
    }

    func refreshLook(offset: Double = 0) {
        guard let onLookChanged else { return }
        let position = Double(scrollPageIndex) - (spacePagePitch > 0 ? offset / spacePagePitch : 0)
        let lower = Int(floor(position))
        func look(at index: Int) -> Look? {
            if snapshot.spaces.indices.contains(index) { return snapshot.spaces[index].look }
            let id = index < 0 ? libraryLookSpaceID : creationLookSpaceID
            return (snapshot.spaces.first { $0.id == id } ?? snapshotSpace)?.look
        }
        let fraction = position - Double(lower)
        onLookChanged(look(at: lower), look(at: fraction == 0 ? lower : lower + 1), fraction)
    }

    func updateDockSelection(offset: Double = 0) {
        let position = CGFloat(scrollPageIndex) - (spacePagePitch > 0 ? CGFloat(offset / spacePagePitch) : 0)
        dock.selectionPosition = position
        let fraction = max(0, 1 - abs(position + 1))
        libraryOpenFraction = fraction
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            libraryFill.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(SpaceDockButton.fillAlpha(fraction: fraction, appearance: effectiveAppearance)).cgColor
        }
    }

    private var pageView: NSView { libraryOpen ? library : createSpaceOpen ? creation : spaceColumn }

    private var pagePresentationOffset: Double {
        Double(pageView.layer?.presentation()?.transform.m41 ?? pageView.layer?.transform.m41 ?? 0)
    }

    @objc private func sampleLook() {
        let offset = pagePresentationOffset
        refreshLook(offset: offset)
        updateDockSelection(offset: offset)
    }

    // Check hook: the sampler above runs from a display link, which delivers no callbacks on a VM
    // display, so the dock screen check pumps the same sampler from its own timer. Returns the
    // offset just read, so a failed run shows whether presentation frames existed at all.
    @discardableResult
    public func dockCheckSampleLook() -> Double {
        guard CommandLine.arguments.contains("--ararat-screen=dock") else { return 0 }
        let offset = pagePresentationOffset
        sampleLook()
        return offset
    }

    // Check hook: the page slide's layer state, so an offset of 0 in the trace can be told apart —
    // no animation at all is a paging fault, an animation whose presentation stays 0 means this
    // display presents no frames.
    public var dockCheckScrollState: [String: Any] {
        guard CommandLine.arguments.contains("--ararat-screen=dock") else { return [:] }
        let layer = pageView.layer
        var state: [String: Any] = ["animation": layer?.animation(forKey: "space.scroll") != nil,
                                    "model": Double(layer?.transform.m41 ?? 0)]
        if let presentation = layer?.presentation() { state["presentation"] = Double(presentation.transform.m41) }
        return state
    }

    private func settleScroll(from offset: Double, switched: Bool) {
        refreshLook(offset: offset)
        updateDockSelection(offset: offset)
        lookSampling?.invalidate()
        if window != nil {
            lookSampling = displayLink(target: self, selector: #selector(sampleLook))
            lookSampling?.add(to: .main, forMode: .common)
        }
        scrollGeneration += 1
        let response = switched ? SidebarMetrics.spaceSwitchResponse : SidebarMetrics.spaceReturnResponse
        let damping = switched ? SidebarMetrics.spaceSwitchDamping : SidebarMetrics.spaceReturnDamping
        let omega = 2 * CGFloat.pi / response
        let generation = scrollGeneration
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor in
                guard let self, self.scrollGeneration == generation else { return }
                self.finishScrollPresentation()
            }
        }
        for (view, origin) in scrollPages {
            let spring = CASpringAnimation(keyPath: "transform.translation.x")
            spring.mass = 1
            spring.stiffness = omega * omega
            spring.damping = 2 * damping * omega
            spring.duration = spring.settlingDuration
            spring.fillMode = .forwards
            spring.isRemovedOnCompletion = false
            spring.fromValue = origin + offset
            spring.toValue = origin
            view.layer?.transform = CATransform3DMakeTranslation(origin, 0, 0)
            view.layer?.add(spring, forKey: "space.scroll")
        }
        CATransaction.commit()
    }

    func finishScrollPresentation() {
        clearScrollPresentation()
        libraryDidLand()
        refreshPointer()
        notifyAutoArchiveReady()
    }

    private func clearScrollPresentation() {
        lookSampling?.invalidate()
        lookSampling = nil
        refreshLook()
        updateDockSelection()
        stopPullAnimation()
        pullIndicator.update(excess: 0)
        scrollGeneration += 1
        for (view, _) in scrollPages {
            view.layer?.removeAnimation(forKey: "space.scroll")
            view.layer?.transform = CATransform3DIdentity
        }
        scrollPreviews.forEach { $0.superview?.removeFromSuperview() }
        scrollPreviews.removeAll()
        showingScrollPages = false
        library.isHidden = !libraryOpen
        if !libraryOpen { library.removeFromSuperview() }
        creation.isHidden = !createSpaceOpen
        if !createSpaceOpen { creation.removeFromSuperview() }
        creation.layer?.transform = CATransform3DIdentity
        mainColumn.isHidden = libraryOpen || createSpaceOpen
        library.layer?.transform = CATransform3DIdentity
    }

    private func stopPullAnimation() {
        pullTimer?.invalidate()
        pullTimer = nil
        pullStep = nil
        wheelPullPlaying = false
    }

    private func animatePull(duration: Double, frame: @escaping @MainActor (Double) -> Void,
                             completion: @escaping @MainActor () -> Void) {
        stopPullAnimation()
        let start = pullClock()
        pullStep = { [weak self] in
            guard let self else { return }
            let elapsed = min(duration, self.pullClock() - start)
            frame(elapsed)
            if elapsed >= duration {
                self.stopPullAnimation()
                completion()
                self.notifyAutoArchiveReady()
            }
        }
        let timer = Timer(timeInterval: 1 / 120, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated { self.stepPull() }
        }
        pullTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stepPull() { pullStep?() }

    private func pullSpring(switched: Bool) -> CASpringAnimation {
        let spring = CASpringAnimation()
        let omega = 2 * Double.pi / (switched ? SidebarMetrics.spaceSwitchResponse : SidebarMetrics.spaceReturnResponse)
        spring.mass = 1
        spring.stiffness = omega * omega
        spring.damping = 2 * (switched ? SidebarMetrics.spaceSwitchDamping : SidebarMetrics.spaceReturnDamping) * omega
        return spring
    }

    private func springProgress(_ time: Double, spring: CASpringAnimation) -> Double {
        let omega = sqrt(spring.stiffness)
        let decay = spring.damping / 2
        let frequency = sqrt(omega * omega - decay * decay)
        return 1 - exp(-decay * time) * (cos(frequency * time) + decay / frequency * sin(frequency * time))
    }

    private func playWheelPull(from offset: Double) {
        let spring = pullSpring(switched: true)
        scrollGeneration += 1
        for (view, _) in scrollPages { view.layer?.removeAnimation(forKey: "space.scroll") }
        prepareScrollPages(offset: offset)
        animatePull(duration: spring.settlingDuration, frame: { [weak self] time in
            guard let self else { return }
            let raw = offset + (-SidebarMetrics.spaceCreateThreshold - offset) * self.springProgress(time, spring: spring)
            let followed = min(0, raw)
            let position = raw < 0 ? SpaceScrollState.rubberBand(raw) : raw
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.refreshLook(offset: position)
            for (view, origin) in self.scrollPages { view.layer?.transform = CATransform3DMakeTranslation(origin + position, 0, 0) }
            self.pullIndicator.update(excess: -followed)
            CATransaction.commit()
        }, completion: { [weak self] in
            self?.pullIndicator.update(excess: SidebarMetrics.spaceCreateThreshold)
            self?.openCreationAfterPull()
        })
        wheelPullPlaying = true
    }

    private func returnPullIndicator(excess: Double) {
        let spring = pullSpring(switched: false)
        let offset = abs(SpaceScrollState.rubberBand(excess))
        animatePull(duration: spring.settlingDuration, frame: { [weak self] time in
            guard let self else { return }
            let shown = max(0, offset * (1 - self.springProgress(time, spring: spring)))
            let raw = shown / (SidebarMetrics.spaceRubberCoefficient * (1 - shown / SidebarMetrics.spaceRubberDistance))
            self.pullIndicator.update(excess: raw)
        }, completion: { [weak self] in self?.pullIndicator.update(excess: 0) })
    }

    private func openCreationAfterPull() {
        let excess = max(SidebarMetrics.spaceCreateThreshold, pullIndicator.excess)
        clearScrollPresentation()
        setCreateSpaceOpen(true, scrolling: true)
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        pullIndicator.update(excess: excess)
        animatePull(duration: SidebarMetrics.spaceCreateExitDuration, frame: { [weak self] time in
            self?.pullIndicator.update(excess: excess, exit: 48 * time / SidebarMetrics.spaceCreateExitDuration)
        }, completion: { [weak self] in self?.pullIndicator.update(excess: 0) })
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

extension SidebarView {
    private func wireDrag(_ view: SidebarRowView) {
        guard !isScrollPreview else { return }
        view.onDragPress = { [weak self, weak view] row, point in self?.pressDrag(row: row, view: view, windowPoint: point) }
        view.onDragMove = { [weak self] point in self?.moveDrag(to: self?.dragPoint(point) ?? .zero) }
        view.onDragRelease = { [weak self] point in self?.releaseDrag(at: self?.dragPoint(point) ?? .zero) ?? false }
    }

    private func wireDrag(_ view: FavoriteTile) {
        guard !isScrollPreview else { return }
        view.onDragPress = { [weak self, weak view] row, point in self?.pressDrag(row: row, view: view, windowPoint: point) }
        view.onDragMove = { [weak self] point in self?.moveDrag(to: self?.dragPoint(point) ?? .zero) }
        view.onDragRelease = { [weak self] point in self?.releaseDrag(at: self?.dragPoint(point) ?? .zero) ?? false }
    }

    private func dragPoint(_ point: CGPoint) -> CGPoint {
        let local = convert(point, from: nil)
        return CGPoint(x: local.x, y: bounds.height - local.y)
    }

    private func dragRect(_ view: NSView) -> CGRect {
        let rect = convert(view.bounds, from: view)
        return CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    private func nativeDragRect(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    private func pressDrag(row: Row, view: NSView?, windowPoint: CGPoint) {
        guard let view, drag == nil, !dragSettling, !libraryOpen, !createSpaceOpen else { return }
        window?.makeFirstResponder(self)
        tooltip.dismiss()
        guard row.kind != .folder, row.kind != .noTabs else { return }
        finishRowMotion()
        clearScrollPresentation()
        var item = row
        let models = (snapshotSpace?.pinned ?? []) + (snapshotSpace?.today ?? [])
        var parent = models.first { $0.id == item.parentId }
        while let ancestor = parent {
            if ancestor.kind == .split { item = ancestor }
            parent = models.first { $0.id == ancestor.parentId }
        }
        let source = rowViews[item.id] ?? view
        let point = dragPoint(windowPoint)
        drag = SidebarDragState(row: item, origin: point, originFrame: dragRect(source), position: point)
        if row.kind != .folder { select(row); listScroll.stopReveal() }
    }

    func moveDrag(to position: CGPoint) {
        guard var state = drag, !dragSettling else { return }
        state.position = position
        if !state.active && hypot(position.x - state.origin.x, position.y - state.origin.y) >= SidebarDragMetrics.threshold {
            state.active = true
            let copy = SidebarRowView(row: state.row, selected: true) { _ in }
            copy.dragCopy = true
            copy.acceptsKeyboardFocus = false
            copy.setAccessibilityHidden(true)
            copy.translatesAutoresizingMaskIntoConstraints = true
            copy.frame = nativeDragRect(state.originFrame)
            addSubview(copy)
            dragCopyView = copy
            rowViews[state.row.id]?.dragSource = true
            listScroll.stopReveal()
            dragLastTick = dragClock()
            let timer = Timer(timeInterval: 1 / 120, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                MainActor.assumeIsolated { self.stepDrag() }
            }
            dragTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        drag = state
        guard state.active else { return }
        var frame = state.originFrame
        frame.origin.x += position.x - state.origin.x
        frame.origin.y += position.y - state.origin.y
        dragCopyView?.frame = nativeDragRect(frame)
        resolveDrag()
    }

    func dragGeometry() -> SidebarDragGeometry? {
        guard let space = snapshotSpace else { return nil }
        let models = space.pinned + space.today
        func inSplit(_ row: Row) -> Bool {
            var parent = models.first { $0.id == row.parentId }
            while let item = parent {
                if item.kind == .split { return true }
                parent = models.first { $0.id == item.parentId }
            }
            return false
        }
        var entries = models.filter { !inSplit($0) }.compactMap { row -> SidebarDragGeometry.Entry? in
            guard let view = rowViews[row.id] ?? noTabsRows[row.id] else { return nil }
            return .init(row: row, frame: dragRect(view))
        }
        for i in entries.indices where entries[i].row.kind == .split {
            let split = entries[i].row.id
            for row in models where row.parentId == split {
                if let view = rowViews[row.id] { entries[i].frame = entries[i].frame.union(dragRect(view)) }
            }
        }
        var favoriteFrame = dragRect(favorites)
        if space.favorites.isEmpty {
            let top = dragRect(urlField).maxY
            favoriteFrame = CGRect(x: favoriteFrame.minX, y: top, width: favoriteFrame.width, height: max(0, favoriteFrame.maxY - top))
        }
        return SidebarDragGeometry(bounds: CGRect(origin: .zero, size: bounds.size), list: dragRect(listScroll), pinnedArea: dragRect(spaceNameRow),
            favorites: favoriteFrame, rows: entries,
            dock: zip(snapshot.spaces, dock.subviews).map { ($0, dragRect($1)) }, space: space)
    }

    private func resolveDrag() {
        guard let state = drag, state.active, let geometry = dragGeometry() else { return }
        dropTarget = resolveSidebarDrop(position: state.position, geometry: geometry, dragged: state.row)
        let refused = geometry.dock.firstIndex { $0.frame.contains(state.position) && $0.space.profileKey != geometry.space.profileKey }
        setRefusedDock(refused)
        let favoriteIndex: Int?
        if case .favorites(_, let index) = dropTarget { favoriteIndex = index } else { favoriteIndex = nil }
        if favoriteIndex != dragFavoriteIndex {
            dragFavoriteIndex = favoriteIndex
            reloadFavorites()
            layoutSubtreeIfNeeded()
        }
        for row in rowViews.values { row.dropHovered = dropTarget == .folder(row.row.id) }
        let folder: String?
        if case .folder(let id) = dropTarget { folder = id } else { folder = nil }
        if drag?.hoverFolder != folder {
            drag?.hoverFolder = folder
            drag?.hoverStarted = folder == nil ? nil : dragClock()
        }
        dropIndicator.removeFromSuperlayer()
        dropIndicator.frame = bounds
        if case .insert(_, _, let y, let depth) = dropTarget {
            let x = SidebarDragMetrics.lineLeading + 16 * CGFloat(depth)
            let nativeY = bounds.height - y
            let path = CGMutablePath()
            path.move(to: CGPoint(x: x + SidebarDragMetrics.ringDiameter / 2, y: nativeY))
            path.addLine(to: CGPoint(x: bounds.width - SidebarDragMetrics.lineTrailing, y: nativeY))
            let diameter = SidebarDragMetrics.ringDiameter - SidebarDragMetrics.lineWidth
            path.addEllipse(in: CGRect(x: x - diameter / 2, y: nativeY - diameter / 2, width: diameter, height: diameter))
            dropIndicator.path = path
            dropIndicator.lineWidth = SidebarDragMetrics.lineWidth
            dropIndicator.fillColor = NSColor.clear.cgColor
            effectiveAppearance.performAsCurrentDrawingAppearance {
                dropIndicator.strokeColor = NSColor.labelColor.withAlphaComponent(0.95).cgColor
            }
            layer?.addSublayer(dropIndicator)
        }
    }

    private func setRefusedDock(_ index: Int?) {
        guard index != refusedDockIndex else { return }
        refusedDockIndex = index
        for (i, view) in dock.subviews.enumerated() { (view as? SpaceDockButton)?.refused = i == index }
        dockCursor(index != nil)
    }

    func stepDrag() {
        guard let state = drag, state.active, !dragSettling, let geometry = dragGeometry() else { return }
        let now = dragClock()
        let elapsed = max(0, min(0.1, now - dragLastTick))
        dragLastTick = now
        if geometry.list.contains(state.position) {
            let edge = SidebarDragMetrics.autoscrollEdge
            let delta: CGFloat = state.position.y < geometry.list.minY + edge ? -1 : state.position.y > geometry.list.maxY - edge ? 1 : 0
            if delta != 0 { listScroll.move(to: listScroll.contentView.bounds.minY + delta * SidebarDragMetrics.autoscrollSpeed * elapsed) }
        }
        resolveDrag()
        if let id = drag?.hoverFolder, let start = drag?.hoverStarted,
           now - start >= SidebarDragMetrics.folderHoverDelay,
           rowViews[id]?.row.collapsed == true {
            drag?.hoverStarted = nil
            onOpenFolder?(id) { [weak self] snapshot in
                guard let self, let snapshot else { return }
                self.replaceSnapshot(snapshot)
                self.resolveDrag()
            }
        }
    }

    @discardableResult
    func releaseDrag(at position: CGPoint) -> Bool {
        guard let state = drag else { return false }
        guard state.active else {
            drag = nil
            refreshPointer()
            return state.row.kind != .folder
        }
        moveDrag(to: position)
        dragTimer?.invalidate()
        dragTimer = nil
        let target = dropTarget
        dropIndicator.removeFromSuperlayer()
        dragSettling = true
        if case .favorites(nil, let index) = target, let space = snapshotSpace, let onFirstFavorite {
            let generation = dragGeneration
            onFirstFavorite(state.row.id, space.id, index) { [weak self] snapshot in
                guard let self, self.dragGeneration == generation else { return }
                if let snapshot { self.replaceSnapshot(snapshot) }
                self.settleDrag(accepted: snapshot != nil)
            }
        } else if let move = target.move, let onMove {
            let pinSpace = pinFromTodaySpace(id: state.row.id, container: move.container)
            let generation = dragGeneration
            onMove(state.row.id, move.container, move.index, { if case .folder = target { true } else { false } }()) { [weak self] snapshot in
                guard let self, self.dragGeneration == generation else { return }
                if let snapshot {
                    self.replaceSnapshot(snapshot)
                    self.showPinHint(id: state.row.id, space: pinSpace)
                }
                self.settleDrag(accepted: snapshot != nil)
            }
        } else { settleDrag(accepted: false) }
        return true
    }

    private func cancelDrag() {
        guard drag != nil, !dragSettling else { return }
        dragGeneration += 1
        dragTimer?.invalidate()
        dragTimer = nil
        dropTarget = .refused
        dropIndicator.removeFromSuperlayer()
        dragSettling = true
        settleDrag(accepted: false)
    }

    private func settleDrag(accepted: Bool) {
        setRefusedDock(nil)
        guard let state = drag else { return }
        dragFavoriteIndex = nil
        reloadFavorites()
        layoutSubtreeIfNeeded()
        let destination: CGRect
        if accepted, case .dock(let space, _, _) = dropTarget,
           let index = snapshot.spaces.firstIndex(where: { $0.id == space }), dock.subviews.indices.contains(index) {
            destination = dragRect(dock.subviews[index])
        } else if accepted, let view = rowViews[state.row.id] ?? favoriteTiles[state.row.id] { destination = dragRect(view) }
        else { destination = state.originFrame }
        guard let copy = dragCopyView, !dragReduceMotion() else { finishDrag(); return }
        let from = copy.layer?.presentation()?.position ?? copy.layer?.position ?? .zero
        copy.frame = nativeDragRect(destination)
        let animation = CABasicAnimation(keyPath: "position")
        animation.fromValue = NSValue(point: from)
        animation.toValue = NSValue(point: copy.layer?.position ?? .zero)
        animation.duration = SidebarDragMetrics.settleDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let generation = dragGeneration
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor in
                guard let self, self.dragGeneration == generation else { return }
                self.finishDrag()
            }
        }
        copy.layer?.add(animation, forKey: "drag.settle")
        CATransaction.commit()
    }

    private func finishDrag() {
        setRefusedDock(nil)
        dragGeneration += 1
        dragCopyView?.removeFromSuperview()
        dragCopyView = nil
        drag = nil
        dragSettling = false
        for row in rowViews.values { row.dragSource = false; row.dropHovered = false }
        tooltip.dismiss()
        refreshPointer()
        notifyAutoArchiveReady()
    }
}

@MainActor
private final class SidebarMenuItem: NSMenuItem {
    private let perform: () -> Void
    init(_ title: String, enabled: Bool = true, perform: @escaping () -> Void) {
        self.perform = perform
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
        isEnabled = enabled
    }
    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }
    @objc private func invoke() { perform() }
}

extension SidebarView: NSMenuDelegate {
    public func menuWillOpen(_ menu: NSMenu) { tooltip.menuTracking = true }
    public func menuDidClose(_ menu: NSMenu) { tooltip.menuTracking = false; refreshPointer(); notifyAutoArchiveReady() }

    private func itemMenu(_ items: [NSMenuItem]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        items.forEach(menu.addItem)
        shortcutMenus.add(menu)
        KeyBindingsModel.apply(keyBindings, to: menu)
        return menu
    }

    private func copyItem(_ row: Row) -> NSMenuItem {
        SidebarMenuItem("Copy Link", enabled: row.url != nil) { [weak self] in
            guard let self, let url = row.url else { return }
            self.copyLink(url)
        }
    }

    private func renameItem(_ row: Row) -> NSMenuItem {
        SidebarMenuItem("Rename…") { [weak self] in self?.beginRename(id: row.id) }
    }

    private func duplicateItem(_ row: Row) -> NSMenuItem {
        SidebarMenuItem("Duplicate") { [weak self] in self?.performEdit(.duplicate(id: row.id)) }
    }

    private func moveItem(_ row: Row) -> NSMenuItem {
        let item = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
        let targets = snapshot.spaces.filter { $0.profileKey == snapshotSpace?.profileKey && $0.id != snapshotSpace?.id }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for target in targets {
            menu.addItem(SidebarMenuItem(target.title) { [weak self] in
                guard let self else { return }
                let pinned = row.kind == .folder || self.snapshotSpace?.pinned.contains { $0.id == row.id } == true || self.snapshotSpace?.favorites.contains { $0.id == row.id } == true
                let container = pinned ? target.pinnedId : target.todayId
                let index = Int(pinned ? target.pinnedCount : target.todayCount)
                self.menuMove(row.id, container: container, index: index)
            })
        }
        item.submenu = menu
        item.isEnabled = !targets.isEmpty
        return item
    }

    func todayMenu(row: Row) -> NSMenu {
        itemMenu([copyItem(row), renameItem(row), duplicateItem(row), moveItem(row),
                  SidebarMenuItem("Archive Tab") { [weak self] in self?.onArchive?(row.id) }])
    }

    func pinnedMenu(row: Row) -> NSMenu {
        // D2: the mock's close item sits before "Remove Pin", and its words and action follow
        // the row's load state through the same rule as the hover button.
        let target = closeTarget(for: row.id)
        let archives = target?.action == .archive
        let close = SidebarMenuItem(archives ? "Archive Tab" : "Close Tab") { [weak self] in
            guard let self, let id = target?.id else { return }
            if archives { self.onArchive?(id) } else { self.onClose?(id) }
        }
        close.identifier = NSUserInterfaceItemIdentifier("close_tab")
        return itemMenu([copyItem(row), renameItem(row), duplicateItem(row), moveItem(row), close,
                         SidebarMenuItem("Remove Pin") { [weak self] in
                             guard let self, let container = self.snapshotSpace?.todayId else { return }
                             self.menuMove(row.id, container: container, index: 0)
                         }])
    }

    func favoriteMenu(row: Row) -> NSMenu {
        let close = SidebarMenuItem("Close Tab", enabled: pageCommandsAllowed) { [weak self] in
            guard self?.pageCommandsAllowed == true else { return }
            self?.onClose?(row.id)
        }
        close.identifier = NSUserInterfaceItemIdentifier("close_tab")
        return itemMenu([copyItem(row), renameItem(row), moveItem(row), close,
                  SidebarMenuItem("Remove Favorite") { [weak self] in self?.onArchive?(row.id) }])
    }

    func folderMenu(row: Row) -> NSMenu {
        itemMenu([SidebarMenuItem("New Nested Folder…") { [weak self] in self?.createFolder(in: row.id) },
                  renameItem(row), duplicateItem(row), moveItem(row),
                  SidebarMenuItem("Delete") { [weak self] in self?.deleteFolder(row) }])
    }

    public func dockMenuItems(for spaceID: String) -> [NSMenuItem] {
        spaceMenu(spaceID: spaceID).items
    }

    func spaceMenu(spaceID: String, anchor: NSView? = nil) -> NSMenu {
        let space = snapshot.spaces.first { $0.id == spaceID }
        return itemMenu([
            SidebarMenuItem("Rename Space…", enabled: space != nil) { [weak self] in self?.renameSpace(spaceID) },
            SidebarMenuItem("Edit Look…", enabled: space != nil) { [weak self] in self?.editLook(spaceID, anchor: anchor) },
            SidebarMenuItem("Space Settings…", enabled: space != nil) { [weak self] in self?.onSpaceSettings?(spaceID) },
            SidebarMenuItem("New Folder", enabled: space != nil && snapshotSpace != nil) { [weak self] in
                guard let self, let index = self.snapshot.spaces.firstIndex(where: { $0.id == spaceID }) else { return }
                if self.spaceIndex != index || self.libraryOpen || self.createSpaceOpen { self.dockClicked(self.dock.subviews[index] as! NSButton) }
                self.newFolder(nil)
            },
            SidebarMenuItem("Delete Space…", enabled: space != nil && snapshot.spaces.count > 1) { [weak self] in self?.confirmSpaceDelete(spaceID) },
        ])
    }

    private func renameSpace(_ id: String) {
        guard let index = snapshot.spaces.firstIndex(where: { $0.id == id }) else { return }
        if spaceIndex != index || libraryOpen || createSpaceOpen { dockClicked(dock.subviews[index] as! NSButton) }
        spaceNameRow.finishRename(commit: true)
        spaceNameRow.beginRename { [weak self] title, done in
            guard let save = self?.onRenameSpace else { done(false); return }
            save(id, title, done)
        }
        spaceRenameField = spaceNameRow.renameField
    }

    private func spaceRenameEnded() {
        spaceRenameField = nil
        notifyAutoArchiveReady()
    }

    // S1/S2: the chevron and a click on the row toggle the pinned section; the record is the
    // core's per-space, device-only one (part 1), and the edit's snapshot carries the new
    // `pinned_collapsed`, so the chevron follows the core rather than a local copy.
    public func isSectionCollapsed(_ spaceID: String) -> Bool {
        snapshot.spaces.first { $0.id == spaceID }?.pinnedCollapsed ?? false
    }

    public func toggleSection() {
        guard let space = snapshotSpace else { return }
        setSectionCollapsed(!isSectionCollapsed(space.id), spaceID: space.id)
    }

    public func setSectionCollapsed(_ collapsed: Bool, spaceID: String) {
        guard collapsed != isSectionCollapsed(spaceID) else { return }
        performEdit(.collapseSection(spaceID: spaceID, collapsed: collapsed))
    }

    // D13: the popover anchors to the row's … or right-click when the menu came from there,
    // and to the dock cell when it came from the cell (U22's entry).
    private func editLook(_ id: String, anchor: NSView?) {
        guard let index = snapshot.spaces.firstIndex(where: { $0.id == id }),
              dock.subviews.indices.contains(index), let settings = lookSettings else { return }
        dockLookPopover.performClose(nil)
        settings.update(snapshot: snapshot)
        let editor = LookEditorModel(settings: settings, space: snapshot.spaces[index])
        dockLookEditor = editor
        dockLookPopover.behavior = .transient
        dockLookPopover.delegate = self
        dockLookPopover.contentViewController = NSHostingController(rootView: LookPopoverView(model: editor))
        let view = anchor ?? dock.subviews[index]
        dockLookPopover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
    }

    // Preflight check 9: the look probe opens the popover from the space name row's Edit
    // Look… (the right-click path, without a menu tracking loop) instead of the Settings
    // window's anchor. Settings › Spaces keeps its own anchor.
    public func openLookForCheck() -> LookCheckProbe? {
        guard let space = snapshotSpace else { return nil }
        let menu = spaceMenu(spaceID: space.id, anchor: spaceNameRow)
        guard let item = menu.items.first(where: { $0.title == "Edit Look…" }), let action = item.action else { return nil }
        NSApp.sendAction(action, to: item.target, from: item)
        guard dockLookPopover.isShown else { return nil }
        return lookCheckProbe()
    }

    public func lookCheckProbe() -> LookCheckProbe? {
        guard dockLookPopover.isShown else { return nil }
        return LookCheckProbe(popover: dockLookPopover, editor: { [weak self] in self?.dockLookEditor })
    }

    public func showLookFromRow(_ id: String? = nil) { editLook(id ?? snapshotSpace?.id ?? "", anchor: spaceNameRow) }

    private func confirmSpaceDelete(_ id: String) {
        guard snapshot.spaces.count > 1, snapshot.spaces.contains(where: { $0.id == id }), let window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete Space?"
        alert.informativeText = "Its pinned and Today tabs will move to the Archive. Favorites will remain available in their profile. This cannot be undone."
        let delete = alert.addButton(withTitle: "Delete Space")
        delete.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: window) { [weak self] result in
            if result == .alertFirstButtonReturn { self?.onDeleteSpace?(id) }
        }
    }

    func emptyAreaMenu() -> NSMenu {
        itemMenu([SidebarMenuItem("New Folder", enabled: snapshotSpace != nil) { [weak self] in self?.newFolder(nil) }])
    }

    override public func menu(for event: NSEvent) -> NSMenu? {
        guard !isScrollPreview, !libraryOpen, !createSpaceOpen else { return nil }
        return emptyAreaMenu()
    }

    private func pinFromTodaySpace(id: String, container: String) -> String? {
        guard let space = snapshotSpace, space.today.contains(where: { $0.id == id }),
              container == space.pinnedId || space.pinned.contains(where: { $0.id == container && $0.kind == .folder }) else { return nil }
        return space.id
    }

    private func showPinHint(id: String, space: String?) {
        guard let space, snapshotSpace?.id == space else { return }
        rowViews[id]?.showRenameHint()
    }

    private func menuMove(_ id: String, container: String, index: Int) {
        onMove?(id, container, index, false) { [weak self] snapshot in
            if let snapshot { self?.replaceSnapshot(snapshot) }
        }
    }

    private var organizeFolder: Row? {
        guard let space = snapshotSpace else { return nil }
        let rows = space.favorites + space.pinned + space.today
        if let focused = window?.firstResponder as? SidebarRowView,
           let folder = rows.first(where: { $0.id == focused.row.id && $0.kind == .folder }) { return folder }
        guard let selected = rows.first(where: { $0.id == selectedID && $0.kind == .tab }) else { return nil }
        var parent = selected.parentId
        while let item = rows.first(where: { $0.id == parent }) {
            if item.kind == .folder { return item }
            parent = item.parentId
        }
        return nil
    }

    public var canDeleteOrganizeFolder: Bool { pageCommandsAllowed && !libraryOpen && organizeFolder != nil }

    public func organize(command: String) {
        guard pageCommandsAllowed, !libraryOpen else { return }
        guard let space = snapshotSpace else { return }
        let focused = (window?.firstResponder as? SidebarRowView)?.row
        let rows = space.favorites + space.pinned + space.today
        let row = rows.first { $0.id == focused?.id } ?? rows.first { $0.id == selectedID }
        if command == "new_folder" {
            createFolder(in: row?.kind == .folder ? row!.id : space.pinnedId)
            return
        }
        guard let row else { return }
        switch command {
        case "duplicate":
            guard row.kind != .split, !space.favorites.contains(where: { $0.id == row.id }) else { return }
            performEdit(.duplicate(id: row.id))
        case "rename":
            guard let target = (focused?.kind == .folder ? rows.first { $0.id == focused?.id } : rows.first { $0.id == selectedID && $0.kind == .tab }) else { return }
            beginRename(id: target.id)
        case "delete_folder":
            if let folder = organizeFolder { deleteFolder(folder) }
        default:
            guard command.hasPrefix("move_to_space_"),
                  let number = Int(command.dropFirst("move_to_space_".count)),
                  snapshot.spaces.indices.contains(number - 1) else { return }
            let target = snapshot.spaces[number - 1]
            guard target.id != space.id, target.profileKey == space.profileKey else { return }
            let pinned = !space.today.contains { $0.id == row.id }
            menuMove(row.id, container: pinned ? target.pinnedId : target.todayId,
                     index: Int(pinned ? target.pinnedCount : target.todayCount))
        }
    }

    func performEdit(_ edit: SidebarItemEdit, completion: ((Bool) -> Void)? = nil) {
        guard let onItemEdit else { completion?(false); return }
        onItemEdit(edit) { [weak self] snapshot in
            if let snapshot { self?.replaceSnapshot(snapshot) }
            completion?(snapshot != nil)
        }
    }

    @objc func newFolder(_ sender: Any?) {
        guard let space = snapshotSpace else { return }
        createFolder(in: space.pinnedId)
    }

    func createFolder(in container: String) {
        guard let space = snapshotSpace else { return }
        let id = UUID().uuidString
        // Why not count every row: the open, empty folder's "No tabs" marker is not an item,
        // so it has no index of its own to land after.
        let index = container == space.pinnedId ? Int(space.pinnedCount)
            : (space.pinned.filter { $0.parentId == container && $0.kind != .noTabs }.map { Int($0.siblingIndex) + 1 }.max() ?? 0)
        // Why not use the visible child count: collapsed folders omit their children.
        if let folder = space.pinned.first(where: { $0.id == container }), folder.collapsed {
            performEdit(.collapse(id: container, collapsed: false)) { [weak self] success in
                if success { self?.createFolder(in: container) }
            }
            return
        }
        performEdit(.createFolder(id: id, container: container, index: index)) { [weak self] success in
            if success { self?.beginRename(id: id) }
        }
    }

    func beginRename(id: String) {
        if let old = renamingID, old != id {
            rowViews[old]?.finishRename(commit: true)
            favoriteTiles[old]?.renameField?.finish(commit: true)
        }
        tooltip.dismiss()
        if let view = rowViews[id] {
            renamingID = id
            view.beginRename()
        } else if let tile = favoriteTiles[id] {
            renamingID = id
            tile.beginRename { [weak self, weak tile] title, done in
                guard let self, let tile else { done(false); return }
                self.commitRename(row: tile.row, title: title, completion: done)
            }
            tile.onRenameEnd = { [weak self] in
                guard let self, self.renamingID == id else { return }
                self.renamingID = nil; self.notifyAutoArchiveReady()
            }
        }
    }

    func commitRename(row: Row, title: String, completion: @escaping (Bool) -> Void) {
        if row.kind == .folder && title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { completion(false); return }
        performEdit(.rename(id: row.id, title: title, folder: row.kind == .folder), completion: completion)
    }

    func deleteFolder(_ row: Row) {
        let remove: (Bool) -> Void = { [weak self] confirmed in
            if confirmed { self?.performEdit(.deleteFolder(id: row.id)) }
        }
        if row.folderHasTabs { confirmFolderDeletion?(row, remove) }
        else { remove(true) }
    }
}

@MainActor
extension SidebarView: NSPopoverDelegate {
    public func popoverWillClose(_ notification: Notification) { dockLookEditor?.dismiss(); dockLookEditor = nil }
}

// The check seam (U25b part 2): what a row shows, without making the row view public.
public struct SidebarRowCheckInfo: Sendable {
    public let id: String
    public let kind: RowKind
    public let unloaded: Bool
    public let loading: Bool
    public let audioLabel: String?
    public let closeLabel: String?
    public let closeCaps: [String]?
    public let unreadDot: Bool
    public let iconDescription: String?
    public let opacity: Double
    public let frame: NSRect
}

extension SidebarView {
    public var rowCheckIds: [String] { Array(rowViews.keys) }
    public func pressRowAudioForCheck(id: String) { rowViews[id]?.pressAudioForCheck() }

    public func rowCheckInfo(id: String) -> SidebarRowCheckInfo? {
        guard let view = rowViews[id] else { return nil }
        let icon = view.subviews.compactMap { $0 as? NSImageView }.first
        let label = view.closeButton.accessibilityLabel()
        return SidebarRowCheckInfo(id: id, kind: view.row.kind, unloaded: view.row.unloaded, loading: view.loadingVisible, audioLabel: view.audioLabel,
            // The configured label, shown or not: the button only appears on hover, and a VM
            // check cannot move the pointer reliably (the hover look is covered in swift test).
            closeLabel: label, closeCaps: view.closeShortcutCaps,
            unreadDot: view.unreadDotVisible, iconDescription: icon?.image?.accessibilityDescription,
            opacity: Double(icon?.alphaValue ?? 1),
            frame: convert(view.bounds, from: view))
    }

    public var noTabsRowsForCheck: [(id: String, parent: String, frame: NSRect, text: NSRect, height: CGFloat,
                                    fontSize: CGFloat, lineHeight: CGFloat, cellHeight: CGFloat)] {
        noTabsRows.map { id, view in
            view.layoutSubtreeIfNeeded()
            // Dragging works in the sidebar’s flipped coordinates (SidebarDrag.dragRect).
            let row = dragRect(view)
            let text = convert(view.textFrameInRow, from: view)
            return (id, view.parentIDForCheck, row,
                    CGRect(x: text.minX, y: bounds.height - text.maxY, width: text.width, height: text.height),
                    view.frame.height, view.textFontSize, view.textLineHeight, view.textCellHeight)
        }
    }

    public var todayDividerForCheck: (frame: NSRect, line: NSRect, clear: NSRect)? {
        guard todayDivider.superview != nil else { return nil }
        todayDivider.layoutSubtreeIfNeeded()
        let frames = todayDivider.checkFrames
        guard let line = frames["line"], let clear = frames["clear"] else { return nil }
        return (convert(todayDivider.bounds, from: todayDivider),
                convert(line, from: todayDivider), convert(clear, from: todayDivider))
    }

    public var newTabRowForCheck: NSRect? {
        guard newTabRow.superview != nil, !newTabRow.isHidden else { return nil }
        return convert(newTabRow.bounds, from: newTabRow)
    }

    public func pressClearToday() -> Bool {
        guard todayDivider.superview != nil,
              let button = SidebarNoTabsRowSelf.find(todayDivider, SidebarClearButton.self) else { return false }
        button.performClick(nil)
        return true
    }

    public var closeCapsForCheck: [String]? { selectedID.flatMap { rowViews[$0] }?.closeShortcutCaps }
    /// The caps the close_tab binding gives every row, to compare against the current row's.
    public var closeBindingCapsForCheck: [String] { closeCaps }
}

private enum SidebarNoTabsRowSelf {
    static func find<T: NSView>(_ view: NSView, _ type: T.Type) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews { if let match = find(child, type) { return match } }
        return nil
    }
}

// The check seam for a drop: the resolver's answer as plain values, so the check does not
// reach into the drag types.
public struct SidebarDropCheck: Sendable {
    public let kind: String
    public let container: String?
    public let index: Int?
}

extension SidebarView {
    public func resolveDropForCheck(position: CGPoint, draggedID: String) -> SidebarDropCheck? {
        guard let space = snapshotSpace,
              let dragged = (space.today + space.pinned + space.favorites).first(where: { $0.id == draggedID }),
              let geometry = dragGeometry() else { return nil }
        switch resolveSidebarDrop(position: position, geometry: geometry, dragged: dragged) {
        case .refused: return SidebarDropCheck(kind: "refused", container: nil, index: nil)
        case let .insert(container, index, _, _): return SidebarDropCheck(kind: "insert", container: container, index: index)
        case let .folder(id): return SidebarDropCheck(kind: "folder", container: id, index: nil)
        case let .favorites(container, index): return SidebarDropCheck(kind: "favorites", container: container, index: index)
        case let .dock(_, container, index): return SidebarDropCheck(kind: "dock", container: container, index: index)
        }
    }
}

extension SidebarView {
    /// The action the hover button runs for a row, without a pointer: the check calls the
    /// same rule and callbacks the button would (the button itself is hover-only).
    @discardableResult
    public func pressRowCloseForCheck(id: String) -> RowCloseAction? {
        guard let target = closeTarget(for: id) else { return nil }
        if target.action == .archive { onArchive?(target.id) } else { onClose?(target.id) }
        return target.action
    }

    /// What closeSelectedTab checks before it runs ⌘W's action, so a check can tell a
    /// blocked window (no page command allowed) from a missing archive.
    public var closeSelectedReadyForCheck: (allowed: Bool, selected: String?) {
        (pageCommandsAllowed, selectedID)
    }
}
