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
    public func refreshShortcuts() { model.readShortcuts() }
    public func modelUpdate(snapshot: WorkspaceSnapshot) { model.update(snapshot: snapshot) }
    public func checkResetSidebarWidth() {
        guard CommandLine.arguments.contains("--ararat-check=keyboard") else { return }
        model.resetWidth()
    }
    public func checkRenameShownSpace(_ name: String) {
        guard CommandLine.arguments.contains("--ararat-check=keyboard"), case .space(let id) = model.page else { return }
        model.rename(id, name: name)
    }
    public func retarget(snapshot: WorkspaceSnapshot, adapter: WorkspaceAdapter, publish: @escaping (WorkspaceSnapshot) -> Void,
                         resetWidth: @escaping () -> Void, preview: @escaping (String, Look?, Bool) -> Void,
                         keyBindings: KeyBindingsModel, airTraffic: AirTrafficModel) {
        model.retarget(snapshot: snapshot, adapter: adapter, publish: publish, resetWidth: resetWidth,
                       preview: preview, keyBindings: keyBindings, airTraffic: airTraffic)
    }
    public func prepare(shownSpaceID: String?) {
        model.readShortcuts()
        model.airTraffic.load()
        model.navigate(shownSpaceID.map(SettingsModel.Page.space) ?? .spaces)
    }
    public func open(shownSpaceID: String?) {
        if !hasOpened { window?.center(); hasOpened = true }
        prepare(shownSpaceID: shownSpaceID)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// The visible window and the pane the screen check reads it through (`--ararat-screen=
    /// settings-<pane>`). Nil until the controller has a window.
    public func checkProbe() -> SettingsCheckProbe? {
        guard let window else { return nil }
        return SettingsCheckProbe(controller: self, window: window)
    }

    /// Opens the window on a pane for a check: the ordinary open path (a shown space opens its
    /// space page) and then the pane's own page, which is the page the check names.
    public func checkOpen(paneID: String, shownSpaceID: String?) {
        open(shownSpaceID: shownSpaceID)
        if let page = SettingsRegistry.pane(id: paneID)?.page { model.navigate(page) }
    }

    /// Pushes a space's page, the page the Spaces rows draw, for the spaces check.
    @discardableResult
    public func checkPushSpace(_ index: Int) -> Bool {
        guard model.snapshot.spaces.indices.contains(index) else { return false }
        model.navigate(.space(model.snapshot.spaces[index].id))
        return true
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

enum SettingsColor {
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
    /// The hairline between a grouped card's rows (`--sep` on the boards).
    static let separator = grey(235, 57)
}

private struct SettingsRail: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(SettingsColor.foreground.opacity(0.6))
                TextField("Search", text: $model.query).textFieldStyle(.plain).accessibilityLabel("Search settings")
                    // The result list's keyboard model (D7): arrows move the selection, Return opens
                    // it. A text field would otherwise use the arrows for the caret.
                    .onKeyPress(.upArrow) { model.handleSearchKey(.up); return .handled }
                    .onKeyPress(.downArrow) { model.handleSearchKey(.down); return .handled }
                    .onSubmit { model.openSelectedResult() }
            }
                .padding(.horizontal, 10).frame(height: 32).background(SettingsColor.search, in: Capsule()).padding(.top, 8)
            ScrollView {
                VStack(spacing: 2) {
                    if model.query.isEmpty { paneList } else { resultList }
                }
            }
        }.padding(.horizontal, 10).frame(width: 180).foregroundStyle(SettingsColor.foreground).background(SettingsColor.rail)
            .background(SettingsMarker(id: SettingsModel.railMarkerID))
    }

    private var paneList: some View {
        ForEach(model.panes) { pane in
            Button { if let page = pane.page { model.navigate(page) } } label: {
                Label(pane.title, systemImage: pane.icon).foregroundStyle(SettingsColor.foreground).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).frame(height: 26)
                    .background(selected(pane) ? SettingsColor.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(.plain).accessibilityLabel(pane.title)
                .background(SettingsMarker(id: pane.railMarker))
        }
    }

    @ViewBuilder
    private var resultList: some View {
        ForEach(model.resultGroups, id: \.pane.id) { group in
            Label(group.pane.title, systemImage: group.pane.icon).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                .background(SettingsMarker(id: group.pane.groupMarker))
            ForEach(Array(group.rows.enumerated()), id: \.offset) { _, row in
                let hit = model.selectedResult.map { $0.pane.searchKey == row.pane.searchKey && $0.id == row.id } ?? false
                Button { model.select(row) } label: {
                    Text(model.resultTitle(row)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 26).frame(height: 26)
                }.buttonStyle(.plain).help(row.subtitle).accessibilityLabel(row.title + ", " + row.subtitle)
                    .background(SettingsMarker(id: SettingsModel.resultMarker(row)))
                    .background { if hit { SettingsMarker(id: SettingsModel.selectedResultMarker) } }
            }
        }
        if model.results.isEmpty {
            Text("No matching settings").foregroundStyle(.secondary).background(SettingsMarker(id: SettingsModel.noResultsMarker))
        }
    }

    func selected(_ pane: SettingsPane) -> Bool {
        if case .space = model.page { return pane.id == .spaces }
        return model.page == pane.page
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
                        card("archive-after", title: "Archive Today's tabs after", subtitle: model.archiveSubtitle) {
                            Picker("Archive Today's tabs after", selection: Binding(get: { model.archiveAfter }, set: model.setArchiveAfter)) {
                                Text("12 hours").tag(ArchiveAfter.hours12)
                                Text("24 hours").tag(ArchiveAfter.hours24)
                                Text("7 days").tag(ArchiveAfter.days7)
                                Text("30 days").tag(ArchiveAfter.days30)
                            }.labelsHidden()
                        }
                    case .shortcuts:
                        SettingsShortcutsSection(model: model, keyBindings: model.keyBindings)
                    case .airTraffic:
                        SettingsAirTrafficSection(model: model, airTraffic: model.airTraffic)
                    case .spaces:
                        VStack(spacing: 0) {
                            ForEach(Array(model.snapshot.spaces.enumerated()), id: \.element.id) { index, space in
                                Button { model.navigate(.space(space.id)) } label: {
                                    HStack {
                                        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                                        Text(space.icon ?? String(space.title.prefix(1))).frame(width: 24)
                                        Text(space.title)
                                        Spacer()
                                        Text(model.tabCountLabel(space)).foregroundStyle(.secondary)
                                        if let keys = model.spaceKeys[index] { SettingsKeycaps(keys: keys) }
                                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                    }.padding(.horizontal, 12).frame(height: 44).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                    .background { if model.highlighted == space.id { SettingsHitFill() } }
                                    .background(SettingsMarker(id: SettingsModel.rowMarker("space-\(space.id)")))
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
            if let space = model.space {
                Text(space.icon ?? String(space.title.prefix(1))).font(.system(size: 40)).frame(height: 56)
                    .background(SettingsMarker(id: SettingsModel.headerIconMarker))
            } else {
                Image(systemName: model.icon).font(.system(size: 48)).frame(height: 56)
                    .background(SettingsMarker(id: SettingsModel.headerIconMarker))
            }
            Text(model.title).font(.title.bold()).background(SettingsMarker(id: SettingsModel.headerTitleMarker))
            Text(model.subtitle).foregroundStyle(.secondary).background(SettingsMarker(id: SettingsModel.headerSubtitleMarker))
        }.frame(maxWidth: .infinity).padding(.vertical, 18).opacity(1 - model.headerProgress).id("header")
    }
    /// One row per card (the panes built before U27 keep this look, D6). A search hit fills the
    /// row's inside with the selection grey, inset 3 pt at radius 9 (D7).
    func card<Content: View>(_ id: String, title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        let hit = model.highlighted == id
        return HStack {
            VStack(alignment: .leading, spacing: 3) { Text(title); Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            Spacer(minLength: 12)
            content()
        }.padding(.horizontal, 12).frame(minHeight: 54)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius).fill(SettingsColor.card)
                    if hit { SettingsHitFill() }
                }
            }
            .background(SettingsMarker(id: SettingsModel.rowMarker(id)))
            .id(id)
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
                LookPopoverButton(settings: model, space: space).frame(width: 30, height: 30)
            }
            card("profile", title: "Profile", subtitle: "Read-only · This space") { Text(space.profileName).foregroundStyle(.secondary) }
            card("delete", title: "Delete Space", subtitle: model.snapshot.spaces.count == 1 ? "The last space cannot be deleted." : "Move pinned and Today tabs to the Archive.") {
                Button("Delete Space", role: .destructive) { model.requestDelete(space.id) }.disabled(model.snapshot.spaces.count == 1)
            }
        }
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

