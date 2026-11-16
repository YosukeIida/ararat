import AraratKit

/// P5b: the launch's one decision about the kept `Window` records: which one the first window
/// adopts, whether the launch throws them away, and where a fresh window opens. It is its own type
/// so a test can read the choice; `main.swift` only supplies what the store answered.
public struct LaunchPlan: Equatable {
    /// The record the first window adopts (Restore windows and tabs), nil for a fresh window.
    public let adopted: KeptWindow?
    /// Open a new window throws every kept record away, as closing each window did (F6), so
    /// nothing piles up across launches and a later Restore finds no window to bring back.
    public let discardsKept: Bool
    /// Where a fresh window opens: the newest record's own space, whatever profile it belongs to,
    /// so it opens where Restore would have (F9). Nil leaves the core's first space.
    public let shownSpace: String?

    /// `kept` is the store's list, newest first; `openIDs` are the windows this process already
    /// has open, which a launch never adopts twice.
    public static func forLaunch(startup: StartupBehavior, kept: [KeptWindow],
                                 openIDs: Set<String>) -> LaunchPlan {
        let candidates = kept.filter { !openIDs.contains($0.id) }
        guard startup == .restoreWindows else {
            return LaunchPlan(adopted: nil, discardsKept: true, shownSpace: candidates.first?.shownSpace)
        }
        return LaunchPlan(adopted: candidates.first, discardsKept: false, shownSpace: nil)
    }
}
