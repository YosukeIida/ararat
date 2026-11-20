import AppKit
import SwiftUI

public enum SettingsUpdateState: Equatable, Sendable {
    case unavailable, notChecked, upToDate(Date), checking
    case available(String), downloading(String, Double?), ready(String), failed(String), noCompatibleUpdate(String)

    var row: (title: String, detail: String?, button: String?) {
        switch self {
        case .unavailable: ("Updates are unavailable", nil, nil)
        case .notChecked: ("No recent update check", nil, "Check for Updates")
        case .upToDate(let date): ("Ararat is up to date", "Checked " + date.formatted(.relative(presentation: .named)), "Check for Updates")
        case .noCompatibleUpdate(let message): ("No compatible update", message, "Check for Updates")
        case .checking: ("Checking for updates…", nil, nil)
        case .available(let version): ("Ararat \(version) is available", nil, "Check for Updates")
        case .downloading(let version, _): ("Downloading Ararat \(version)…", nil, nil)
        case .ready(let version): ("Ararat \(version) is ready", "Restarting brings your windows back", "Restart to Update")
        case .failed(let message): ("Couldn’t check for updates", message, "Try Again")
        }
    }
}

@MainActor
public protocol SettingsUpdater: AnyObject {
    var state: SettingsUpdateState { get }
    var canCheck: Bool { get }
    var automaticallyChecks: Bool? { get set }
    func checkNow()
    func restartToUpdate()
}

struct SettingsAboutSection: View {
    @ObservedObject var model: SettingsModel
    @State private var showsAcknowledgements = false

    private var state: SettingsUpdateState { model.aboutUpdater?.state ?? .unavailable }

    var automaticChecks: Binding<Bool> {
        Binding(
            get: { model.aboutUpdater?.automaticallyChecks ?? false },
            set: { model.aboutUpdater?.automaticallyChecks = $0 }
        )
    }

    var body: some View {
        let status = state.row
        let ready = if case .ready = state { true } else { false }
        SettingsGroupCard {
            row("about-updates", first: true) {
                label(status.title, detail: status.detail)
                if let button = status.button {
                    Button(button) {
                        if ready {
                            model.aboutUpdater?.restartToUpdate()
                        } else {
                            model.aboutUpdater?.checkNow()
                        }
                    }.disabled(!ready && model.aboutUpdater?.canCheck != true)
                } else if case .checking = state {
                    ProgressView().controlSize(.small).accessibilityLabel("Checking for updates")
                } else if case .downloading(_, let progress) = state {
                    ProgressView(value: progress).progressViewStyle(.linear).frame(width: 160).accessibilityLabel("Downloading update")
                }
            }
        }
        SettingsGroupCard {
            row("about-automatic", first: true) {
                Toggle("Check for updates automatically", isOn: automaticChecks).toggleStyle(.switch).controlSize(.small).disabled(model.aboutUpdater?.automaticallyChecks == nil)
            }
        }
        SettingsGroupCard {
            link("about-licence", title: "Licence", detail: "GNU General Public License v3.0", first: true,
                 enabled: model.aboutLicence != nil) {
                if let url = model.aboutLicence { NSWorkspace.shared.open(url) }
            }
            link("about-source", title: "Source code",
                 detail: model.aboutSource == nil ? "Unavailable for this build" : nil,
                 enabled: model.aboutSource != nil) {
                if let url = model.aboutSource { NSWorkspace.shared.open(url) }
            }
            link("about-acknowledgements", title: "Acknowledgements", detail: "Chromium, Ardia, Cra and other open-source software") {
                showsAcknowledgements = true
            }
        }
        .sheet(isPresented: $showsAcknowledgements) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Acknowledgements").font(.headline)
                Button("Chromium Credits") {
                    showsAcknowledgements = false
                    model.openChromiumCredits?()
                }.disabled(model.openChromiumCredits == nil)
                ForEach(SettingsModel.aboutNotices(), id: \.name) { notice in
                    Button(notice.name) { NSWorkspace.shared.open(notice.url) }
                }
                Button("Done") { showsAcknowledgements = false }
                    .keyboardShortcut(.defaultAction)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }.padding(20).frame(width: 360)
        }
    }

    private func row<Content: View>(_ id: String, first: Bool, @ViewBuilder content: () -> Content) -> some View {
        SettingsCardRow(first: first, hit: model.highlighted == id, marker: SettingsModel.rowMarker(id), content: content)
            .id(id)
    }

    private func label(_ title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func link(_ id: String, title: String, detail: String? = nil, first: Bool = false,
                      enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            row(id, first: first) {
                label(title, detail: detail)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary).accessibilityHidden(true)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!enabled)
    }
}
