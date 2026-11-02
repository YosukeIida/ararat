import AppKit
import AraratKit
import SwiftUI

@MainActor
public final class SettingsWindowController: NSWindowController {
    let model: SettingsModel
    private var hasOpened = false
    public init(model: SettingsModel) {
        self.model = model
        let split = NSSplitViewController()
        let rail = NSSplitViewItem(sidebarWithViewController: NSHostingController(rootView: SettingsRail(model: model)))
        rail.minimumThickness = 180
        rail.maximumThickness = 180
        rail.canCollapse = false
        split.addSplitViewItem(rail)
        split.addSplitViewItem(NSSplitViewItem(viewController: NSHostingController(rootView: SettingsDetail(model: model))))
        split.splitView.dividerStyle = .thin
        let window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 540), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentViewController = split
        window.title = "Settings"
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let toolbar = NSToolbar(identifier: "Settings")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.setFrame(NSRect(x: 0, y: 0, width: 760, height: 540), display: false)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    public func modelUpdate(snapshot: WorkspaceSnapshot) { model.update(snapshot: snapshot) }
    public func prepare(shownSpaceID: String?) {
        model.readShortcuts(NSApp.mainMenu ?? NSMenu())
        model.navigate(shownSpaceID.map(SettingsModel.Page.space) ?? .spaces)
    }
    public func open(shownSpaceID: String?) {
        if !hasOpened { window?.center(); hasOpened = true }
        prepare(shownSpaceID: shownSpaceID)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

extension SettingsWindowController: NSToolbarDelegate {
    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.init("navigation"), .flexibleSpace] }
    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.init("navigation"), .flexibleSpace] }
    public func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.view = NSHostingView(rootView: SettingsToolbar(model: model))
        return item
    }
}

private struct SettingsToolbar: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 0) {
                Button { model.go(-1) } label: { Image(systemName: "chevron.left").frame(width: 38, height: 36) }.disabled(model.historyIndex == 0).help("Back")
                Divider().frame(height: 16)
                Button { model.go(1) } label: { Image(systemName: "chevron.right").frame(width: 38, height: 36) }.disabled(model.historyIndex + 1 == model.history.count).help("Forward")
            }.buttonStyle(.plain).background(SettingsColor.capsule, in: Capsule())
            Text(model.title).font(.headline).opacity(model.headerProgress)
        }.frame(height: 52)
    }
}

private enum SettingsColor {
    static func grey(_ light: Double, _ dark: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(white: value / 255, alpha: 1)
        })
    }
    static let rail = grey(243, 42)
    static let page = grey(255, 39)
    static let card = grey(247, 46)
    static let selected = grey(215, 61)
    static let search = grey(236, 71)
    static let capsule = grey(240, 67)
    static let foreground = grey(35, 235)
}

private struct SettingsRail: View {
    @ObservedObject var model: SettingsModel
    let panes: [(SettingsModel.Page, String, String)] = [(.tabs, "Tabs", "square.on.square"), (.shortcuts, "Shortcuts", "keyboard"), (.spaces, "Spaces", "square.grid.2x2")]
    var body: some View {
        VStack(spacing: 8) {
            HStack { Image(systemName: "magnifyingglass").foregroundStyle(SettingsColor.foreground.opacity(0.6)); TextField("Search", text: $model.query).textFieldStyle(.plain) }
                .padding(.horizontal, 10).frame(height: 32).background(SettingsColor.search, in: Capsule()).padding(.top, 8)
            ScrollView {
                VStack(spacing: 2) {
                    if model.query.isEmpty {
                        ForEach(panes, id: \.1) { pane, title, icon in
                            Button { model.navigate(pane) } label: {
                                Label(title, systemImage: icon).foregroundStyle(SettingsColor.foreground).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).frame(height: 26)
                                    .background(selected(pane) ? SettingsColor.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain)
                        }
                    } else {
                        ForEach(panes, id: \.1) { pane, title, icon in
                            let hits = model.results.filter { row in row.pane == pane || (pane == .spaces && { if case .space = row.pane { return true }; return false }()) }
                            if !hits.isEmpty {
                                Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                                ForEach(Array(hits.enumerated()), id: \.offset) { _, row in
                                    Button { model.select(row) } label: { Text(model.resultTitle(row)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 26).frame(height: 26) }.buttonStyle(.plain).help(row.subtitle).accessibilityLabel(row.title + ", " + row.subtitle)
                                }
                            }
                        }
                        if model.results.isEmpty { Text("No matching settings").foregroundStyle(.secondary) }
                    }
                }
            }
        }.padding(.horizontal, 10).frame(width: 180).foregroundStyle(SettingsColor.foreground).background(SettingsColor.rail)
    }
    func selected(_ pane: SettingsModel.Page) -> Bool {
        if case .space = model.page { return pane == .spaces }
        return model.page == pane
    }
}

