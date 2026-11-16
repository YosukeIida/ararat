import AppKit
import AraratKit

/// P5b: the engine side of Settings › General's downloads rows. `AraratApplyDownloadSettings` is a
/// C entry point in AraratHostAPI.h (the pane acts on every regular profile, not on one window's
/// Browser), so the app resolves it from the loaded framework the way the privacy and sites calls
/// are resolved. The model takes `apply` as its downloads handler; the model tests take a fake.
@MainActor
enum EngineDownloadSettingsHost {
    private typealias Apply = @convention(c) (UnsafeRawPointer, Bool) -> Void

    private static func symbol<T>(_ name: String) -> T? {
        guard let symbol = dlsym(Launcher.handle, name) else {
            FileHandle.standardError.write(Data("ararat-trace: missing download settings API \(name)\n".utf8))
            return nil
        }
        return unsafeBitCast(symbol, to: T.self)
    }

    private static let applySettings: Apply? = symbol("AraratApplyDownloadSettings")

    /// The app applies the record at every window start and after every write, so a profile loaded
    /// later and one already loaded both hold it; the engine remembers it for a profile it creates
    /// later. An empty folder leaves Chromium's own default alone.
    static func apply(_ settings: DownloadSettings) {
        guard let applySettings else { return }
        let directory = settings.directory as NSString
        applySettings(Unmanaged.passUnretained(directory).toOpaque(), settings.askWhereToSave)
    }
}
