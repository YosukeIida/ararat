import AppKit
import AraratKit
import AraratUI

let arguments = Array(CommandLine.arguments.dropFirst())
let checkOnly = arguments.first == "--check"
let path = arguments.last { $0 != "--check" }

let json: String
do {
    if let path {
        json = try String(contentsOfFile: path, encoding: .utf8)
    } else {
        let url = Bundle.module.url(forResource: "arc-sidebar-synthetic", withExtension: "json", subdirectory: "Fixtures")!
        json = try String(contentsOf: url, encoding: .utf8)
    }
} catch {
    FileHandle.standardError.write(Data("cannot read sidebar file: \(error)\n".utf8))
    exit(1)
}

let snapshot: WorkspaceSnapshot
do {
    snapshot = try importArcSidebar(json: json)
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}

if checkOnly {
    for space in snapshot.spaces {
        print("\(space.title): favorites \(space.favorites.count), pinned \(space.pinned.count), today \(space.today.count)")
    }
    exit(0)
}

@MainActor
final class HarnessDelegate: NSObject, NSApplicationDelegate {
    let snapshot: WorkspaceSnapshot
    var window: NSWindow?

    init(snapshot: WorkspaceSnapshot) { self.snapshot = snapshot }

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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@MainActor
final class PlaceholderCard: NSView {
    private let label = NSTextField(wrappingLabelWithString: "Select a tab")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
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
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = HarnessDelegate(snapshot: snapshot)
app.delegate = delegate
app.run()
