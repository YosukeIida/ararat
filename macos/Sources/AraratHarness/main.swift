import AppKit
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

let store: WorkspaceStore?
let snapshot: WorkspaceSnapshot
do {
    if let databasePath {
        let opened = try WorkspaceStore.open(path: databasePath)
        store = opened
        let loaded = opened.snapshot()
        snapshot = loaded.spaces.isEmpty ? try opened.importArcSidebar(json: sidebarJSON(path: path)) : loaded
    } else {
        store = nil
        snapshot = try importArcSidebar(json: sidebarJSON(path: path))
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}

if checkOnly {
    for space in snapshot.spaces {
        print("\(space.title): favorites \(space.favorites.count), pinned \(space.pinned.count), today \(space.today.count)")
    }
    do { try store?.flush() } catch {
        FileHandle.standardError.write(Data("cannot flush store: \(error)\n".utf8))
        exit(1)
    }
    exit(0)
}

@MainActor
final class HarnessDelegate: NSObject, NSApplicationDelegate {
    let snapshot: WorkspaceSnapshot
    let store: WorkspaceStore?
    var window: NSWindow?
    var sidebar: SidebarView?

    init(snapshot: WorkspaceSnapshot, store: WorkspaceStore?) {
        self.snapshot = snapshot
        self.store = store
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
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
        sidebar.onSelect = { row in card.show(title: row.title, url: row.url) }

        for view in [sidebar, card] {
            view.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(view)
        }
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: background.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 240),
            card.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            card.topAnchor.constraint(equalTo: background.topAnchor, constant: 6),
            card.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -7),
            card.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -7),
        ])
        window.contentView = background
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
        guard let sidebar else { return }
        let words = line.split(separator: " ", maxSplits: 1).map(String.init)
        let reply: String
        switch (words.first, words.count > 1 ? words[1] : nil) {
        case ("space", let arg?):
            guard let index = Int(arg), snapshot.spaces.indices.contains(index) else { reply = "error no space \(arg)"; break }
            sidebar.showSpace(at: index)
            reply = "ok space \(index)"
        case ("select", let id?):
            reply = sidebar.selectRow(id: id) ? "ok select \(id)" : "error no row \(id)"
        case ("state", nil):
            reply = "state space \(sidebar.spaceShown) selected \(sidebar.selectedRowID ?? "-")"
        default:
            reply = "error unknown command"
        }
        print(reply)
        fflush(stdout)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        do { try store?.flush() } catch {
            FileHandle.standardError.write(Data("cannot flush store: \(error)\n".utf8))
        }
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
app.run()
