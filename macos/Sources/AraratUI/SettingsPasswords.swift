import AppKit
import AraratEngineAPI
import Darwin
import SwiftUI

@MainActor
final class SettingsPasswordsModel: ObservableObject {
    enum State: Equatable { case locked, loading, failed, empty, ready }
    enum Page { case list, detail, add, edit }

    @Published private(set) var profile: String?
    @Published private(set) var state: State = .locked
    @Published private(set) var page: Page = .list
    @Published private(set) var rows: [any ARPasswordRowAPI] = []
    @Published private(set) var selected: (any ARPasswordRowAPI)?
    @Published private(set) var busy = false
    @Published private(set) var showingPassword = false
    @Published private(set) var error: String?
    @Published var query = ""
    @Published var website = ""
    @Published var username = ""
    @Published var confirmDelete = false

    private(set) var handle: (any ARPasswordsAPI)?
    private var generation = UUID()
    private var snapshotRequest = UUID()
    private var detailRequest = UUID()
    private var authorized = false
    private var configureRequest = UUID()
    private var openWebsite: ((String) -> Void)?
    lazy var input = NSSecureTextField()
    lazy var revealed = NSTextField(labelWithString: "")

    var filtered: [any ARPasswordRowAPI] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.filter {
            term.isEmpty || $0.website.localizedStandardContains(term) || $0.username.localizedStandardContains(term)
        }
    }

    func configure(profile: String?, openWebsite: @escaping (String) -> Void,
                   load: (@escaping ((any ARPasswordsAPI)?) -> Void) -> Void) {
        close()
        self.profile = profile
        self.openWebsite = openWebsite
        let request = configureRequest
        guard profile != nil else { state = .failed; return }
        state = .loading
        load { [weak self] handle in
            guard let self, self.configureRequest == request else { return }
            self.handle = handle
            self.state = handle == nil ? .failed : .locked
        }
    }

    func close() {
        configureRequest = UUID()
        lock()
        handle?.invalidate()
        handle = nil
        profile = nil
        openWebsite = nil
    }

    func lock() {
        generation = UUID()
        authorized = false
        handle?.cancelAuthentication()
        handle?.setChangedHandler(nil)
        busy = false
        state = .locked
        rows = []
        query = ""
        list()
    }

    func unlock() {
        guard let handle, !busy, !authorized else { return }
        let request = generation
        busy = true
        error = nil
        handle.authenticate { [weak self] ok in
            guard let self, self.generation == request else { return }
            self.busy = false
            guard ok else { self.error = "Could not unlock saved passwords."; return }
            self.authorized = true
            self.state = .loading
            self.handle?.setChangedHandler { [weak self] in self?.refresh() }
            self.refresh()
        }
    }

    func refresh() {
        guard authorized, let handle else { return }
        let request = UUID()
        snapshotRequest = request
        let current = generation
        handle.snapshot { [weak self] state, rows in
            guard let self, self.generation == current, self.snapshotRequest == request else { return }
            if let selected = self.selected, !rows.contains(where: { $0.rowID == selected.rowID }) {
                self.list()
            }
            self.rows = state == .ready ? rows : []
            if state == .failed, self.busy {
                self.generation = UUID()
                self.busy = false
            }
            switch state {
            case .ready: self.state = rows.isEmpty ? .empty : .ready
            case .loading: self.state = .loading
            default: self.state = .failed
            }
        }
    }

    func detail(_ row: any ARPasswordRowAPI) {
        guard authorized, rows.contains(where: { $0.rowID == row.rowID }) else { return }
        list()
        selected = row
        page = .detail
    }

    func list() {
        clearPassword()
        clearInput()
        confirmDelete = false
        error = nil
        selected = nil
        website = ""
        username = ""
        page = .list
    }

    func add() {
        guard authorized, state == .ready || state == .empty else { return }
        list()
        page = .add
    }

    func edit() {
        guard let selected else { return }
        clearPassword()
        clearInput()
        error = nil
        username = selected.username
        page = .edit
    }

    func cancelEdit() {
        clearInput()
        error = nil
        if selected == nil { list() } else { page = .detail }
    }

    func write() {
        guard authorized, page == .add || page == .edit, let handle else { return }
        let isAdding = page == .add
        input.validateEditing()
        let value = input.stringValue as NSString
        let length = value.length
        var characters = [unichar](repeating: 0, count: length)
        let success = characters.withUnsafeMutableBufferPointer { buffer in
            defer {
                if let address = buffer.baseAddress {
                    let size = length * MemoryLayout<unichar>.stride
                    _ = memset_s(address, size, 0, size)
                }
            }
            if length > 0, let address = buffer.baseAddress {
                value.getCharacters(address, range: NSRange(location: 0, length: length))
                if isAdding {
                    return handle.addWebsite(website, username: username, password: address, length: UInt(length))
                }
            }
            guard !isAdding, let selected else { return false }
            return handle.editRow(selected.rowID, username: username,
                                  password: length == 0 ? nil : buffer.baseAddress, length: UInt(length))
        }
        clearInput()
        guard success else {
            error = isAdding ? "Could not add this password. Check the website and password, or look for an existing sign-in."
                             : "Could not update this password."
            return
        }
        list()
        refresh()
    }

    func remove() {
        guard authorized, let selected, let handle else { return }
        guard handle.deleteRow(selected.rowID) else { error = "Could not delete this password."; return }
        list()
        refresh()
    }

    func openSelectedWebsite() {
        guard let selected,
              let scheme = URL(string: selected.website)?.scheme,
              scheme == "https" || scheme == "http" else { return }
        openWebsite?(selected.website)
    }

    func toggleReveal() {
        if showingPassword { clearPassword(); return }
        guard authorized, let selected, let handle, !busy else { return }
        busy = true
        error = nil
        let request = UUID()
        detailRequest = request
        let rowID = selected.rowID
        handle.revealRow(rowID) { [weak self] password, count in
            guard let self, self.detailRequest == request else { return }
            self.busy = false
            guard let password else { self.error = "Could not show this password."; return }
            self.revealed.objectValue = NSString(characters: password, length: Int(count))
            self.showingPassword = true
        }
    }

    func copyPassword() {
        guard authorized, let selected, let handle, !busy else { return }
        busy = true
        error = nil
        let request = UUID()
        detailRequest = request
        let rowID = selected.rowID
        handle.copyRow(rowID) { [weak self] ok in
            guard let self, self.detailRequest == request else { return }
            self.busy = false
            if !ok { self.error = "Could not copy this password." }
        }
    }

    private func clearPassword() {
        detailRequest = UUID()
        if busy, selected != nil {
            handle?.cancelAuthentication()
            busy = false
        }
        if showingPassword {
            revealed.objectValue = ""
            showingPassword = false
        }
    }

    private func clearInput() {
        if page == .add || page == .edit {
            input.currentEditor()?.string = ""
            input.abortEditing()
            input.stringValue = ""
        }
    }
}

