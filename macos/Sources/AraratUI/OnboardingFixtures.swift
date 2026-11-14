import Foundation

/// U27j's checked-in showcase fixture: synthetic Arc files shaped like the ones the core importer
/// reads (import.rs), with F-Import screen 6's numbers — 3 spaces · 21 pinned tabs · 5 folders ·
/// 8 favourites · 3 looks · 6 routes — plus the report's counters the done screen can name: two
/// peeked folders, two folder states that differ between Arc's windows, one route that named a
/// profile, and three custom key bindings. No owner data: every title and URL is invented.
///
/// These are Swift string constants, not files, because the app bundle carries no resource bundle
/// (`bundle-app.sh` copies only the engine and the executable); the model takes them as injected
/// strings, which is also what proves the flow reads nothing from the owner's Arc.
public enum OnboardingFixtures {
    public struct Expectation: Equatable, Sendable {
        public let spaces, pinnedTabs, folders, favourites, looks, routes: Int
        public let peekedFolders, differingFolderStates, skippedKeyBindings, skippedProfileDestinations: Int
    }

    /// What the showcase fixture must produce. The model tests assert the core import's report and
    /// summary against it, and the VM check asserts the same numbers off the done screen.
    public static let expected = Expectation(
        spaces: 3, pinnedTabs: 21, folders: 5, favourites: 8, looks: 3, routes: 6,
        peekedFolders: 2, differingFolderStates: 2, skippedKeyBindings: 3, skippedProfileDestinations: 1)

    public static let spaces = [
        OnboardingSpaceSource(id: "space-work", title: "Work", profileName: "University", pinnedCount: 6),
        OnboardingSpaceSource(id: "space-personal", title: "Personal", profileName: "Default", pinnedCount: 4),
        OnboardingSpaceSource(id: "space-reading", title: "Reading", profileName: "Default", pinnedCount: 11),
    ]

    public static let showcase = OnboardingData(
        sidebar: showcaseSidebar, windows: showcaseWindows,
        keyBindings: showcaseKeyBindings, routing: showcaseRouting, spaces: spaces)

    /// The malformed-sidebar fixture: valid JSON whose containers carry no `spaces`, which the
    /// core refuses with `ImportError("sidebar.containers has no container with spaces")`.
    public static let malformedSidebar = OnboardingData(
        sidebar: #"{"sidebar":{"containers":[{"global":{}}]}}"#,
        windows: showcaseWindows, keyBindings: showcaseKeyBindings, routing: showcaseRouting, spaces: spaces)