private struct SettingsDetail: View {
    @ObservedObject var model: SettingsModel
    @State private var offset = 0.0
    @State private var followedOffset = 0.0
    @State private var pageWidth = 580.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 10) {
                    header
                    switch model.page {
                    case .tabs:
                        card("width", title: "Sidebar width", subtitle: "Reset the sidebar to its default width of 240 pt.") { Button("Reset to default", action: model.resetWidth) }
                    case .shortcuts:
                        ForEach(model.shortcuts) { row in card(row.id, title: row.title, subtitle: row.subtitle) { SettingsKeycaps(keys: row.keys) } }
                    case .spaces:
                        VStack(spacing: 0) {
                            ForEach(Array(model.snapshot.spaces.enumerated()), id: \.element.id) { index, space in
                                Button { model.navigate(.space(space.id)) } label: {
                                    HStack {
                                        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                                        Text(space.icon ?? String(space.title.prefix(1))).frame(width: 24)
                                        Text(space.title)
                                        Spacer()
                                        Text("\(model.tabCount(space)) tabs").foregroundStyle(.secondary)
                                        if let keys = model.spaceKeys[index] { SettingsKeycaps(keys: keys) }
                                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                    }.padding(.horizontal, 12).frame(height: 44).contentShape(Rectangle())
                                }.buttonStyle(.plain).background(model.highlighted == space.id ? SettingsColor.selected : .clear)
                                    .id(space.id).draggable(space.id)
                                    .dropDestination(for: String.self) { ids, _ in
                                        guard ids.count == 1, let id = ids.first, id != space.id, model.snapshot.spaces.contains(where: { $0.id == id }) else { return false }
                                        model.move(id, to: index); return true
                                    }
                            }
                        }.background(SettingsColor.card, in: RoundedRectangle(cornerRadius: 12))
                    case .space:
                        if let space = model.space { spacePage(space) }
                    }
                    if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                }.padding(.horizontal, 19).padding(.top, 19).padding(.bottom, 20)
                    .id(model.page).offset(x: followedOffset).transition(reduceMotion ? .identity : .asymmetric(insertion: .offset(x: offset), removal: .offset(x: -offset)))
            }.onScrollGeometryChange(for: Double.self) { max(0, $0.contentOffset.y) } action: { _, y in model.headerProgress = min(1, y / 100) }
                .onChange(of: model.highlighted) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
                .onChange(of: model.page) { _, _ in if let id = model.highlighted { proxy.scrollTo(id, anchor: .center) } else { proxy.scrollTo("header", anchor: .top) } }
        }.background(SettingsColor.page)
            .onGeometryChange(for: Double.self) { $0.size.width } action: { pageWidth = $0 }
            .background(SettingsScrollBridge { event in handleScroll(event) })
            .alert("Delete Space?", isPresented: Binding(get: { model.pendingDelete != nil }, set: { if !$0 { model.pendingDelete = nil } })) {
                Button("Cancel", role: .cancel) { model.pendingDelete = nil }
                Button("Delete Space", role: .destructive) { model.confirmDelete() }
            } message: { Text("Its pinned and Today tabs will move to the Archive. Favorites will remain available in their profile. This cannot be undone.") }
    }
    var header: some View {
        VStack(spacing: 8) {
            if let space = model.space { Text(space.icon ?? String(space.title.prefix(1))).font(.system(size: 40)).frame(height: 56) }
            else { Image(systemName: model.page == .tabs ? "square.on.square" : model.page == .shortcuts ? "keyboard" : "square.grid.2x2").font(.system(size: 48)).frame(height: 56) }
            Text(model.title).font(.title.bold())
            Text(model.space.map { "\(model.tabCount($0)) tabs · \($0.profileName)" } ?? (model.page == .tabs ? "Make room for your tabs." : model.page == .shortcuts ? "Use the keyboard to move around Ararat." : "Keep related tabs together.")).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, 18).opacity(1 - model.headerProgress).id("header")
    }
    func card<Content: View>(_ id: String, title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) { Text(title); Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            Spacer(minLength: 12)
            content()
        }.padding(.horizontal, 12).frame(minHeight: 54).background(model.highlighted == id ? SettingsColor.selected : SettingsColor.card, in: RoundedRectangle(cornerRadius: 12)).id(id)
    }
    func spacePage(_ space: SpaceSnapshot) -> some View {
        VStack(spacing: 10) {
            HStack {
                Button { offset = -pageWidth; model.slide(-1) } label: { Image(systemName: "chevron.left") }.disabled(model.snapshot.spaces.first?.id == space.id).help("Previous space")
                Spacer()
                ForEach(Array(model.snapshot.spaces.enumerated()), id: \.element.id) { index, target in
                    Button {
                        guard let current = model.snapshot.spaces.firstIndex(where: { $0.id == space.id }) else { return }
                        offset = index > current ? pageWidth : -pageWidth
                        model.slide(index - current)
                    } label: {
                        Circle().fill(space.id == target.id ? Color.primary : Color.secondary.opacity(0.4)).frame(width: 6, height: 6).padding(4)
                    }.help(target.title).accessibilityLabel(target.title)
                }
                Spacer()
                Button { offset = pageWidth; model.slide(1) } label: { Image(systemName: "chevron.right") }.disabled(model.snapshot.spaces.last?.id == space.id).help("Next space")
            }.buttonStyle(.plain)
            card("name", title: "Name", subtitle: "This space") { SettingsField(value: space.title, label: "Space name") { model.rename(space.id, name: $0) }.frame(width: 220) }
            card("icon", title: "Icon", subtitle: "Choose one character · This space") {
                SettingsField(value: space.icon ?? "", label: "Space icon", characterPalette: true) { model.icon(space.id, value: $0) }.frame(width: 190)
                Button("Clear") { model.icon(space.id, value: "") }.disabled(space.icon == nil)
            }
            card("look", title: "Look", subtitle: "Colour and texture · This space") {
                Circle().fill(LinearGradient(colors: swatches(space), startPoint: .top, endPoint: .bottom)).frame(width: 24, height: 24).accessibilityLabel("Current space look")
            }
            card("profile", title: "Profile", subtitle: "Read-only · This space") { Text(space.profileName).foregroundStyle(.secondary) }
            card("delete", title: "Delete Space", subtitle: model.snapshot.spaces.count == 1 ? "The last space cannot be deleted." : "Move pinned and Today tabs to the Archive.") {
                Button("Delete Space", role: .destructive) { model.requestDelete(space.id) }.disabled(model.snapshot.spaces.count == 1)
            }
        }
    }
    func swatches(_ space: SpaceSnapshot) -> [Color] {
        guard let look = space.look else { return [SettingsColor.rail] }
        return look.colors.map { Color(red: $0.red, green: $0.green, blue: $0.blue).opacity(look.opacity) }
    }
    @State private var scroll = SpaceScrollState()
    func handleScroll(_ event: NSEvent) -> Bool {
        guard let space = model.space, let index = model.snapshot.spaces.firstIndex(where: { $0.id == space.id }) else { return false }
        let phase: SpaceScrollEvent.Phase = event.phase.contains(.began) ? .began : event.phase.contains(.ended) ? .ended : event.phase.contains(.cancelled) ? .cancelled : event.phase.isEmpty ? .none : .changed
        let action = scroll.handle(SpaceScrollEvent(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY, phase: phase, momentum: !event.momentumPhase.isEmpty, inverted: event.isDirectionInvertedFromDevice, time: event.timestamp), index: index, count: model.snapshot.spaces.count, pitch: pageWidth)
        switch action {
        case .vertical: return false
        case .follow(let value): followedOffset = SettingsModel.settingsOffset(value, index: index)
        case .settle(let target, _, _):
            offset = target > index ? pageWidth : -pageWidth
            withAnimation(reduceMotion ? nil : .spring(response: SidebarMetrics.spaceSwitchResponse, dampingFraction: SidebarMetrics.spaceSwitchDamping)) { followedOffset = 0 }
            model.slide(min(model.snapshot.spaces.count - 1, max(0, target)) - index)
        default: break
        }
        return true
    }
}

