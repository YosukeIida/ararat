import AppKit
import AraratKit
import Testing
@testable import AraratUI

/// U27h: the Little Window's bar model — the Open-in label and its disabled states, the space
/// menu's search (every space of the profile, no Most Recent), and the address rule.
@Test @MainActor
func littleWindowOpenInFollowsTheDefaultDestination() {
    var model = LittleWindowBarModel()
    model.profileName = "Default"
    model.profiles = ["Default", "Profile 1"]
    model.spaces = [.init(id: "work", title: "Work"), .init(id: "personal", title: "Personal"),
                    .init(id: "reading", title: "Reading")]
    model.defaultSpaceID = "personal"
    model.pageURL = "https://example.com/page"
    #expect(model.destination?.id == "personal")
    #expect(model.openInTitle == "Open in Personal")
    #expect(model.openEnabled)
    // A stale default (the space was deleted) falls back to the profile's first space.
    model.defaultSpaceID = "gone"
    #expect(model.destination?.id == "work")
    #expect(model.openInTitle == "Open in Work")
    // No page yet: the menu-created Little Window on about:blank has nothing to open.
    model.pageURL = "about:blank"
    #expect(!model.openEnabled)
    model.pageURL = nil
    #expect(!model.openEnabled)
    // No space at all: Open is disabled and the label drops the name.
    model.spaces = []
    model.defaultSpaceID = nil
    model.pageURL = "https://example.com/page"
    #expect(!model.openEnabled)
    #expect(model.openInTitle == "Open in")
}

@Test @MainActor
func littleWindowSpaceMenuSearchesTheProfilesSpaces() {
    var model = LittleWindowBarModel()
    model.spaces = [.init(id: "work", title: "Work"), .init(id: "personal", title: "Personal"),
                    .init(id: "reading", title: "Reading")]
    #expect(model.filteredSpaces.map(\.title) == ["Work", "Personal", "Reading"])
    model.search = "per"
    #expect(model.filteredSpaces.map(\.title) == ["Personal"])
    model.search = "REA"
    #expect(model.filteredSpaces.map(\.title) == ["Reading"])
    model.search = "  "
    #expect(model.filteredSpaces.count == 3)
    model.search = "nothing"
    #expect(model.filteredSpaces.isEmpty)
    // The menu lists the profile's spaces only: no Most Recent item exists.
    #expect(!model.spaces.contains { $0.title.localizedCaseInsensitiveContains("most recent") })
}

@Test @MainActor
func littleWindowAddressUsesTheURLFieldRule() {
    var model = LittleWindowBarModel()
    model.pageURL = "https://user:pw@real.example:8443/a"
    #expect(model.addressText == "real.example")
    #expect(model.copyEnabled)
    model.pageURL = "file:///Users/someone/Notes/spec.md"
    #expect(model.addressText == "spec.md")
    model.pageURL = "data:text/html,<title>x</title>"
    #expect(model.addressText == "data:")
    model.pageURL = "about:blank"
    #expect(model.addressText == URLFieldContent.placeholderText)
    #expect(model.copyEnabled)
    model.pageURL = "chrome://settings/"
    #expect(model.address.showsGear)
    #expect(model.addressText == "chrome://settings/")
    model.pageURL = nil
    #expect(model.addressText == URLFieldContent.placeholderText)
    #expect(!model.copyEnabled)
}