struct SettingsPasswordsSection: View {
    @ObservedObject var model: SettingsPasswordsModel
    let highlighted: String?

    var body: some View {
        VStack(spacing: SettingsMetrics.cardGap) {
            switch model.page {
            case .list: list
            case .detail: if let selected = model.selected { detail(selected) }
            case .add, .edit: form
            }
            if let error = model.error {
                Text(error).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var list: some View {
        VStack(spacing: SettingsMetrics.cardGap) {
            VStack(spacing: 8) {
                Image(systemName: "key.fill").font(.system(size: 48)).frame(height: 56)
                    .background(SettingsMarker(id: SettingsModel.headerIconMarker))
                Text("Passwords").font(.title.bold())
                    .background(SettingsMarker(id: SettingsModel.headerTitleMarker))
                Text("Saved sign-ins.").foregroundStyle(.secondary)
                    .background(SettingsMarker(id: SettingsModel.headerSubtitleMarker))
            }.padding(.vertical, 18).id("header")
            SettingsGroupCard {
                SettingsCardRow(first: true, hit: highlighted == "password-manager",
                                marker: SettingsModel.rowMarker("password-manager")) {
                    toggle("Use Ararat’s password manager",
                           subtitle: model.profile.map { "Profile: " + $0 } ?? "Profile unavailable",
                           get: { $0.enabled }, set: { _ = $0.setManagerEnabled($1) })
                }.id("password-manager")
                SettingsCardRow(hit: highlighted == "password-save", marker: SettingsModel.rowMarker("password-save")) {
                    toggle("Offer to save passwords",
                           get: { $0.offersToSave }, set: { $0.offersToSave = $1 })
                }.id("password-save")
                SettingsCardRow(hit: highlighted == "password-fill", marker: SettingsModel.rowMarker("password-fill")) {
                    toggle("Fill passwords", subtitle: "Ask for Touch ID before filling",
                           get: { $0.authenticatesBeforeFilling }, set: { $0.authenticatesBeforeFilling = $1 })
                }.id("password-fill")
            }

            SettingsGroupCard(heading: "Saved passwords", marker: "saved-passwords") {
                switch model.state {
                case .locked:
                    SettingsCardRow(first: true) {
                        Label("Passwords are locked", systemImage: "lock")
                        Spacer()
                        Button("Unlock with Touch ID…", action: model.unlock).disabled(model.busy)
                    }
                case .loading:
                    SettingsCardRow(first: true) {
                        ProgressView().controlSize(.small)
                        Text("Loading saved passwords…")
                    }
                case .failed:
                    SettingsCardRow(first: true) { Text("Saved passwords could not be loaded.") }
                case .empty, .ready:
                    SettingsCardRow(first: true) {
                        TextField("Search saved passwords", text: $model.query)
                        Button("Add…", action: model.add)
                    }
                    if model.filtered.isEmpty {
                        SettingsCardRow {
                            Text(model.state == .empty ? "No saved passwords" : "No matching passwords")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(model.filtered, id: \.rowID) { row in
                        SettingsCardRow {
                            Button { model.detail(row) } label: {
                                HStack {
                                    let site = siteName(row)
                                    SettingsSpaceIconTile(text: String(site.prefix(1)).uppercased())
                                    SettingsRowLabel(title: site, subtitle: row.username)
                                    Text("••••••••").foregroundStyle(.secondary).accessibilityHidden(true)
                                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func toggle(_ title: String, subtitle: String = "", get: @escaping (any ARPasswordsAPI) -> Bool,
                        set: @escaping (any ARPasswordsAPI, Bool) -> Void) -> some View {
        SettingsRowLabel(title: title, subtitle: subtitle)
        Toggle(title, isOn: Binding(
            get: { model.handle.map(get) ?? false },
            set: {
                if let handle = model.handle {
                    set(handle, $0)
                    model.objectWillChange.send()
                }
            }
        )).labelsHidden().toggleStyle(.switch).disabled(model.handle == nil)
    }

    private func detail(_ row: any ARPasswordRowAPI) -> some View {
        VStack(spacing: SettingsMetrics.cardGap) {
            HStack {
                Button("Saved passwords", systemImage: "chevron.left", action: model.list)
                Spacer()
                Button("Edit…", action: model.edit).disabled(model.busy)
            }
            VStack(spacing: 6) {
                SettingsSpaceIconTile(text: String(siteName(row).prefix(1)).uppercased())
                Text(siteName(row)).font(.title.bold())
                Text("Saved password").foregroundStyle(.secondary)
            }.padding(.vertical, 8)
            SettingsGroupCard {
                SettingsCardRow(first: true) {
                    Text("User name")
                    Spacer()
                    Text(row.username).textSelection(.enabled)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(row.username, forType: .string)
                    }.accessibilityLabel("Copy user name")
                }
                SettingsCardRow {
                    Text("Password")
                    Spacer()
                    if model.showingPassword {
                        PasswordAppKitField(field: model.revealed, label: "Password").frame(width: 190, height: 24)
                    } else {
                        Text("••••••••").accessibilityLabel("Password hidden")
                    }
                    Button(model.showingPassword ? "Hide" : "Show", action: model.toggleReveal).disabled(model.busy)
                    Button("Copy", action: model.copyPassword).accessibilityLabel("Copy password").disabled(model.busy)
                }
                SettingsCardRow {
                    SettingsRowLabel(title: "Website", subtitle: row.website)
                    if let scheme = URL(string: row.website)?.scheme, scheme == "http" || scheme == "https" {
                        Button("Open", action: model.openSelectedWebsite)
                    }
                }
            }
            SettingsGroupCard {
                SettingsCardRow(first: true) {
                    SettingsRowLabel(title: "Delete password", subtitle: "Ararat stops filling it on " + siteName(row))
                    Button("Delete…", role: .destructive) { model.confirmDelete = true }.disabled(model.busy)
                }
            }
        }.alert("Delete password?", isPresented: $model.confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive, action: model.remove)
        }
    }

    private var form: some View {
        VStack(spacing: SettingsMetrics.cardGap) {
            Text(model.page == .add ? "Add password" : "Edit password").font(.title.bold())
            SettingsGroupCard {
                if model.page == .add {
                    SettingsCardRow(first: true) { TextField("Website", text: $model.website) }
                }
                SettingsCardRow(first: model.page == .edit) { TextField("User name", text: $model.username) }
                SettingsCardRow {
                    let label = model.page == .edit ? "New password (optional)" : "Password"
                    Text(label)
                    Spacer()
                    PasswordAppKitField(field: model.input, label: label).frame(width: 190, height: 24)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: model.cancelEdit).keyboardShortcut(.cancelAction)
                Button("Save", action: model.write).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func siteName(_ row: any ARPasswordRowAPI) -> String {
        URL(string: row.website)?.host() ?? row.website
    }
}

private struct PasswordAppKitField: NSViewRepresentable {
    let field: NSTextField
    let label: String

    func makeNSView(context: Context) -> NSTextField {
        field.setAccessibilityLabel(label)
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {}
}
