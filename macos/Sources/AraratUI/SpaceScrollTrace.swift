import AppKit

/// `--ararat-trace-space-scroll`: one stderr line per wheel event over the sidebar, with the
/// fields that decide Arc's wheel rule and the classifier's answer, so a gesture captured on the
/// owner's trackball can be compared with the recordings in docs/research/arc-ardia-observed.md
/// section 5. Off unless the flag is passed.
@MainActor
enum SpaceScrollTrace {
    static let enabled = CommandLine.arguments.contains("--ararat-trace-space-scroll")

    static func write(_ event: NSEvent, action: String) {
        guard enabled else { return }
        let line = String(
            format: "ararat-trace: space-scroll t=%.3f phase=%d momentum=%d precise=%d dx=%.2f dy=%.2f inverted=%d action=%@\n",
            event.timestamp, event.phase.rawValue, event.momentumPhase.rawValue,
            event.hasPreciseScrollingDeltas ? 1 : 0, event.scrollingDeltaX, event.scrollingDeltaY,
            event.isDirectionInvertedFromDevice ? 1 : 0, action)
        FileHandle.standardError.write(Data(line.utf8))
    }
}