/// The bar's geometry follows the design's step rule: 48 pt tall, the ⌘L bar 504 pt, the
/// board's colours and radii.
@Test @MainActor
func littleWindowBarLaysOutTheBoardsBand() throws {
    let bar = LittleWindowBarView(frame: NSRect(x: 0, y: 0, width: 640, height: LittleWindowMetrics.barHeight))
    var model = LittleWindowBarModel()
    model.profileName = "Default"
    model.profiles = ["Default", "Profile 1"]
    model.spaces = [.init(id: "work", title: "Work")]
    model.defaultSpaceID = "work"
    model.pageURL = "https://example.com/page"
    bar.model = model
    bar.layoutSubtreeIfNeeded()
    #expect(LittleWindowMetrics.barHeight == 48)
    #expect(LittleWindowMetrics.commandBarWidth == 504)
    #expect(LittleWindowMetrics.contentRadius == 10)
    #expect(bar.checkProfileTitle == "Default")
    #expect(bar.checkOpenTitle == "Open in Work")
    #expect(bar.checkOpenEnabled)
    #expect(bar.checkCopyEnabled)
    #expect(bar.checkAddressText == "example.com")
    // The chip starts clear of the traffic lights and the buttons end at the trailing inset.
    let frames = bar.checkButtonFrames
    #expect((frames["profile"]?.minX ?? 0) >= 80)
    let profile = try #require(frames["profile"])
    let copy = try #require(frames["copy"])
    let regionCentre = (90 + copy.minX) / 2
    let group = try #require(frames["glyph"]).union(try #require(frames["address"]))
    #expect(abs(group.midX - regionCentre) <= 1)
    #expect(abs((frames["chevron"]?.maxX ?? 0) - (640 - LittleWindowMetrics.trailingInset)) <= 1)
    #expect((frames["open"]?.maxX ?? 0) <= (frames["chevron"]?.minX ?? 0))
    #expect((frames["copy"]?.maxX ?? 0) <= (frames["open"]?.minX ?? 0))
    #expect((frames["address"]?.maxX ?? 0) <= (frames["copy"]?.minX ?? 0))
    let colour = bar.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) }
    #expect(abs((colour?.redComponent ?? 0) - 0x23 / 255) < 0.01)
    #expect(abs((colour?.blueComponent ?? 0) - 0x27 / 255) < 0.01)

    let longHost = Array(repeating: String(repeating: "a", count: 50), count: 3).joined(separator: ".") + ".example.com"
    model.pageURL = "https://\(longHost)/page"
    bar.model = model
    bar.layoutSubtreeIfNeeded()
    let longFrames = bar.checkButtonFrames
    let address = try #require(bar.subviews.compactMap { $0 as? NSTextField }.first)
    let longGroup = try #require(longFrames["glyph"]).union(try #require(longFrames["address"]))
    #expect(address.stringValue == longHost)
    #expect(address.lineBreakMode == .byTruncatingTail)
    #expect(address.frame.width < address.intrinsicContentSize.width)
    #expect(longGroup.minX >= profile.maxX + 16)
    #expect(longGroup.maxX <= copy.minX - 16)

    model.profileName = "University Research and Teaching"
    bar.model = model
    bar.layoutSubtreeIfNeeded()
    let longProfileFrames = bar.checkButtonFrames
    let longProfile = try #require(longProfileFrames["profile"])
    let longProfileCopy = try #require(longProfileFrames["copy"])
    let longProfileAddress = try #require(longProfileFrames["address"])
    let shiftedGroup = try #require(longProfileFrames["glyph"]).union(longProfileAddress)
    #expect(shiftedGroup.minX > regionCentre)
    #expect(abs(shiftedGroup.minX - (longProfile.maxX + 16)) <= 1)
    #expect(shiftedGroup.maxX <= longProfileCopy.minX - 16)
    #expect(longProfileAddress.width > 0)
    #expect(longProfileAddress.width < address.intrinsicContentSize.width)
}

@Test @MainActor
func littleWindowBarRoutesOnlyItsDragAreasToTheBar() throws {
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    let bar = LittleWindowBarView(frame: NSRect(x: 30, y: 500, width: 720, height: 48))
    root.addSubview(bar)
    NSLayoutConstraint.activate([
        bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 30),
        bar.topAnchor.constraint(equalTo: root.topAnchor, constant: 52),
        bar.widthAnchor.constraint(equalToConstant: 720),
        bar.heightAnchor.constraint(equalToConstant: 48),
    ])
    var model = LittleWindowBarModel()
    model.profileName = "Default"
    model.spaces = [.init(id: "work", title: "Work")]
    model.defaultSpaceID = "work"
    model.pageURL = "https://example.com/page"
    bar.model = model
    root.layoutSubtreeIfNeeded()
    for name in ["address", "glyph", "profile", "copy", "extensions", "open", "chevron"] {
        let frame = try #require(bar.checkButtonFrames[name])
        #expect(!frame.isEmpty)
        let point = bar.convert(NSPoint(x: frame.midX, y: frame.midY), to: root)
        let target = try #require(root.hitTest(point))
        if name == "address" || name == "glyph" {
            #expect(target === bar)
        } else {
            #expect(target is NSControl)
            #expect(target !== bar)
        }
    }
    #expect(root.hitTest(bar.convert(NSPoint(x: 360, y: 40), to: root)) === bar)
    #expect(root.hitTest(NSPoint(x: 360, y: 499)) === root)
    #expect(bar.acceptsFirstMouse(for: nil))
    #expect(!bar.mouseDownCanMoveWindow)
}

