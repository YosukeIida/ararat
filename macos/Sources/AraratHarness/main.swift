import AppKit
import Darwin
import AraratKit
import AraratUI

var arguments = CommandLine.arguments.dropFirst().makeIterator()
var checkOnly = false
var databasePath: String?
var path: String?
while let argument = arguments.next() {
    switch argument {
    case "--check": checkOnly = true
    case "--db":
        guard let value = arguments.next(), !value.hasPrefix("--") else {
            FileHandle.standardError.write(Data("--db requires a path\n".utf8))
            exit(1)
        }
        databasePath = value
    default:
        guard !argument.hasPrefix("--"), path == nil else {
            FileHandle.standardError.write(Data("usage: AraratHarness [--check] [--db path] [StorableSidebar.json]\n".utf8))
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

let temporaryDirectory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? NSTemporaryDirectory(), isDirectory: true)
let temporaryDatabasePath = databasePath == nil
    ? temporaryDirectory.appendingPathComponent("ararat-harness-\(UUID().uuidString).sqlite").path : nil

@discardableResult
func removeTemporaryDatabase() -> Bool {
    guard let temporaryDatabasePath else { return true }
    var removed = true
    for suffix in ["", "-wal", "-shm"] {
        let file = temporaryDatabasePath + suffix
        guard FileManager.default.fileExists(atPath: file) else { continue }
        do { try FileManager.default.removeItem(atPath: file) } catch {
            FileHandle.standardError.write(Data("cannot remove temporary database \(file): \(error)\n".utf8))
            removed = false
        }
    }
    return removed
}

let store: WorkspaceStore
let snapshot: WorkspaceSnapshot
do {
    let opened = try WorkspaceStore.open(path: databasePath ?? temporaryDatabasePath!)
    store = opened
    do {
        let loaded = opened.snapshot()
        snapshot = loaded.spaces.isEmpty ? try opened.importArcSidebar(json: sidebarJSON(path: path)) : loaded
    } catch {
        try? opened.flush()
        throw error
    }
} catch {
    removeTemporaryDatabase()
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}

func flushAndCleanup() -> Bool {
    var flushed = true
    do { try store.flush() } catch {
        FileHandle.standardError.write(Data("cannot flush store: \(error)\n".utf8))
        flushed = false
    }
    let removed = removeTemporaryDatabase()
    return flushed && removed
}

if checkOnly {
    for space in snapshot.spaces {
        print("\(space.title): favorites \(space.favorites.count), pinned \(space.pinned.count), today \(space.today.count)")
    }
    exit(flushAndCleanup() ? 0 : 1)
}

@MainActor
final class HarnessDelegate: NSObject, NSApplicationDelegate {
    var snapshot: WorkspaceSnapshot
    let store: WorkspaceStore
    var window: NSWindow?
    var sidebar: SidebarView?
    var resizeHandle: SidebarResizeHandle?
    var sidebarContainer: SidebarContainerView?
    private var card: PlaceholderCard?

    init(snapshot: WorkspaceSnapshot, store: WorkspaceStore) {
        self.snapshot = snapshot
        self.store = store
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = BrowserWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Ararat Harness"

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
        sidebar.onSelect = { [weak self] row in
            do { try self?.selectItem(id: row.id) } catch {
                FileHandle.standardError.write(Data("cannot select item: \(error)\n".utf8))
            }
        }
        sidebar.onClose = { [weak self] id in
            do { try self?.closeTab(id: id) } catch {
                FileHandle.standardError.write(Data("cannot close tab: \(error)\n".utf8))
            }
        }
        showSelection()

        container.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            container.topAnchor.constraint(equalTo: background.topAnchor),
            container.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        window.contentView = background
        let menu = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Ararat Harness", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = appMenu
        let fileMenu = NSMenu(title: "File")
        let close = fileMenu.addItem(withTitle: "Close Tab", action: #selector(SidebarView.closeSelectedTodayTab(_:)), keyEquivalent: "w")
        close.target = sidebar
        menu.addItem(withTitle: "File", action: nil, keyEquivalent: "").submenu = fileMenu
        let viewMenu = NSMenu(title: "View")
        let toggle = viewMenu.addItem(withTitle: "Toggle Sidebar", action: #selector(toggleSidebar(_:)), keyEquivalent: "s")
        toggle.target = self
        let reset = viewMenu.addItem(withTitle: "Reset Sidebar Width", action: #selector(resetSidebarWidth(_:)), keyEquivalent: "")
        reset.target = self
        menu.addItem(withTitle: "View", action: nil, keyEquivalent: "").submenu = viewMenu
        NSApp.mainMenu = menu
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate()
        readCommands()
        HitchMonitor.start()
    }

    private func readCommands() {
        Thread.detachNewThread {
            while let line = readLine() {
                DispatchQueue.main.async { self.run(line) }
            }
        }
    }

    private func run(_ line: String) {
        guard let sidebar, let resizeHandle, let sidebarContainer else { return }
        let words = line.split(separator: " ", maxSplits: 1).map(String.init)
        let reply: String
        switch (words.first, words.count > 1 ? words[1] : nil) {
        case ("quit", nil):
            reply = "ok quit"
        case ("space", let arg?):
            guard let index = Int(arg), snapshot.spaces.indices.contains(index) else { reply = "error no space \(arg)"; break }
            sidebar.showSpace(at: index)
            reply = "ok space \(index)"
        case ("select", let id?):
            guard snapshot.spaces.indices.contains(sidebar.spaceShown) else { reply = "error no row \(id)"; break }
            let space = snapshot.spaces[sidebar.spaceShown]
            guard (space.favorites + space.pinned + space.today).contains(where: { $0.id == id }) else {
                reply = "error no row \(id)"; break
            }
            do {
                try selectItem(id: id)
                reply = "ok select \(id)"
            } catch { reply = "error select \(id): \(error)" }
        case ("close", let id?):
            do {
                try closeTab(id: id)
                reply = "ok close \(id)"
            } catch { reply = "error close \(id): \(error)" }
        case ("state", nil):
            reply = "state space \(sidebar.spaceShown) selected \(sidebar.selectedRowID ?? "-")"
        case ("width", nil):
            reply = String(format: "ok %g", Double(resizeHandle.sidebarWidth))
        case ("reset-width", nil):
            resetSidebarWidth(nil)
            reply = "ok 240"
        case ("sidebar", nil):
            reply = "ok \(sidebarContainer.sidebarState)"
        case ("toggle-sidebar", nil):
            toggleSidebar(nil)
            reply = "ok \(sidebarContainer.sidebarState)"
        default:
            reply = "error unknown command"
        }
        print(reply)
        fflush(stdout)
        if words == ["quit"] { NSApp.terminate(nil) }
    }

    private func selectItem(id: String) throws {
        do {
            snapshot = try store.selectItem(id: id)
        } catch {
            snapshot = store.snapshot()
            sidebar?.updateSelection(id: snapshot.selectedId)
            showSelection()
            throw error
        }
        sidebar?.updateSelection(id: snapshot.selectedId)
        showSelection()
    }

    private func closeTab(id: String) throws {
        do {
            snapshot = try store.closeTodayTab(id: id)
            sidebar?.applyClose(id: id, snapshot: snapshot)
        } catch {
            snapshot = store.snapshot()
            sidebar?.update(snapshot: snapshot)
            showSelection()
            throw error
        }
        showSelection()
    }

    private func showSelection() {
        let row = snapshot.spaces.flatMap { $0.favorites + $0.pinned + $0.today }.first { $0.id == snapshot.selectedId }
        card?.show(title: row?.title ?? "Select a tab", url: row?.url)
        sidebarContainer?.selectionChanged()
    }

    @objc private func resetSidebarWidth(_ sender: Any?) {
        resizeHandle?.resetWidth()
    }

    @objc private func toggleSidebar(_ sender: Any?) {
        sidebarContainer?.toggleSidebar()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        _ = flushAndCleanup()
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
app.setActivationPolicy(.regular)
let delegate = HarnessDelegate(snapshot: snapshot, store: store)
app.delegate = delegate
let terminationSignals = [SIGTERM, SIGINT].map { number in
    _ = signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
    source.resume()
    return source
}
withExtendedLifetime(terminationSignals) { app.run() }
if !flushAndCleanup() { exit(1) }