    /// The sibling-file failure: the sidebar imports, and the key-bindings file's version is one
    /// the core does not know, so the report carries `unsupported key bindings version` (screen 8).
    public static let badKeyBindings = OnboardingData(
        sidebar: showcaseSidebar, windows: showcaseWindows,
        keyBindings: #"{"version":2,"userOverrides":[]}"#, routing: showcaseRouting, spaces: spaces)

    /// A detector that answers "installed" the way the fixture says, so a check never asks
    /// LaunchServices about the machine it runs on.
    public final class FixtureSourceDetector: OnboardingSourceDetector {
        public init() {}
        public func isArcInstalled() -> Bool { true }
    }

    // MARK: - The four files

    private static let workLook = """
    {"windowAppearance":{"single":{"_0":"light"}},"background":{"single":{"_0":{"style":{"color":{"_0":{"basicColor":{"_0":{"color":{"red":0.30,"green":0.45,"blue":0.80,"alpha":1},"modifiers":{"intensityFactor":1,"noiseFactor":0}}}}}}}}}}
    """
    private static let personalLook = """
    {"windowAppearance":{"single":{"_0":"dark"}},"background":{"single":{"_0":{"style":{"color":{"_0":{"basicColor":{"_0":{"color":{"red":0.55,"green":0.25,"blue":0.35,"alpha":1},"modifiers":{"intensityFactor":1,"noiseFactor":0}}}}}}}}}}
    """
    private static let readingLook = """
    {"windowAppearance":{"appearanceBased":{"light":"light","dark":"dark"}},"background":{"appearanceBased":{"light":{"style":{"color":{"_0":{"blendedSingleColor":{"_0":{"color":{"red":0.20,"green":0.55,"blue":0.40,"alpha":1,"position":{"x":0.6,"y":0.4}},"modifiers":{"intensityFactor":0.6,"noiseFactor":0.2},"translucencyStyle":"auto"}}}}}}}}}
    """

    public static let showcaseSidebar = """
    {"sidebar":{"containers":[{"global":{}},{
      "spaces":[
        "space-work",{"id":"space-work","title":"Work","profile":{"custom":{"_0":{"directoryBasename":"University"}}},"containerIDs":["pinned","pin-work","unpinned","today-work"],"customInfo":{"iconType":{"emoji_v2":"💼"},"windowTheme":\(workLook)}},
        "space-personal",{"id":"space-personal","title":"Personal","profile":{"default":true},"containerIDs":["pinned","pin-personal","unpinned","today-personal"],"customInfo":{"iconType":{"emoji_v2":"🏠"},"windowTheme":\(personalLook)}},
        "space-reading",{"id":"space-reading","title":"Reading","profile":{"default":true},"containerIDs":["pinned","pin-reading","unpinned","today-reading"],"customInfo":{"iconType":{"emoji_v2":"📚"},"windowTheme":\(readingLook)}}
      ],
      "topAppsContainerIDs":[{"default":true},"fav-default"],
      "items":[
        "pin-work",{"id":"pin-work","parentID":null,"childrenIds":["tab-weekly","folder-docs","folder-triage","tab-metrics-a","tab-metrics-b"],"data":{"itemContainer":{"containerType":{"spaceItems":{"_0":"space-work"}}}}},
        "today-work",{"id":"today-work","parentID":null,"childrenIds":[],"data":{"itemContainer":{"containerType":{"spaceItems":{"_0":"space-work"}}}}},
        "tab-weekly",{"id":"tab-weekly","parentID":"pin-work","childrenIds":[],"data":{"tab":{"savedURL":"https://weekly.example.com/","savedTitle":"Weekly review"}}},
        "folder-docs",{"id":"folder-docs","parentID":"pin-work","childrenIds":["tab-spec","tab-notes"],"title":"Docs","data":{"list":{}}},
        "tab-spec",{"id":"tab-spec","parentID":"folder-docs","childrenIds":[],"data":{"tab":{"savedURL":"https://docs.example.com/spec","savedTitle":"Spec"}}},
        "tab-notes",{"id":"tab-notes","parentID":"folder-docs","childrenIds":[],"data":{"tab":{"savedURL":"https://docs.example.com/notes","savedTitle":"Notes"}}},
        "folder-triage",{"id":"folder-triage","parentID":"pin-work","childrenIds":["tab-inbox"],"title":"Triage","data":{"list":{}}},
        "tab-inbox",{"id":"tab-inbox","parentID":"folder-triage","childrenIds":[],"data":{"tab":{"savedURL":"https://mail.example.com/inbox","savedTitle":"Inbox"}}},
        "tab-metrics-a",{"id":"tab-metrics-a","parentID":"pin-work","childrenIds":[],"data":{"tab":{"savedURL":"https://metrics.example.com/a","savedTitle":"Metrics A"}}},
        "tab-metrics-b",{"id":"tab-metrics-b","parentID":"pin-work","childrenIds":[],"data":{"tab":{"savedURL":"https://metrics.example.com/b","savedTitle":"Metrics B"}}},
        "pin-personal",{"id":"pin-personal","parentID":null,"childrenIds":["tab-mail","tab-calendar","folder-recipes"],"data":{"itemContainer":{"containerType":{"spaceItems":{"_0":"space-personal"}}}}},
        "today-personal",{"id":"today-personal","parentID":null,"childrenIds":[],"data":{"itemContainer":{"containerType":{"spaceItems":{"_0":"space-personal"}}}}},
        "tab-mail",{"id":"tab-mail","parentID":"pin-personal","childrenIds":[],"data":{"tab":{"savedURL":"https://mail.example.com/","savedTitle":"Mail"}}},
        "tab-calendar",{"id":"tab-calendar","parentID":"pin-personal","childrenIds":[],"data":{"tab":{"savedURL":"https://calendar.example.com/","savedTitle":"Calendar"}}},
        "folder-recipes",{"id":"folder-recipes","parentID":"pin-personal","childrenIds":["tab-pasta","tab-travel"],"title":"Recipes","data":{"list":{}}},
        "tab-pasta",{"id":"tab-pasta","parentID":"folder-recipes","childrenIds":[],"data":{"tab":{"savedURL":"https://cooking.example.com/pasta","savedTitle":"Pasta"}}},
        "tab-travel",{"id":"tab-travel","parentID":"folder-recipes","childrenIds":[],"data":{"tab":{"savedURL":"https://travel.example.com/","savedTitle":"Travel"}}},
        "pin-reading",{"id":"pin-reading","parentID":null,"childrenIds":["tab-home","folder-to-read","folder-archive","tab-digest","tab-newsletter"],"data":{"itemContainer":{"containerType":{"spaceItems":{"_0":"space-reading"}}}}},
        "today-reading",{"id":"today-reading","parentID":null,"childrenIds":[],"data":{"itemContainer":{"containerType":{"spaceItems":{"_0":"space-reading"}}}}},
        "tab-home",{"id":"tab-home","parentID":"pin-reading","childrenIds":[],"data":{"tab":{"savedURL":"https://reading.example.com/","savedTitle":"Home"}}},
        "folder-to-read",{"id":"folder-to-read","parentID":"pin-reading","childrenIds":["tab-article-1","tab-article-2","tab-article-3","tab-article-4","tab-article-5"],"title":"To read","data":{"list":{}}},
        "tab-article-1",{"id":"tab-article-1","parentID":"folder-to-read","childrenIds":[],"data":{"tab":{"savedURL":"https://reading.example.com/1","savedTitle":"Article 1"}}},
        "tab-article-2",{"id":"tab-article-2","parentID":"folder-to-read","childrenIds":[],"data":{"tab":{"savedURL":"https://reading.example.com/2","savedTitle":"Article 2"}}},
        "tab-article-3",{"id":"tab-article-3","parentID":"folder-to-read","childrenIds":[],"data":{"tab":{"savedURL":"https://reading.example.com/3","savedTitle":"Article 3"}}},
        "tab-article-4",{"id":"tab-article-4","parentID":"folder-to-read","childrenIds":[],"data":{"tab":{"savedURL":"https://reading.example.com/4","savedTitle":"Article 4"}}},
        "tab-article-5",{"id":"tab-article-5","parentID":"folder-to-read","childrenIds":[],"data":{"tab":{"savedURL":"https://reading.example.com/5","savedTitle":"Article 5"}}},
        "folder-archive",{"id":"folder-archive","parentID":"pin-reading","childrenIds":["tab-post-1","tab-post-2","tab-post-3"],"title":"Archive 2024","data":{"list":{}}},
        "tab-post-1",{"id":"tab-post-1","parentID":"folder-archive","childrenIds":[],"data":{"tab":{"savedURL":"https://reading.example.com/post-1","savedTitle":"Post 1"}}},
        "tab-post-2",{"id":"tab-post-2","parentID":"folder-archive","childrenIds":[],"data":{"tab":{"savedURL":"https://reading.example.com/post-2","savedTitle":"Post 2"}}},
        "tab-post-3",{"id":"tab-post-3","parentID":"folder-archive","childrenIds":[],"data":{"tab":{"savedURL":"https://reading.example.com/post-3","savedTitle":"Post 3"}}},
        "tab-digest",{"id":"tab-digest","parentID":"pin-reading","childrenIds":[],"data":{"tab":{"savedURL":"https://reading.example.com/digest","savedTitle":"Digest"}}},
        "tab-newsletter",{"id":"tab-newsletter","parentID":"pin-reading","childrenIds":[],"data":{"tab":{"savedURL":"https://reading.example.com/newsletter","savedTitle":"Newsletter"}}},
        "fav-default",{"id":"fav-default","parentID":null,"childrenIds":["tab-fav-1","tab-fav-2","tab-fav-3","tab-fav-4","tab-fav-5","tab-fav-6","tab-fav-7","tab-fav-8"],"data":{"itemContainer":{"containerType":{"topApps":{"_0":{"default":true}}}}}},
        "tab-fav-1",{"id":"tab-fav-1","parentID":"fav-default","childrenIds":[],"data":{"tab":{"savedURL":"https://fav.example.com/1","savedTitle":"Favourite 1"}}},
        "tab-fav-2",{"id":"tab-fav-2","parentID":"fav-default","childrenIds":[],"data":{"tab":{"savedURL":"https://fav.example.com/2","savedTitle":"Favourite 2"}}},
        "tab-fav-3",{"id":"tab-fav-3","parentID":"fav-default","childrenIds":[],"data":{"tab":{"savedURL":"https://fav.example.com/3","savedTitle":"Favourite 3"}}},
        "tab-fav-4",{"id":"tab-fav-4","parentID":"fav-default","childrenIds":[],"data":{"tab":{"savedURL":"https://fav.example.com/4","savedTitle":"Favourite 4"}}},
        "tab-fav-5",{"id":"tab-fav-5","parentID":"fav-default","childrenIds":[],"data":{"tab":{"savedURL":"https://fav.example.com/5","savedTitle":"Favourite 5"}}},
        "tab-fav-6",{"id":"tab-fav-6","parentID":"fav-default","childrenIds":[],"data":{"tab":{"savedURL":"https://fav.example.com/6","savedTitle":"Favourite 6"}}},
        "tab-fav-7",{"id":"tab-fav-7","parentID":"fav-default","childrenIds":[],"data":{"tab":{"savedURL":"https://fav.example.com/7","savedTitle":"Favourite 7"}}},
        "tab-fav-8",{"id":"tab-fav-8","parentID":"fav-default","childrenIds":[],"data":{"tab":{"savedURL":"https://fav.example.com/8","savedTitle":"Favourite 8"}}}
      ]
    }]}}
    """

    private static let showcaseWindows = """
    {"windows":[
      {"expandedItems":["folder-docs",{"expanded":{}},"folder-recipes",{"expanded":{}},"folder-to-read",{"expanded":{}},"folder-triage",{"peeked":{}},"folder-archive",{"peeked":{}}],
       "itemLastActiveDates":["tab-weekly",700000000.0,"tab-spec",700000001.0]},
      {"expandedItems":["folder-docs",{"expanded":{}},"folder-to-read",{"expanded":{}},"folder-archive",{"expanded":{}}],
       "itemLastActiveDates":["tab-mail",700000002.0]}
    ]}
    """

    private static let showcaseKeyBindings = """
    {"version":1,"userOverrides":[
      {"command":"force_reload","key":"r"},
      {"command":"settings","key":","},
      {"command":"new_tab","key":"t"}
    ]}
    """

    /// Six importable rules plus one that names a profile, which the core skips and counts.
    private static let showcaseRouting = """
    {"version":1,"rules":[
      {"id":"meet","sourceComponents":[{"id":"meet-1","componentType":{"urlMatch":{"_0":{"contains":{}},"_1":"meet.example.com"}}}],"destination":{"space":{"_0":{"mostRecent":{}}}}},
      {"id":"pulls","sourceComponents":[{"id":"pulls-1","componentType":{"urlMatch":{"_0":{"matches":{}},"_1":"https://pulls.example.com/"}}}],"destination":{"space":{"_0":"space-work"}}},
      {"id":"mail","sourceComponents":[{"id":"mail-1","componentType":{"urlMatch":{"_0":{"contains":{}},"_1":"mail.example.com"}}}],"destination":{"space":{"_0":"space-personal"}}},
      {"id":"reading","sourceComponents":[{"id":"reading-1","componentType":{"urlMatch":{"_0":{"contains":{}},"_1":"reading.example.com"}}}],"destination":{"space":{"_0":"space-reading"}}},
      {"id":"docs-little","sourceComponents":[{"id":"docs-little-1","componentType":{"urlMatch":{"_0":{"contains":{}},"_1":"docs.example.com"}}}],"destination":{"littleArc":{"_0":{"mostRecent":{}}}}},
      {"id":"calendar","sourceComponents":[{"id":"calendar-1","componentType":{"urlMatch":{"_0":{"matches":{}},"_1":"https://calendar.example.com/"}}}],"destination":{"space":{"_0":"space-personal"}}},
      {"id":"profile-destination","sourceComponents":[{"id":"profile-1","componentType":{"urlMatch":{"_0":{"contains":{}},"_1":"university.example.com"}}}],"destination":{"space":{"_0":{"profile":{"_0":"University"}}}}}
    ],"defaultDestination":{"space":{"_0":{"mostRecent":{}}}}}
    """
}