@Test @MainActor
func littleWindowBarButtonsDrawOnlyTheirIntendedText() {
    let profile = LittleWindowProfileChip()
    #expect(profile.title.isEmpty)
    let open = LittleWindowBarButton(style: .text, symbol: nil, title: "Open in Work", caps: "⌘O")
    #expect(open.title.isEmpty)
    #expect(open.subviews.compactMap { ($0 as? NSTextField)?.stringValue } == ["Open in Work", "⌘O"])
    for style: LittleWindowBarButton.Style in [.icon, .chevron] {
        let button = LittleWindowBarButton(style: style, symbol: "chevron.down", title: "Choose a space")
        #expect(button.title.isEmpty)
        #expect(button.image != nil)
        #expect(button.imagePosition == .imageOnly)
        #expect(button.subviews.allSatisfy { !($0 is NSTextField) })
    }
}

@Test @MainActor
func littleWindowSpaceSearchKeepsTextAfterItsSearchButton() {
    let panel = LittleWindowMenuPanel(width: LittleWindowMetrics.menuWidth, rows: [], showsSearch: true)
    panel.layoutSubtreeIfNeeded()
    let field = panel.checkSearchField
    #expect(field.placeholderString == "Search spaces")
    for text in ["", "per"] {
        field.stringValue = text
        #expect(field.searchTextBounds.minX >= field.searchButtonBounds.maxX + 4)
        #expect(field.searchTextBounds.width > 0)
        #expect(field.bounds.contains(field.searchTextBounds))
    }
}

/// The space menu's panel: a search field and the rows it filters, at the board's width.
@Test @MainActor
func littleWindowMenuPanelFiltersItsRows() {
    let panel = LittleWindowMenuPanel(width: LittleWindowMetrics.menuWidth, rows: [
        .init(id: "work", title: "Work", selected: true),
        .init(id: "personal", title: "Personal"),
        .init(id: "reading", title: "Reading"),
    ], showsSearch: true)
    panel.layoutSubtreeIfNeeded()
    #expect(panel.checkWidth == 210)
    #expect(panel.checkRowTitles == ["Work", "Personal", "Reading"])
    #expect(panel.checkHeight == 118)
    var selected: String?
    panel.onSelect = { selected = $0 }
    panel.checkClickRow("reading")
    #expect(selected == "reading")
    var query: String?
    panel.onSearch = { query = $0 }
    panel.checkTypeSearch("per")
    #expect(query == "per")
    panel.rows = []
    panel.layoutSubtreeIfNeeded()
    #expect(panel.checkHeight == 42)
}

@Test @MainActor
func littleWindowProfileMenuUsesItsEntireHeightForRows() throws {
    let panel = LittleWindowMenuPanel(width: LittleWindowMetrics.profileMenuWidth, rows: [
        .init(id: "default", title: "Default", selected: true),
        .init(id: "client", title: "Client work"),
    ], showsSearch: false)
    panel.layoutSubtreeIfNeeded()
    let stack = try #require(panel.subviews.compactMap { $0 as? NSStackView }.first)
    #expect(panel.checkSearchField.superview == nil)
    #expect(panel.checkHeight == 60)
    #expect(stack.frame == NSRect(x: 5, y: 5, width: 190, height: 50))
    #expect(stack.arrangedSubviews.allSatisfy { $0.frame.width == 190 && $0.frame.height == 24 })
}

/// The ⌘L bar sits inside the Little Window (the board's 78 pt below the top, rounded to 80)
/// and keeps the design's 504 pt width.
@Test @MainActor
func littleWindowCommandBarSitsInsideTheWindow() {
    let window = NSRect(x: 100, y: 100, width: 640, height: 400)
    let frame = CommandBarMetrics.littleWindowPanelFrame(windowFrame: window, width: LittleWindowMetrics.commandBarWidth, rows: 0)
    #expect(frame.width == 504)
    #expect(abs(frame.midX - window.midX) <= 0.5)
    #expect(abs(frame.maxY - (window.maxY - 80)) <= 0.5)
    #expect(frame.minY >= window.minY)
    #expect(CommandBarMetrics.littleWindowPanelFrame(windowFrame: window, width: 504, rows: 5).height
            == CommandBarMetrics.height(forRows: 5))

    let parent = NSWindow(contentRect: window, styleMask: [.titled], backing: .buffered, defer: false)
    parent.appearance = NSAppearance(named: .aqua)
    let presenter = CommandBarPresenter(parent: parent, visible: false, bindings: [], highlight: .systemBlue,
                                        width: LittleWindowMetrics.commandBarWidth)
    #expect(presenter.panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
}
