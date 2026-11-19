import AppKit
import AraratKit
import XCTest
@testable import AraratUI

@MainActor
final class MockParityTests: XCTestCase {
    private enum Value: Decodable {
        case number(CGFloat)
        case rgba([CGFloat])
        case color(NSColor)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(CGFloat.self) {
                self = .number(number)
            } else {
                self = .rgba(try container.decode([CGFloat].self))
            }
        }
    }

    private struct Entry: Decodable {
        let source: String
        let selector: String
        let property: String
        let css: String
        let appearance: String?
        let swift: String
        let expected: Value?
        let reason: String?
    }

    func testMockTokens() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("docs/research/mock-values.json"))
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        let values: [String: Value] = [
            "CommandBarMetrics.backdropFill": .color(CommandBarMetrics.backdropFill),
            "CommandBarMetrics.fieldHeight": .number(CommandBarMetrics.fieldHeight),
            "CommandBarMetrics.hintFill": .color(CommandBarMetrics.hintFill),
            "CommandBarMetrics.hintFontSize": .number(CommandBarMetrics.hintFontSize),
            "CommandBarMetrics.hintGap": .number(CommandBarMetrics.hintGap),
            "CommandBarMetrics.hintOffset": .number(CommandBarMetrics.hintOffset),
            "CommandBarMetrics.hintPaddingX": .number(CommandBarMetrics.hintPaddingX),
            "CommandBarMetrics.hintPaddingY": .number(CommandBarMetrics.hintPaddingY),
            "CommandBarMetrics.hintRadius": .number(CommandBarMetrics.hintRadius),
            "CommandBarMetrics.rowGap": .number(CommandBarMetrics.rowGap),
            "CommandBarMetrics.rowHeight": .number(CommandBarMetrics.rowHeight),
            "CommandBarMetrics.rowInset": .number(CommandBarMetrics.rowInset),
            "CommandBarMetrics.topInset": .number(CommandBarMetrics.topInset),
            "CreateSpaceView.primaryFill": .color(CreateSpaceView.primaryFill),
            "DownloadsPopover.rowHeight": .number(DownloadsPopover.rowHeight),
            "DownloadsPageView.contentInset": .number(DownloadsPageView.contentInset),
            "DownloadsPageView.rowHeight": .number(DownloadsPageView.rowHeight),
            "DownloadsPageView.searchHeight": .number(DownloadsPageView.searchHeight),
            "DownloadRowView.libraryActionCenterY": .number(DownloadRowView.libraryActionCenterY),
            "DownloadRowView.libraryCompactWidth": .number(DownloadRowView.libraryCompactWidth),
            "EmptyPageHints.hintGap": .number(EmptyPageHints.hintGap),
            "EmptyPageHints.labelSize": .number(EmptyPageHints.labelSize),
            "EmptyPageHints.lightCardFill": .color(EmptyPageHints.lightCardFill),
            "LibraryView.darkSelectedTileFill": .color(LibraryView.darkSelectedTileFill),
            "LibraryView.lightSelectedTileFill": .color(LibraryView.lightSelectedTileFill),
            "LibraryView.railTileGap": .number(LibraryView.railTileGap),
            "LibraryView.railTileHeight": .number(LibraryView.railTileHeight),
            "LibraryView.railTileIconSize": .number(LibraryView.railTileIconSize),
            "LittleWindowMetrics.barBackground": .color(LittleWindowMetrics.barBackground),
            "LittleWindowMetrics.barText": .color(LittleWindowMetrics.barText),
            "LittleWindowMetrics.buttonFill": .color(LittleWindowMetrics.buttonFill),
            "LittleWindowMetrics.buttonHoverFill": .color(LittleWindowMetrics.buttonHoverFill),
            "LittleWindowMetrics.buttonPressedFill": .color(LittleWindowMetrics.buttonPressedFill),
            "LittleWindowMetrics.buttonSize": .number(LittleWindowMetrics.buttonSize),
            "LittleWindowMetrics.disabledFill": .color(LittleWindowMetrics.disabledFill),
            "LittleWindowMetrics.disabledText": .color(LittleWindowMetrics.disabledText),
            "LittleWindowMetrics.hairline": .color(LittleWindowMetrics.hairline),
            "LittleWindowMetrics.menuInset": .number(LittleWindowMetrics.menuInset),
            "LittleWindowMetrics.menuRowHeight": .number(LittleWindowMetrics.menuRowHeight),
            "LittleWindowMetrics.menuRowRadius": .number(LittleWindowMetrics.menuRowRadius),
            "OnboardingColor.foreground": .color(OnboardingColor.foreground),
            "OnboardingColor.primaryButton": .color(OnboardingColor.primaryButton),
            "OnboardingColor.secondaryButton": .color(OnboardingColor.secondaryButton),
            "OnboardingMetrics.bodySize": .number(OnboardingMetrics.bodySize),
            "OnboardingMetrics.buttonRadius": .number(OnboardingMetrics.buttonRadius),
            "SettingsMetrics.cardGap": .number(SettingsMetrics.cardGap),
            "SettingsMetrics.cardRadius": .number(SettingsMetrics.cardRadius),
            "SettingsMetrics.groupHeadingInset": .number(SettingsMetrics.groupHeadingInset),
            "SettingsMetrics.hitInset": .number(SettingsMetrics.hitInset),
            "SettingsMetrics.hitRadius": .number(SettingsMetrics.hitRadius),
            "SettingsMetrics.hitRowHeight": .number(SettingsMetrics.hitRowHeight),
            "SettingsMetrics.separatorInset": .number(SettingsMetrics.separatorInset),
            "SettingsColor.darkAccent": .color(SettingsColor.darkAccent),
            "SidebarClearButton.labelFontSize": .number(SidebarClearButton.labelFontSize),
            "SidebarMetrics.cornerRadius": .number(SidebarMetrics.cornerRadius),
            "SidebarMetrics.defaultWidth": .number(SidebarMetrics.defaultWidth),
            "SidebarMetrics.libraryContentTop": .number(SidebarMetrics.libraryContentTop),
            "SidebarMetrics.libraryFooterInset": .number(SidebarMetrics.libraryFooterInset),
            "SidebarMetrics.newTabRowHeight": .number(SidebarMetrics.newTabRowHeight),
            "SidebarMetrics.noTabsRowHeight": .number(SidebarMetrics.noTabsRowHeight),
            "SidebarMetrics.rowFillHeight": .number(SidebarMetrics.rowFillHeight),
            "SidebarMetrics.rowHoverFillAlphaDark": .number(SidebarMetrics.rowHoverFillAlphaDark),
            "SidebarMetrics.rowHoverFillAlphaLight": .number(SidebarMetrics.rowHoverFillAlphaLight),
            "SidebarMetrics.rowIconInset": .number(SidebarMetrics.rowIconInset),
            "SidebarMetrics.rowPressedFillAlphaDark": .number(SidebarMetrics.rowPressedFillAlphaDark),
            "SidebarMetrics.rowPressedFillAlphaLight": .number(SidebarMetrics.rowPressedFillAlphaLight),
            "SidebarMetrics.rowSelectedFillAlphaDark": .number(SidebarMetrics.rowSelectedFillAlphaDark),
            "SidebarMetrics.rowSelectedFillLight": .color(SidebarMetrics.rowSelectedFillLight),
            "SidebarMetrics.rowSelectedShadowAlpha": .number(SidebarMetrics.rowSelectedShadowAlpha),
            "SidebarMetrics.rowSelectedShadowAlphaDark": .number(SidebarMetrics.rowSelectedShadowAlphaDark),
            "SidebarMetrics.rowSelectedShadowBlur": .number(SidebarMetrics.rowSelectedShadowBlur),
            "SidebarMetrics.rowSelectedShadowY": .number(SidebarMetrics.rowSelectedShadowY),
            "SidebarMetrics.secondaryFontSize": .number(SidebarMetrics.secondaryFontSize),
            "SidebarMetrics.spaceChevronLeading + 8": .number(SidebarMetrics.spaceChevronLeading + 8),
            "SidebarMetrics.spaceNameIndented + 8": .number(SidebarMetrics.spaceNameIndented + 8),
            "SidebarMetrics.spaceNameLeading + 8": .number(SidebarMetrics.spaceNameLeading + 8),
            "SidebarMetrics.spaceRowHeight": .number(SidebarMetrics.spaceRowHeight),
            "SidebarMetrics.splitSegmentGap": .number(SidebarMetrics.splitSegmentGap),
            "SidebarMetrics.splitSegmentRadius": .number(SidebarMetrics.splitSegmentRadius),
            "SidebarMetrics.splitSegmentTitleLeading": .number(SidebarMetrics.splitSegmentTitleLeading),
            "SidebarMetrics.splitSegmentTitleSize": .number(SidebarMetrics.splitSegmentTitleSize),
            "SidebarMetrics.splitSegmentTitleTrailing": .number(SidebarMetrics.splitSegmentTitleTrailing),
            "SidebarMetrics.todayClearSize": .number(SidebarMetrics.todayClearSize),
            "SidebarMetrics.todayClearTrailing + 8": .number(SidebarMetrics.todayClearTrailing + 8),
            "SidebarMetrics.todayDividerHeight": .number(SidebarMetrics.todayDividerHeight),
            "SidebarMetrics.todayDividerLeading + 8": .number(SidebarMetrics.todayDividerLeading + 8),
            "SidebarMetrics.todayDividerLineDrop": .number(SidebarMetrics.todayDividerLineDrop),
            "SidebarMetrics.todayDividerTrailing + 8": .number(SidebarMetrics.todayDividerTrailing + 8),
            "SidebarMetrics.unloadedOpacity": .number(SidebarMetrics.unloadedOpacity),
            "SidebarMetrics.unreadDotSize": .number(SidebarMetrics.unreadDotSize),
            "SidebarPanelView.defaultDarkBackground": .color(SidebarPanelView.defaultDarkBackground),
            "SiteControlsContent.actionGap": .number(SiteControlsContent.actionGap),
            "SiteControlsContent.actionHeight": .number(SiteControlsContent.actionHeight),
            "SiteControlsContent.actionRadius": .number(SiteControlsContent.actionRadius),
            "SiteControlsContent.gap": .number(SiteControlsContent.gap),
            "SiteControlsContent.linkHeight": .number(SiteControlsContent.linkHeight),
            "SiteControlsContent.padding": .number(SiteControlsContent.padding),
            "SiteControlsContent.pillHeight": .number(SiteControlsContent.pillHeight),
            "SiteControlsContent.pillRadius": .number(SiteControlsContent.pillRadius),
            "SiteControlsContent.width": .number(SiteControlsContent.width),
            "SpaceDockButton.dotAlpha": .number(SpaceDockButton.dotAlpha),
            "SpaceAccent.privateColor": .color(SpaceAccent.privateColor),
            "SpaceAccent.teal": .color(SpaceAccent.teal),
            "TooltipKeycap.gap": .number(TooltipKeycap.gap),
            "TooltipKeycap.size": .number(TooltipKeycap.size),
        ]
        XCTAssertFalse(entries.isEmpty)
        var checked = Set<String>()
        for entry in entries {
            let context = "\(entry.source) \(entry.selector) \(entry.property): \(entry.css)\(entry.appearance.map { " [\($0)]" } ?? "") → \(entry.swift)"
            if let reason = entry.reason {
                XCTAssertFalse(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, context)
                if values[entry.swift] == nil { continue }
            }
            checked.insert(entry.swift)
            switch (entry.expected, values[entry.swift]) {
            case let (.number(expected), .number(actual)):
                XCTAssertEqual(actual, expected, accuracy: 0.000_001, context)
            case let (.rgba(expected), .color(color)):
                guard expected.count == 4, let rgb = color.usingColorSpace(.sRGB) else {
                    XCTFail("Expected four sRGB channels: \(context)")
                    continue
                }
                let actual = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent]
                for (index, channels) in zip(actual, expected).enumerated() {
                    XCTAssertEqual(channels.0, channels.1, accuracy: 1 / 255, "\(context) (channel \(index))")
                }
            default:
                XCTFail("Missing or incompatible token mapping: \(context)")
            }
        }
        XCTAssertEqual(checked, Set(values.keys))
    }
}