struct SettingsField: View {
    let value: String
    let label: String
    var characterPalette = false
    let commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool
    var body: some View {
        HStack {
            TextField(label, text: $draft).textFieldStyle(.roundedBorder).labelsHidden().accessibilityLabel(label).focused($focused)
            .onAppear { draft = value }.onChange(of: value) { _, value in if !focused { draft = value } }
            .onChange(of: draft) { _, next in
                guard characterPalette, next != value else { return }
                let icon = SettingsModel.iconDraft(next)
                if next != icon { draft = icon }
                commit(icon)
            }
            .onSubmit { if !characterPalette { commit(draft) } }.onChange(of: focused) { old, new in if !characterPalette && old && !new && draft != value { commit(draft) } }
            if characterPalette { Button("Choose…") { focused = true; NSApp.orderFrontCharacterPalette(nil) } }
        }
    }
}

@MainActor
final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command], event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private struct SettingsKeycaps: NSViewRepresentable {
    let keys: [String]
    func makeNSView(context: Context) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 3
        stack.setAccessibilityElement(true)
        stack.setAccessibilityRole(.group)
        return stack
    }
    func updateNSView(_ stack: NSStackView, context: Context) {
        stack.setAccessibilityLabel("Shortcut " + keys.joined())
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        for key in keys {
            let cap = TooltipKeycap(key, modifier: [])
            stack.addArrangedSubview(cap)
            cap.widthAnchor.constraint(greaterThanOrEqualToConstant: 18).isActive = true
            cap.heightAnchor.constraint(equalToConstant: 18).isActive = true
        }
    }
}

private struct SettingsScrollBridge: NSViewRepresentable {
    let handle: (NSEvent) -> Bool
    func makeNSView(context: Context) -> SettingsEventView { SettingsEventView(handle: handle) }
    func updateNSView(_ view: SettingsEventView, context: Context) { view.handle = handle }
}
private final class SettingsEventView: NSView {
    var handle: (NSEvent) -> Bool
    nonisolated(unsafe) private var monitor: Any?
    init(handle: @escaping (NSEvent) -> Bool) { self.handle = handle; super.init(frame: .zero) }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func viewDidMoveToWindow() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === self.window, self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
            return self.handle(event) ? nil : event
        }
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
