import AppKit
import AraratEngineAPI
import Darwin
import SwiftUI

@MainActor
final class SettingsPasswordsModel: ObservableObject {
    enum State: Equatable { case locked, loading, failed, empty, ready }
    enum Page { case list, detail, add }

    @Published private(set) var profile: String?
    @Published private(set) var state: State = .locked
    @Published private(set) var page: Page = .list
    @Published private(set) var rows: [any ARPasswordRowAPI] = []
    @Published private(set) var selected: (any ARPasswordRowAPI)?
    @Published private(set) var busy = false
    @Published private(set) var showingPassword = false
    @Published private(set) var passwordChanged = false
    @Published private(set) var error: String?
    @Published var query = ""
    @Published var website = ""
    @Published var username = ""
    @Published var confirmDelete = false
    @Published var confirmDiscardPassword = false

    private(set) var handle: (any ARPasswordsAPI)?
    private var generation = UUID()
    private var snapshotRequest = UUID()
    private var detailRequest = UUID()
    private var authorized = false
    private var configureRequest = UUID()
    private var openWebsite: ((String) -> Void)?
    lazy var input = NSSecureTextField()
    lazy var revealed: NSTextField = {
        let field = NSTextField()
        field.cell = RevealedPasswordCell(textCell: "")
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = true
        field.drawsBackground = true
        return field
    }()

    var showsFillAuthentication: Bool { handle?.showsFillAuthentication == true }
    var authenticatesBeforeFilling: Bool { handle?.authenticatesBeforeFilling == true }

    func setManagerEnabled(_ enabled: Bool) {
        guard let handle else { return }
        _ = handle.setManagerEnabled(enabled)
        objectWillChange.send()
    }

    func setAuthenticatesBeforeFilling(_ enabled: Bool) {
        guard let handle, showsFillAuthentication, !busy,
              enabled != authenticatesBeforeFilling else { return }
        let request = generation
        busy = true
        error = nil
        handle.setAuthenticatesBeforeFilling(enabled) { [weak self] changed in
            guard let self, self.generation == request else { return }
            self.busy = false
            if !changed { self.error = "Could not change authentication before filling." }
        }
    }

    var canSaveDetail: Bool {
        guard let selected, !busy else { return false }
        return passwordChanged || username != selected.username
    }

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
                self.handle?.cancelAuthentication()
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
        username = row.username
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

    func passwordDidChange() {
        if showingPassword { passwordChanged = true }
    }

    func saveDetail() {
        guard authorized, canSaveDetail, let handle, let selected else { return }
        let success: Bool
        if passwordChanged {
            success = withPassword(in: revealed) { password, length in
                guard let password else { return false }
                return handle.editRow(selected.rowID, username: username, password: password, length: length)
            }
        } else {
            success = handle.editRow(selected.rowID, username: username, password: nil, length: 0)
        }
        clearPassword()
        guard success else { error = "Could not update this password."; return }
        list()
        refresh()
    }

    func write() {
        guard authorized, page == .add, let handle else { return }
        let success = withPassword(in: input) { password, length in
            guard let password else { return false }
            return handle.addWebsite(website, username: username, password: password, length: length)
        }
        clearInput()
        guard success else {
            error = "Could not add this password. Check the website and password, or look for an existing sign-in."
            return
        }
        list()
        refresh()
    }

