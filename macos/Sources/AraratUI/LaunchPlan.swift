import AraratKit

public struct LaunchPlan: Equatable {
    public let adopted: KeptWindow?
    public let restores: [KeptWindow]
    public let discardsKept: Bool
    public let shownSpace: String?

    public static func forLaunch(startup: StartupBehavior, kept: [KeptWindow],
                                 openIDs: Set<String>, reopening: Bool) -> LaunchPlan {
        let candidates = kept.filter { !openIDs.contains($0.id) }
        if reopening {
            return LaunchPlan(adopted: candidates.first, restores: [], discardsKept: false, shownSpace: nil)
        }
        guard startup == .restoreWindows else {
            return LaunchPlan(adopted: nil, restores: [], discardsKept: true, shownSpace: kept.first?.shownSpace)
        }
        let restores = Array(candidates.reversed())
        return LaunchPlan(adopted: restores.first, restores: restores, discardsKept: false, shownSpace: nil)
    }
}
