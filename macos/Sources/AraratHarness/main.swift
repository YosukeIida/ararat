import AppKit
import Darwin
import AraratKit
import AraratUI

var arguments = CommandLine.arguments.dropFirst().makeIterator()
var checkOnly = false
var headless = false
var databasePath: String?
var path: String?
while let argument = arguments.next() {
    switch argument {
    case "--check": checkOnly = true
    case "--headless": headless = true
    case "--db":
        guard let value = arguments.next(), !value.hasPrefix("--") else {
            FileHandle.standardError.write(Data("--db requires a path\n".utf8))
            exit(1)
        }
        databasePath = value
    default:
        guard !argument.hasPrefix("--"), path == nil else {
            FileHandle.standardError.write(Data("usage: AraratHarness [--check] [--headless] [--db path] [StorableSidebar.json]\n".utf8))
            exit(1)
        }
        path = argument
    }
}

func sidebarJSON(path: String?) throws -> String {
    if let path {
        return try String(contentsOfFile: path, encoding: .utf8)
    } else {
        let url = Bundle.module.url(forResource: "arc-sidebar-synthetic", withExtension: "json", subdirectory: "Fixtures")!
        return try String(contentsOf: url, encoding: .utf8)
    }
}

@MainActor
final class HarnessDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    var snapshot = WorkspaceSnapshot(archive: [], shownSpaceId: nil, selectedId: nil, spaces: [])
    let adapter: WorkspaceAdapter
    var exitStatus: Int32 = 0
    private var terminating = false
    private var commands: [String] = []
    var window: NSWindow?
    var sidebar: SidebarView?
    var resizeHandle: SidebarResizeHandle?
    var sidebarContainer: SidebarContainerView?
    private var autoArchive: AutoArchive?
    private var settings: SettingsWindowController?
    private var card: PlaceholderCard?
    private var headlessContent: NSView?

    let options: HarnessOptions
    var terminate: () -> Void
    init(adapter: WorkspaceAdapter, options: HarnessOptions = HarnessOptions(), terminate: @escaping () -> Void = { NSApp.terminate(nil) }) {
        self.options = options
        self.adapter = adapter
        self.terminate = terminate
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !terminating else { return }
        let fixturePath = options.fixturePath
        adapter.open(path: options.databasePath, json: { try sidebarJSON(path: fixturePath) }) { [weak self] result in
            guard let self, !self.terminating else { return }
            switch result {
            case .success(let snapshot):
                self.snapshot = snapshot
                if options.checkOnly {
                    for space in snapshot.spaces {
                        print("\(space.title): favorites \(space.favorites.count), pinned \(space.pinned.count), today \(space.today.count)")
                    }
                    NSApp.terminate(nil)
                } else {
                    self.build()
                    let archive = AutoArchive(adapter: self.adapter, canPublish: { [weak self] in self?.sidebar?.canPublishAutoArchive ?? false }) { [weak self] result in
                        _ = self?.publish(result)
                    }
                    self.autoArchive = archive
                    self.sidebar?.onAutoArchiveReady = { [weak archive] in archive?.publishDeferred() }
                    archive.start()
                }
            case .failure(let error):
                FileHandle.standardError.write(Data("\(error)\n".utf8))
                self.exitStatus = 1
                NSApp.terminate(nil)
            }
        }
    }

    private func build() {
        let window = options.headless ? nil : BrowserWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window?.isReleasedWhenClosed = false
        window?.delegate = self
        window?.titlebarAppearsTransparent = true
        window?.titleVisibility = .hidden
        window?.title = "Ararat Harness"

        let background = NSVisualEffectView()
        background.material = .sidebar
        background.blendingMode = .behindWindow

        let sidebar = SidebarView(snapshot: snapshot)
        self.sidebar = sidebar
        let card = PlaceholderCard()
        self.card = card
        let container = SidebarContainerView(sidebar: sidebar, page: card)
        sidebarContainer = container
        resizeHandle = container.resizeHandle
        sidebar.onItemEdit = { [weak self] edit, completion in
            guard let self, !self.terminating else { completion(nil); return }
            self.adapter.edit(edit) { [weak self] result in
                switch result {
                case .success(let snapshot):
                    self?.snapshot = snapshot
                    completion(snapshot)
                    self?.showSelection()
                case .failure(let error):
                    FileHandle.standardError.write(Data("cannot edit item: \(error)\n".utf8))
                    completion(nil)
                }
            }
        }
        sidebar.confirmFolderDeletion = { [weak self] row, completion in
            guard let window = self?.window else { completion(false); return }
            let alert = NSAlert()
            alert.messageText = "Delete your “\(row.title)” folder?"
            alert.informativeText = "Deleting this folder will archive the tabs inside it."
            let delete = alert.addButton(withTitle: "Delete Folder")
            delete.keyEquivalent = "\r"
            delete.hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
            alert.beginSheetModal(for: window) { response in completion(response == .alertFirstButtonReturn) }
        }
        sidebar.onSelect = { [weak self] row in
            guard let self, !self.terminating else { return }
            self.adapter.select(id: row.id) { [weak self] result in
                if let error = self?.publish(result) {
                    FileHandle.standardError.write(Data("cannot select item: \(error)\n".utf8))
                }
            }
        }
        sidebar.onMove = { [weak self] id, container, index, openFolder, completion in
            guard let self, !self.terminating else { completion(nil); return }
            self.adapter.move(id: id, container: container, index: index, openFolder: openFolder) { [weak self] result in
                switch result {
                case .success(let snapshot):
                    self?.snapshot = snapshot
                    completion(snapshot)
                    self?.showSelection()
                case .failure(let error):
                    FileHandle.standardError.write(Data("cannot move item: \(error)\n".utf8))
                    completion(nil)
                }
            }
        }
        sidebar.onOpenFolder = { [weak self] id, completion in
            guard let self, !self.terminating else { completion(nil); return }
            self.adapter.openFolder(id: id) { [weak self] result in
                switch result {
                case .success(let snapshot): self?.snapshot = snapshot; completion(snapshot)
                case .failure(let error):
                    FileHandle.standardError.write(Data("cannot open folder: \(error)\n".utf8))
                    completion(nil)
                }
            }
        }
        sidebar.onClose = { [weak self] id in
            guard let self, !self.terminating else { return }
            self.adapter.close(id: id) { [weak self] result in
                if let error = self?.publishChange(result) {
                    FileHandle.standardError.write(Data("cannot close tab: \(error)\n".utf8))
                }
            }
        }
        sidebar.onCloseSelected = { [weak self] in
            guard let self, !self.terminating else { return }
            self.adapter.closeSelected { [weak self] result in
                if let error = self?.publishChange(result) {
                    FileHandle.standardError.write(Data("cannot close tab: \(error)\n".utf8))
                }
            }
        }
        sidebar.onArchive = { [weak self] id in
            guard let self, !self.terminating else { return }
            self.adapter.archive(id: id) { [weak self] result in
                if let error = self?.publishChange(result) {
                    FileHandle.standardError.write(Data("cannot archive tab: \(error)\n".utf8))
                }
            }
        }
        sidebar.onShowSpace = { [weak self] id in
            guard let self, !self.terminating else { return }
            self.adapter.showSpace(id: id) { result in
                if case .failure(let error) = result {
                    FileHandle.standardError.write(Data("cannot show space: \(error)\n".utf8))
                }
            }
        }
        sidebar.onRestore = { [weak self] id in self?.restore(id: id) { _ in } }
        sidebar.onArchiveDelete = { [weak self] id in self?.deleteArchive(id: id) { _ in } }
        sidebar.onCreateSpace = { [weak self] name in self?.createSpace(name: name) { _ in } }
        sidebar.onCreatePageChanged = { [weak self] in self?.showSelection() }
        showSelection()

        container.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            container.topAnchor.constraint(equalTo: background.topAnchor),
            container.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        if let window {
            window.contentView = background
            NSApp.mainMenu = makeMenu()
            window.center()
            window.makeKeyAndOrderFront(nil)
            self.window = window
            NSApp.activate()
        } else {
            headlessContent = background
            background.frame = NSRect(x: 0, y: 0, width: 1100, height: 720)
            background.layoutSubtreeIfNeeded()
        }
        readCommands()
        HitchMonitor.start()
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let appMenu = NSMenu()
        let settingsItem = appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.toolTip = "Open settings for the shown space."
        appMenu.addItem(.separator())
        let quit = appMenu.addItem(withTitle: "Quit Ararat Harness", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.toolTip = "Close all windows and quit Ararat."
        menu.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = appMenu
        let fileMenu = NSMenu(title: "File")
        let close = fileMenu.addItem(withTitle: "Close Tab", action: #selector(closeSelectedTab(_:)), keyEquivalent: "w")
        close.target = self
        close.toolTip = "Close the selected tab in the browser window."
        menu.addItem(withTitle: "File", action: nil, keyEquivalent: "").submenu = fileMenu
        let viewMenu = NSMenu(title: "View")
        let toggle = viewMenu.addItem(withTitle: "Toggle Sidebar", action: #selector(toggleSidebar(_:)), keyEquivalent: "s")
        toggle.target = self
        toggle.toolTip = "Show or hide the sidebar."
        let library = viewMenu.addItem(withTitle: "Toggle Library", action: #selector(SidebarView.toggleLibrary(_:)), keyEquivalent: "l")
        library.keyEquivalentModifierMask = [.command, .shift]
        library.target = sidebar
        library.toolTip = "Show or hide the Library."
        let reset = viewMenu.addItem(withTitle: "Reset Sidebar Width", action: #selector(resetSidebarWidth(_:)), keyEquivalent: "")
        reset.target = self
        viewMenu.addItem(.separator())
        for index in 0..<9 {
            let item = viewMenu.addItem(withTitle: "Show Space \(index + 1)", action: WorkspaceCommands.showSpace, keyEquivalent: String(index + 1))
            item.keyEquivalentModifierMask = [.control]
            item.tag = index
            item.target = self
            item.toolTip = "Show space \(index + 1) in sidebar order."
        }
        menu.addItem(withTitle: "View", action: nil, keyEquivalent: "").submenu = viewMenu
        return menu
    }

    func canCloseTab(keyWindow: NSWindow?) -> Bool { window != nil && keyWindow === window }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(closeSelectedTab(_:)) { return canCloseTab(keyWindow: NSApp.keyWindow) }
        if menuItem.action == WorkspaceCommands.showSpace { return snapshot.spaces.indices.contains(menuItem.tag) }
        return true
    }

    @objc func closeSelectedTab(_ sender: Any?) {
        guard canCloseTab(keyWindow: NSApp.keyWindow) else { return }
        sidebar?.closeSelectedTab(sender)
    }

    @objc func showSpace(_ sender: NSMenuItem) {
        guard snapshot.spaces.indices.contains(sender.tag) else { return }
        sidebar?.showSpace(at: sender.tag)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        terminate()
    }

    private func readCommands() {
        Thread.detachNewThread {
            while let line = readLine() {
                DispatchQueue.main.async { self.receive(line) }
            }
        }
    }

    private func receive(_ line: String) {
        guard !terminating else { return }
        commands.append(line)
        if commands.count == 1 { runNext() }
    }

    private func runNext() {
        guard let line = commands.first else { return }
        let command = HarnessCommand.parse(line)
        run(command) { [weak self] reply in
            guard let self else { return }
            print(reply)
            fflush(stdout)
            self.commands.removeFirst()
            if case .quit = command { NSApp.terminate(nil) }
            else { self.runNext() }
        }
    }

    private func run(_ command: HarnessCommand, reply: @escaping @MainActor (String) -> Void) {
        guard let sidebar, let resizeHandle, let sidebarContainer else { reply("error not ready"); return }
        switch command {
        case .archiveDelete(let id): deleteArchive(id: id, reply: reply)
        case .archiveSearch(let query): reply("ok archive-search count \(sidebar.searchArchive(query))")
        case .createSpace(let name): createSpace(name: name, reply: reply)
        case .library(let open):
            sidebar.setLibraryOpen(open)
            reply(open ? "ok library" : "ok library close")
        case .restore(let id): restore(id: id, reply: reply)
        case .quit: reply("ok quit")
        case .space(let index):
            guard snapshot.spaces.indices.contains(index) else { reply("error no space \(index)"); return }
            sidebar.showSpace(at: index)
            adapter.snapshot { result in
                if case .failure(let error) = result { reply("error space \(index): \(error)") }
                else { reply("ok space \(index)") }
            }
        case .select(let id):
            guard snapshot.spaces.indices.contains(sidebar.spaceShown) else { reply("error no row \(id)"); return }
            let space = snapshot.spaces[sidebar.spaceShown]
            guard (space.favorites + space.pinned + space.today).contains(where: { $0.id == id }) else { reply("error no row \(id)"); return }
            adapter.select(id: id) { [weak self] result in
                if let error = self?.publish(result) { reply("error select \(id): \(error)") }
                else { self?.sidebar?.revealSelection(); reply("ok select \(id)") }
            }
        case .close(let id):
            adapter.close(id: id) { [weak self] result in
                if let error = self?.publishChange(result) { reply("error close \(id): \(error)") }
                else { reply("ok close \(id)") }
            }
        case .state: reply("state space \(sidebar.spaceShown) selected \(sidebar.selectedRowID ?? "-") library \(sidebar.libraryOpen ? "open" : "closed") spaces \(snapshot.spaces.count)")
        case .width: reply(String(format: "ok %g", Double(resizeHandle.sidebarWidth)))
        case .resetWidth: resetSidebarWidth(nil); reply("ok 240")
        case .sidebar: reply("ok \(sidebarContainer.sidebarState)")
        case .toggleSidebar: toggleSidebar(nil); reply("ok \(sidebarContainer.sidebarState)")
        case .invalid(let error): reply(error)
        }
    }

    private func deleteArchive(id: String, reply: @escaping @MainActor (String) -> Void) {
        adapter.deleteArchive(id: id) { [weak self] result in
            if let error = self?.publish(result) { reply("error archive-delete \(id): \(error)") }
            else { reply("ok archive-delete \(id)") }
        }
    }

    private func createSpace(name: String, reply: @escaping @MainActor (String) -> Void) {
        adapter.createSpace(name: name) { [weak self] result in
            switch result {
            case .success(let snapshot):
                self?.snapshot = snapshot
                self?.sidebar?.applyCreatedSpace(snapshot: snapshot)
                self?.showSelection()
                reply("ok create-space \(snapshot.spaces.last?.title ?? name)")
            case .failure(let error):
                self?.sidebar?.creationFailed(String(describing: error))
                reply("error create-space: \(error)")
            }
        }
    }

    private func restore(id: String, reply: @escaping @MainActor (String) -> Void) {
        adapter.restore(id: id) { [weak self] result in
            switch result {
            case .success(let snapshot):
                self?.snapshot = snapshot
                self?.sidebar?.applyRestore(snapshot: snapshot)
                self?.showSelection()
                reply("ok restore \(id)")
            case .failure(let error):
                _ = self?.publish(.failure(error))
                FileHandle.standardError.write(Data("cannot restore tab: \(error)\n".utf8))
                reply("error restore \(id): \(error)")
            }
        }
    }

    private func publish(_ result: Result<WorkspaceSnapshot, Error>, closing id: String? = nil) -> Error? {
        switch result {
        case .success(let snapshot):
            self.snapshot = snapshot
            if let id { sidebar?.applyClose(id: id, snapshot: snapshot) }
            else { sidebar?.applySelection(snapshot: snapshot) }
            showSelection()
            return nil
        case .failure(let error):
            if terminating { return error }
            adapter.snapshot { [weak self] result in
                if case .success = result { _ = self?.publish(result) }
            }
            return error
        }
    }

    private func publishChange(_ result: Result<WorkspaceAdapter.Change, Error>) -> Error? {
        switch result {
        case .success(let change): return publish(.success(change.snapshot), closing: change.id)
        case .failure(let error): return publish(.failure(error))
        }
    }

    @objc private func openSettings(_ sender: Any?) {
        prepareSettings().open(shownSpaceID: shownSpaceID)
    }

    private var shownSpaceID: String? {
        sidebar.flatMap { snapshot.spaces.indices.contains($0.spaceShown) ? snapshot.spaces[$0.spaceShown].id : nil }
    }

    func prepareSettings() -> SettingsWindowController {
        if settings == nil {
            let model = SettingsModel(snapshot: snapshot, adapter: adapter, publish: { [weak self] snapshot in
                _ = self?.publish(.success(snapshot))
            }, resetWidth: { [weak self] in self?.resetSidebarWidth(nil) }, preview: { [weak self] id, look, active in self?.sidebar?.previewLook(spaceID: id, look: look, active: active) })
            settings = SettingsWindowController(model: model)
        }
        settings!.prepare(shownSpaceID: shownSpaceID)
        return settings!
    }

    private func showSelection() {
        settings?.modelUpdate(snapshot: snapshot)
        if sidebar?.createSpaceOpen == true {
            card?.show(title: "", url: nil)
            sidebarContainer?.selectionChanged()
            return
        }
        let row = snapshot.spaces.flatMap { $0.favorites + $0.pinned + $0.today }.first { $0.id == snapshot.selectedId }
        if row != nil || snapshot.selectedId == nil {
            card?.show(title: row?.title ?? "Select a tab", url: row?.url)
        }
        sidebarContainer?.selectionChanged()
    }

    @objc private func resetSidebarWidth(_ sender: Any?) {
        resizeHandle?.resetWidth()
    }

    @objc private func toggleSidebar(_ sender: Any?) {
        sidebarContainer?.toggleSidebar()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        autoArchive?.stop()
        terminating = true
        adapter.shutdown { [weak self] result in
            guard let self else { return }
            if case .failure(let error) = result {
                FileHandle.standardError.write(Data("cannot flush store: \(error)\n".utf8))
                self.exitStatus = 1
            }
            if !options.removeTemporaryDatabase() { self.exitStatus = 1 }
            if self.exitStatus != 0 { exit(self.exitStatus) }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

}

@MainActor
final class PlaceholderCard: NSView {
    private let label = NSTextField(wrappingLabelWithString: "Select a tab")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        updateFill()
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(title: String, url: String?) {
        label.stringValue = [title, url].compactMap { $0 }.joined(separator: "\n")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill()
    }

    private func updateFill() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        }
    }
}

enum HitchMonitor {
    static func start() {
        Thread.detachNewThread {
            while true {
                let sent = DispatchTime.now().uptimeNanoseconds
                let done = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { done.signal() }
                done.wait()
                let ms = (DispatchTime.now().uptimeNanoseconds - sent) / 1_000_000
                if ms > 100 { FileHandle.standardError.write(Data("hitch \(ms) ms\n".utf8)) }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(headless || checkOnly ? .prohibited : .regular)
let delegate = HarnessDelegate(adapter: WorkspaceAdapter(windowID: "harness-window"), options: HarnessOptions(checkOnly: checkOnly, headless: headless, databasePath: databasePath, fixturePath: path))
app.delegate = delegate
let terminationSignals = [SIGTERM, SIGINT].map { number in
    _ = signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
    source.resume()
    return source
}
withExtendedLifetime(terminationSignals) { app.run() }
exit(delegate.exitStatus)