/// The Shortcuts pane: a search field over action names and keys, the Customized/Conflicting filter
/// menu and ⋯ › Reset All like Cra's pane, rows showing the effective key (click it to record,
/// right-click for Reset/Remove), and the recorder view. Obtained from Cra's MIT
/// `Sources/Cra/UI/Settings/ShortcutsPane.swift`.
private struct SettingsShortcutsSection: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var keyBindings: KeyBindingsModel

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search", text: $model.shortcutQuery).textFieldStyle(.plain).accessibilityLabel("Search shortcuts")
                }
                .padding(.horizontal, 10).frame(height: 30).background(SettingsColor.capsule, in: Capsule())
                filterButton
                resetAllButton
            }
            if let error = keyBindings.error, keyBindings.errorCommand == nil
                || !model.filteredShortcuts.contains(where: { $0.command == keyBindings.errorCommand }) {
                ShortcutRefusal(text: error, id: "refusal-pane").help("The last recording was refused")
            }
            ForEach(model.filteredShortcuts) { row in rowCard(row) }
            if model.filteredShortcuts.isEmpty && !model.shortcuts.isEmpty { Text("No matching shortcuts").foregroundStyle(.secondary) }
        }
        .background(ShortcutsRecorderBridge(keyBindings: keyBindings).frame(width: 1, height: 1))
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var filterButton: some View {
        Menu {
            Toggle("Customized Shortcuts", isOn: $model.customizedOnly)
            Toggle("Conflicting Shortcuts", isOn: $model.conflictingOnly)
        } label: {
            Image(systemName: "line.3.horizontal.decrease").font(.system(size: 14, weight: .medium)).frame(width: 30, height: 30)
        }
        .menuIndicator(.hidden).menuStyle(.borderlessButton).fixedSize()
        .help("Show customized or conflicting shortcuts")
    }

    private var resetAllButton: some View {
        Menu {
            Button("Reset All Shortcuts") { model.resetAllShortcuts() }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 14, weight: .medium)).frame(width: 30, height: 30)
        }
        .menuIndicator(.hidden).menuStyle(.borderlessButton).fixedSize()
        .help("Reset all shortcuts to their defaults")
    }

    @ViewBuilder
    private func rowCard(_ row: SettingsModel.Row) -> some View {
        let recording = recording(on: row)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title).lineLimit(1)
                Text(row.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .background(ShortcutLayoutMarker(id: "description-\(row.id)"))
                if let holder = recording?.holder {
                    Text("Held by \(holder) — press again to take it").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .background(ShortcutLayoutMarker(id: "message-\(row.id)"))
                } else if row.command == keyBindings.errorCommand, let error = keyBindings.error {
                    ShortcutRefusal(text: error, id: "message-\(row.id)")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button { if let command = row.command { model.toggleRecording(command) } } label: {
                keyFace(row, recording).frame(width: 140, alignment: .trailing)
                    .background(ShortcutLayoutMarker(id: "column-\(row.id)"))
            }
                .buttonStyle(.plain)
                .accessibilityLabel("Record shortcut for \(row.title)")
        }
        .padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: 54)
        .background(ShortcutLayoutMarker(id: "row-\(row.id)"))
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius).fill(SettingsColor.card)
                if model.highlighted == row.id { SettingsHitFill() }
            }
        }
        .id(row.id)
        .contextMenu {
            if let command = row.command, let binding = keyBindings.binding(command: command) {
                Button("Reset to Default") { model.resetShortcut(command) }.disabled(!binding.customized)
                Button("Remove Shortcut") { model.removeShortcut(command) }.disabled(binding.key == nil && !binding.conflicting)
            }
        }
    }

    private func recording(on row: SettingsModel.Row) -> KeyBindingsModel.Recording? {
        guard let command = row.command, let state = keyBindings.recording, state.command == command else { return nil }
        return state
    }

    @ViewBuilder
    private func keyFace(_ row: SettingsModel.Row, _ recording: KeyBindingsModel.Recording?) -> some View {
        if let recording {
            Text(recording.candidate.map { SidebarTooltip.display(for: $0) } ?? "Type shortcut")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(recording.candidate == nil ? Color.secondary : Color.primary)
                .frame(maxWidth: .infinity, alignment: .trailing).padding(.horizontal, 8).frame(height: 30)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 1))
                .background(ShortcutLayoutMarker(id: "recorder-\(row.id)"))
        } else if row.conflicting, !row.keys.isEmpty {
            // The lost key must not read as a working one: the caption marks what the caps are.
            SettingsKeycaps(keys: row.keys, caption: "Conflicting", id: "content-\(row.id)").fixedSize()
                .background(ShortcutLayoutMarker(id: "face-\(row.id)"))
        } else if row.keys.isEmpty {
            Text("None").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                .background(ShortcutLayoutMarker(id: "content-\(row.id)"))
                .frame(maxWidth: .infinity, alignment: .trailing).frame(height: 30)
        } else {
            SettingsKeycaps(keys: row.keys, id: "content-\(row.id)").fixedSize()
        }
    }
}

