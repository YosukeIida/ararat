import AppKit
import AraratKit
import Testing
@testable import AraratUI

private func siteState(security: String, chain: [Data] = []) -> SiteState {
    SiteState(["document": "https://docs.example.org/page", "origin": "https://docs.example.org",
               "security": security, "certificateChain": chain, "permissions": [], "blocked": false,
               "internal": false])!
}

@Test @MainActor
func siteControlsActionRowIsOneRowOfIconButtonsWithTooltips() {
    _ = NSApplication.shared
    let content = SiteControlsContent(model: siteState(security: "secure", chain: [Data([0x01])]),
                                      includesFullPage: true)
    content.frame = NSRect(x: 0, y: 0, width: SiteControlsContent.width, height: 300)
    content.layoutSubtreeIfNeeded()
    #expect(content.actionTitles == ["Screenshot a region", "Capture the full page"])
    let row = content.checkActionRow
    #expect(row.sameRow)
    #expect(row.height == 48)
    #expect(row.equalWidth)
    #expect(row.iconOnly)
    #expect(row.tooltipsMatch)
    #expect(content.actionFrames.count == 2)
    #expect(content.actionFrames[0].width == content.actionFrames[1].width)
    // The footer holds the pill and All Site Settings… at the two ends of one band.
    #expect(content.footerTitle == "Secure")
    #expect(content.pillStyle == .secure)
    #expect(content.footerEnabled)
    #expect(content.allSiteSettingsTitle == "All Site Settings…")
    #expect(abs(content.allSiteSettingsFrame.minY - content.footerFrame.minY) < 0.5)
    #expect(content.allSiteSettingsFrame.minX > content.footerFrame.maxX)
    #expect(content.footerFrame.height == SiteControlsContent.pillHeight)
}

/// A page without connection information keeps the quiet pill with its own words; an insecure
/// page takes the warning style. The board draws neither state's pill text, so this pins ours.
@Test @MainActor
func siteControlsPillFollowsThePagesVerdict() {
    _ = NSApplication.shared
    let neutral = SiteControlsContent(model: siteState(security: "none"), includesFullPage: true)
    #expect(neutral.footerTitle == "No connection information")
    #expect(neutral.pillStyle == .neutral)
    #expect(!neutral.footerEnabled)
    let warn = SiteControlsContent(model: siteState(security: "not_secure"), includesFullPage: true)
    #expect(warn.footerTitle == "Not Secure")
    #expect(warn.pillStyle == .warn)
    #expect(!warn.footerEnabled)
    let bad = SiteControlsContent(model: siteState(security: "error"), includesFullPage: true)
    #expect(bad.footerTitle == "Not Secure")
    #expect(bad.pillStyle == .bad)
    let secure = SiteControlsContent(model: siteState(security: "secure", chain: [Data([0x01])]), includesFullPage: true)
    #expect(secure.footerTitle == "Secure")
    #expect(secure.pillStyle == .secure)
    #expect(secure.footerEnabled)
    #expect(secure.checkClickFooter())
}

/// The full-page row stays one of the two icons when it is left out.
@Test @MainActor
func siteControlsActionRowHoldsOneTileWhenTheFullPageRowIsOff() {
    _ = NSApplication.shared
    let content = SiteControlsContent(model: siteState(security: "secure"), includesFullPage: false)
    content.frame = NSRect(x: 0, y: 0, width: SiteControlsContent.width, height: 300)
    content.layoutSubtreeIfNeeded()
    #expect(content.actionTitles == ["Screenshot a region"])
    #expect(content.checkActionRow.sameRow && content.checkActionRow.iconOnly)
}