    private func withPassword(in field: NSTextField,
                              _ action: (UnsafePointer<unichar>?, UInt) -> Bool) -> Bool {
        field.validateEditing()
        guard let value = field.objectValue as? NSString, value.length > 0 else {
            return action(nil, 0)
        }
        let length = value.length
        var characters = [unichar](repeating: 0, count: length)
        return characters.withUnsafeMutableBufferPointer { buffer in
            guard let address = buffer.baseAddress else { return false }
            defer {
                let size = length * MemoryLayout<unichar>.stride
                _ = memset_s(address, size, 0, size)
            }
            value.getCharacters(address, range: NSRange(location: 0, length: length))
            return action(address, UInt(length))
        }
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
        if showingPassword {
            if passwordChanged { confirmDiscardPassword = true }
            else { clearPassword() }
            return
        }
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

    func discardPasswordEdit() {
        guard showingPassword, passwordChanged else { return }
        clearPassword()
    }

    private func clearPassword() {
        confirmDiscardPassword = false
        detailRequest = UUID()
        if busy, selected != nil {
            handle?.cancelAuthentication()
            busy = false
        }
        if showingPassword {
            revealed.abortEditing()
            (revealed.cell as? RevealedPasswordCell)?.clearEditor()
            revealed.objectValue = ""
            passwordChanged = false
            showingPassword = false
        }
    }

    private func clearInput() {
        if page == .add {
            input.currentEditor()?.string = ""
            input.abortEditing()
            input.objectValue = ""
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
            case .add: form
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
                    SettingsRowLabel(title: "Use Ararat’s password manager",
                                     subtitle: model.profile.map { "Profile: " + $0 } ?? "Profile unavailable")
                    Toggle("Use Ararat’s password manager", isOn: Binding(
                        get: { model.handle?.enabled == true }, set: model.setManagerEnabled
                    )).labelsHidden().toggleStyle(.switch).disabled(model.handle == nil)
                }.id("password-manager")
                SettingsCardRow(hit: highlighted == "password-save", marker: SettingsModel.rowMarker("password-save")) {
                    toggle("Offer to save passwords",
                           get: { $0.offersToSave }, set: { $0.offersToSave = $1 })
                }.id("password-save")
                if model.showsFillAuthentication {
                    SettingsCardRow(hit: highlighted == "password-fill", marker: SettingsModel.rowMarker("password-fill")) {
                        SettingsRowLabel(title: "Fill passwords", subtitle: "Touch ID is asked before filling")
                        Toggle("Touch ID is asked before filling", isOn: Binding(
                            get: { model.authenticatesBeforeFilling }, set: model.setAuthenticatesBeforeFilling
                        )).labelsHidden().toggleStyle(.switch).disabled(model.busy)
                    }.id("password-fill")
                }
            }

            SettingsGroupHeading(title: "Saved passwords", marker: "saved-passwords-heading")
            if model.state == .empty || model.state == .ready {
                HStack {
                    if model.state == .ready {
                        TextField("Search passwords", text: $model.query).frame(maxWidth: 290)
                            .background(SettingsMarker(id: "passwords-search"))
                    }
                    Spacer()
                    Button("Add…", action: model.add)
                }
            }
            SettingsGroupCard(marker: "saved-passwords") {
                switch model.state {
                case .locked:
                    SettingsCardRow(first: true) {
                        Label("Passwords are locked", systemImage: "lock")
                        Spacer()
                        Button("Unlock with Touch ID…", action: model.unlock).disabled(model.busy)
                            .background(SettingsMarker(id: "passwords-unlock"))
                    }
                case .loading:
                    SettingsCardRow(first: true) {
                        ProgressView().controlSize(.small)
                        Text("Loading saved passwords…")
                    }
                case .failed:
                    SettingsCardRow(first: true) { Text("Saved passwords could not be loaded.") }
                case .empty, .ready:
                    let rows = model.filtered
                    if rows.isEmpty {
                        SettingsCardRow(first: true) {
                            Text(model.state == .empty ? "No saved passwords." : "No matching passwords.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(rows, id: \.rowID) { row in
                        SettingsCardRow(first: row.rowID == rows.first?.rowID) {
                            Button { model.detail(row) } label: {
                                HStack {
                                    let site = siteName(row)
                                    SettingsSpaceIconTile(text: String(site.prefix(1)).uppercased())
                                    SettingsRowLabel(title: site, subtitle: row.username)
                                    Text("••••••••").foregroundStyle(.secondary).accessibilityHidden(true)
                                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }.background(SettingsMarker(id: "passwords-result"))
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
                    TextField("User name", text: $model.username).labelsHidden().frame(width: 220)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(row.username, forType: .string)
                    }.accessibilityLabel("Copy user name")
                }
                SettingsCardRow {
                    Text("Password")
                    Spacer()
                    if model.showingPassword {
                        PasswordAppKitField(field: model.revealed, label: "Password", didChange: model.passwordDidChange)
                            .frame(width: 220, height: 24)
                            .background(SettingsMarker(id: "passwords-revealed"))
                    } else {
                        TextField("Password", text: .constant("••••••••")).labelsHidden().disabled(true)
                            .accessibilityLabel("Password hidden").frame(width: 220)
                            .background(SettingsMarker(id: "passwords-hidden"))
                    }
                    Button(model.showingPassword ? "Hide" : "Show", action: model.toggleReveal).disabled(model.busy)
                }
                SettingsCardRow {
                    SettingsRowLabel(title: "Website", subtitle: row.website)
                    if let scheme = URL(string: row.website)?.scheme, scheme == "http" || scheme == "https" {
                        Button("Open", action: model.openSelectedWebsite)
                    }
                }
            }
            if model.canSaveDetail {
                Button("Save Changes", action: model.saveDetail).keyboardShortcut(.defaultAction)
                    .frame(maxWidth: .infinity, alignment: .trailing)
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
        }.alert("Discard the password edit?", isPresented: $model.confirmDiscardPassword) {
            Button("Keep Editing", role: .cancel) {}.keyboardShortcut(.defaultAction)
            Button("Discard Password Edit", role: .destructive, action: model.discardPasswordEdit)
        }
    }

    private var form: some View {
        VStack(spacing: SettingsMetrics.cardGap) {
            Text("Add password").font(.title.bold())
            SettingsGroupCard {
                SettingsCardRow(first: true) { TextField("Website", text: $model.website) }
                SettingsCardRow { TextField("User name", text: $model.username) }
                SettingsCardRow {
                    Text("Password")
                    Spacer()
                    PasswordAppKitField(field: model.input, label: "Password").frame(width: 190, height: 24)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: model.list).keyboardShortcut(.cancelAction)
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
    var didChange: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextField {
        field.setAccessibilityLabel(label)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.didChange = didChange
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var didChange: (() -> Void)?

        func controlTextDidChange(_ notification: Notification) {
            didChange?()
        }
    }
}

private final class RevealedPasswordCell: NSTextFieldCell {
    private let editor = NSTextView()

    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        editor.isFieldEditor = true
        editor.writingToolsBehavior = .none
        editor.allowsUndo = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        return editor
    }

    func clearEditor() { editor.string = "" }
}