private struct ShortcutRefusal: NSViewRepresentable {
    let text: String
    let id: String
    func makeNSView(context: Context) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .systemRed
        label.identifier = NSUserInterfaceItemIdentifier(id)
        return label
    }
    func updateNSView(_ label: NSTextField, context: Context) { label.stringValue = text }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        let width = proposal.width ?? nsView.intrinsicContentSize.width
        let height = nsView.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height ?? 14
        return CGSize(width: width, height: height)
    }
}

private struct ShortcutLayoutMarker: NSViewRepresentable {
    let id: String
    func makeNSView(context: Context) -> ShortcutMarkerView {
        let view = ShortcutMarkerView()
        view.identifier = NSUserInterfaceItemIdentifier(id)
        return view
    }
    func updateNSView(_ view: ShortcutMarkerView, context: Context) { view.identifier = NSUserInterfaceItemIdentifier(id) }
}

private final class ShortcutMarkerView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The Air Traffic Control pane: the rules in order (drag to reorder feeds the
/// model's `move`, tests never drag), each row edited in place with the match style, the URL
/// text and the destination menu, a New Route button, the default destination card and a test
/// field answered by the core's `route`. The one-two-line-route row and the destination menu
/// (Most Recent Space, the spaces, then Little Arc after a separator) are reused from Cra's
/// MIT `Sources/Cra/UI/Settings/AirTrafficControlView.swift`; pane shell, card look and drag
/// behaviour are ours (the Spaces pane's).
private struct SettingsAirTrafficSection: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var airTraffic: AirTrafficModel
    @State private var probe = ""

    var body: some View {
        VStack(spacing: 10) {
            if let error = airTraffic.error { Text(error).foregroundStyle(.red).help("The last change was refused") }
            ruleList
            defaultCard
            testCard
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var rules: [Rule] { airTraffic.routing?.rules ?? [] }

    private var ruleList: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Routes").font(.headline)
                Spacer(minLength: 12)
                Button("New Route") {
                    airTraffic.add(destination: model.newRouteDestination(), profile: model.airTrafficLittleWindowProfile)
                }
            }
            .padding(.vertical, 2)
            ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                ruleCard(rule, position: index + 1)
            }
            if rules.isEmpty {
                Text("No routes yet. Links other apps hand over go to the default destination.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func ruleCard(_ rule: Rule, position: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                matchPicker(rule)
                urlField(rule, position: position)
                Button {
                    airTraffic.delete(rule.id)
                } label: { Image(systemName: "minus.circle.fill") }
                    .buttonStyle(.plain)
                    .accessibilityLabel(SettingsModel.routeDeleteAccessibilityLabel(position))
                    .help("Delete this route")
            }
            HStack(spacing: 8) {
                Text("Open in").foregroundStyle(.secondary)
                destinationPicker(rule)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 64)
        .background(SettingsColor.card, in: RoundedRectangle(cornerRadius: 12))
        .draggable(rule.id)
        .dropDestination(for: String.self) { ids, _ in
            guard ids.count == 1, let id = ids.first, id != rule.id else { return false }
            airTraffic.move(id, to: rules.firstIndex(where: { $0.id == rule.id }) ?? 0)
            return true
        }
    }

    private func matchPicker(_ rule: Rule) -> some View {
        Picker("Match", selection: Binding(
            get: { rule.conditions.first?.style ?? .contains },
            set: { airTraffic.editCondition(rule.id, style: $0, text: rule.conditions.first?.text ?? "") })) {
            Text("Contains").tag(MatchStyle.contains)
            Text("Is equal to").tag(MatchStyle.equals)
        }
        .labelsHidden()
        .frame(width: 120)
    }

    private func urlField(_ rule: Rule, position: Int) -> some View {
        SettingsField(value: rule.conditions.first?.text ?? "", label: "URL",
            accessibility: SettingsModel.routeUrlAccessibilityLabel(position)) {
            airTraffic.editCondition(rule.id, style: rule.conditions.first?.style ?? .contains, text: $0)
        }
    }

    private func destinationPicker(_ rule: Rule) -> some View {
        Picker("Open in", selection: Binding(
            get: { DestinationChoice(rule.destination, deletedSpaces: airTraffic.deletedSpaces) },
            set: { airTraffic.editDestination(rule.id, choice: $0) })) {
            pickerContext
        }
        .labelsHidden()
        .frame(width: 190)
    }

    @ViewBuilder private var pickerContext: some View {
        // Built from `DestinationChoice.menuTags(spaces:deletedSpaceIds:)`: the tag-coverage
        // test reads this menu through the helper, not a copy of it. A destination naming a
        // space the core flagged as gone gets one disabled "Deleted space" item, selected,
        // ahead of the spaces; only the ids this section's own destinations lost appear.
        let tags = DestinationChoice.menuTags(spaces: model.snapshot.spaces,
            deletedSpaceIds: airTraffic.deletedSpaceIds)
        ForEach(tags.filter(\.isDeletedSpace), id: \.self) { tag in
            Text(tag.menuTitle(spaces: model.snapshot.spaces)).tag(tag).disabled(true)
        }
        Section("Open in Space") {
            ForEach(tags.filter { !$0.isDeletedSpace && $0 != .littleWindow }, id: \.self) { tag in
                Text(tag.menuTitle(spaces: model.snapshot.spaces)).tag(tag)
            }
        }
        Divider()
        ForEach(tags.filter { $0 == .littleWindow }, id: \.self) { tag in
            Text(tag.menuTitle(spaces: model.snapshot.spaces)).tag(tag)
        }
    }

    private var defaultCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Default destination")
                Text("Where links land when no route takes them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Picker("Default destination", selection: Binding(
                get: { model.defaultChoice },
                set: { airTraffic.setDefault($0, littleWindowProfile: model.airTrafficLittleWindowProfile) })) {
                pickerContext
            }
            .labelsHidden()
            .frame(width: 190)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 54)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius).fill(SettingsColor.card)
                if model.highlighted == SettingsModel.airTrafficCardId { SettingsHitFill() }
            }
        }
        .background(SettingsMarker(id: SettingsModel.rowMarker(SettingsModel.airTrafficCardId)))
        .id(SettingsModel.airTrafficCardId)
    }

    private var testCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Test a link")
                Text(answer).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            TextField("https://…", text: $probe).textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onChange(of: probe) { _, probe in ask(probe) }
                .onSubmit { ask(probe) }
                .accessibilityLabel("Test link")
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 54)
        .background(SettingsColor.card, in: RoundedRectangle(cornerRadius: 12))
        .background(SettingsMarker(id: SettingsModel.rowMarker("atc-test")))
        .id("atc-test")
    }

    private func ask(_ probe: String) {
        // The empty gate lives here, not in `decide`: the model stays able to say where an
        // empty link lands, and the pane just never asks it that.
        guard !probe.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        airTraffic.decide(probe)
    }

    private var answer: String {
        if let answer = airTraffic.testAnswer, answer.url == probe.trimmingCharacters(in: .whitespacesAndNewlines) {
            let routing = airTraffic.routing
            let decision = answer.decision
            let rules = routing?.rules ?? []
            return AirTrafficModel.answerLabel(url: answer.url, decision: decision, rules: rules, spaces: model.snapshot.spaces)
        }
        return "Type a link to see which route (or the default) takes it."
    }
}

