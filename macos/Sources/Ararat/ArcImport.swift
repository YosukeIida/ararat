import AppKit
import AraratUI

extension Runtime {
    static var onboardingCheckMode: Bool {
        CommandLine.arguments.contains { $0.hasPrefix("--ararat-check=") || $0.hasPrefix("--ararat-screen=") }
    }

    static var onboardingEntryVisible: Bool {
        onboardingEntryVisible(checkMode: onboardingCheckMode, detector: LaunchServicesSourceDetector())
    }

    static func onboardingEntryVisible(checkMode: Bool, detector: OnboardingSourceDetector) -> Bool {
        checkMode || detector.isArcInstalled()
    }

    func openOnboarding() {
        if Runtime.onboardingCheckMode {
            openOnboardingCheck()
            return
        }
        guard Runtime.onboardingEntryVisible, hasUsableHost, !isPrivateWindow else { return }
        let owner = root ?? self
        if let existing = owner.onboardingWindow, existing.window?.isVisible == true || existing.model.stage == .progress {
            existing.open()
            return
        }
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Arc", isDirectory: true)
        guard let model = arcImportModel(directory: directory) else { return }
        let controller = OnboardingWindowController(model: model)
        owner.onboardingWindow = controller
        controller.open()
    }

    func arcImportModel(directory: URL, detector: OnboardingSourceDetector = LaunchServicesSourceDetector()) -> OnboardingModel? {
        guard let workspace, let path = (root ?? self).quitPath, !isPrivateWindow else { return nil }
        return OnboardingModel(storePath: path, workspace: workspace, arcDirectory: directory, detector: detector) { [weak owner = root ?? self] in
            guard let owner else { return }
            for window in [owner] + owner.children where !window.isPrivateWindow {
                window.adapter?.refresh()
            }
        }
    }
}