struct SettingsField: View {
    let value: String
    let label: String
    var characterPalette = false
    var accessibility: String? = nil
    let commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool
    var body: some View {
        HStack {
            TextField(label, text: $draft).textFieldStyle(.roundedBorder).labelsHidden().accessibilityLabel(accessibility ?? label).focused($focused)
            .onAppear { draft = value }.onChange(of: value) { _, value in if !focused { draft = value } }
            .onChange(of: draft) { _, next in
                guard characterPalette, next != value else { return }
                let icon = SettingsModel.iconDraft(next, stored: value)
                if next != icon { draft = icon }
                commit(icon)
            }
            .onSubmit { if !characterPalette { commit(draft) } }.onChange(of: focused) { old, new in if !characterPalette && old && !new && draft != value { commit(draft) } }
            if characterPalette { Button("Choose…") { focused = true; NSApp.orderFrontCharacterPalette(nil) } }
        }
    }
}

@MainActor
final class SettingsWindow: NSWindow, MenuCommandHost {
    var menuCommandBindings: [KeyBinding] { (windowController as? SettingsWindowController)?.model.keyBindings.bindings ?? [] }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // A recording recorder sees the key first, so a guarded ⌘W is refused instead of closing.
        if let recorder = firstResponder as? ShortcutsRecorderView, recorder.performKeyEquivalent(with: event) { return true }
        // A table command rebound without Command yields to one of our text fields (the search):
        // the key is claimed here and typed into the field instead of reaching the menu pass.
        if WorkspaceCommands.yieldsToOwnField(menuCommandBindings, event: event, in: self) {
            firstResponder?.keyDown(with: event)
            return true
        }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command], event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private struct SettingsKeycaps: NSViewRepresentable {
    let keys: [String]
    var caption: String? = nil
    var id: String? = nil
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
        stack.orientation = caption == nil ? .horizontal : .vertical
        stack.alignment = caption == nil ? .centerY : .trailing
        stack.spacing = caption == nil ? 3 : 2
        let caps = caption == nil ? stack : NSStackView()
        caps.orientation = .horizontal
        caps.spacing = 3
        caps.identifier = id.map { NSUserInterfaceItemIdentifier($0) }
        for key in keys {
            let cap = TooltipKeycap(key, modifier: [])
            caps.addArrangedSubview(cap)
            cap.widthAnchor.constraint(greaterThanOrEqualToConstant: 18).isActive = true
            cap.heightAnchor.constraint(equalToConstant: 18).isActive = true
        }
        if let caption {
            stack.addArrangedSubview(caps)
            let label = NSTextField(labelWithString: caption)
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.setAccessibilityLabel(caption)
            stack.addArrangedSubview(label)
            label.heightAnchor.constraint(equalToConstant: 18).isActive = true
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
