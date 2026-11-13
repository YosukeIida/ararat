// The settings-little-window tick, appended to SettingsScreenCheck's extension.
import AppKit
import AraratEngineAPI
import AraratUI

extension Runtime {
    /// Phases 2 to 14 of `settings-little-window` (U27i): the pane's five rows and its recorder;
    /// the Air Traffic Control link; a destination written and read back after the window
    /// reopens, then used by a Little Window's bar; close-after off leaving the window open on the
    /// page it sent; and remembering off opening at the default frame. The shortcut's
    /// registration result is read from the app-wide center, never by pressing a system-wide key.
    func settingsLittleWindowTick(_ probe: SettingsCheckProbe, check: SettingsScreenCheck,
                                  note: @escaping (String) -> Void, trace: @escaping (String) -> Void,
                                  step: @escaping (Int) -> Void, end: (String, Bool) -> Void,
                                  finish: @escaping () -> Void, capture: (String) -> Bool) {
        let owner = root ?? self
        func popup() -> LittleWindowController? { owner.littleWindows.first }
        func popupTab(_ controller: LittleWindowController?) -> (any ARTabAPI)? {
            (controller?.popup.host?.tabs() as? [any ARTabAPI])?.first
        }
        func keyEvent(_ keyCode: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags) -> NSEvent? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                             characters: characters, charactersIgnoringModifiers: characters,
                             isARepeat: false, keyCode: keyCode)
        }
        switch check.phase {
        case 2:
            let ids = [SettingsModel.littleWindowLinkRowId, SettingsModel.littleWindowShortcutRowId,
                       SettingsModel.littleWindowOpenInRowId, SettingsModel.littleWindowCloseAfterRowId,
                       SettingsModel.littleWindowRememberRowId]
            let rows = ids.map { probe.marker(SettingsModel.rowMarker($0)) }
            let controls = [SettingsModel.littleWindowShortcutRecorderMarker, SettingsModel.littleWindowOpenInMenuMarker,
                            SettingsModel.littleWindowCloseAfterSwitchMarker, SettingsModel.littleWindowRememberSwitchMarker]
                .map { probe.marker($0) }
            guard let link = rows[0], let shortcut = rows[1], let openIn = rows[2], let close = rows[3], let remember = rows[4],
                  controls.allSatisfy({ $0 != nil }) else {
                note("little window rows \(rows.map { $0 != nil }) controls \(controls.map { $0 != nil })")
                return
            }
            // The board's order: the link, then the shortcut, then the card with Open in and the
            // two switches, each switch drawn.
            check.report("rows", link.maxY <= shortcut.minY + 1 && shortcut.maxY <= openIn.minY + 1
                         && openIn.maxY <= close.minY + 1 && close.maxY <= remember.minY + 1
                         && controls.allSatisfy { ($0?.width ?? 0) > 0 && ($0?.height ?? 0) >= 16 })
            trace("opening Air Traffic Control from the link row")
            probe.openAirTraffic()
            step(3)
        case 3:
            guard probe.pageID == "air-traffic" else { note("page after the link row: \(probe.pageID)"); return }
            check.report("atc_link", probe.highlightedRowID == SettingsModel.airTrafficCardId
                         && probe.marker(SettingsModel.rowMarker(SettingsModel.airTrafficCardId)) != nil)
            probe.openLittleWindowPane()
            step(4)
        case 4:
            guard probe.pageID == "little-window" else { note("back on \(probe.pageID)"); return }
            let ids = probe.littleWindowSpaceIDs
            guard let target = ids.last else { note("no space for the destination"); return }
            check.littleSpaceID = target
            check.littleSpaceTitle = probe.littleWindowSpaceTitle(target) ?? ""
            trace("writing the destination \(target)")
            probe.setLittleWindowOpenIn(.space(target))
            step(5)
        case 5:
            guard probe.littleWindowOpenIn == .space(check.littleSpaceID), !check.littleSpaceTitle.isEmpty else {
                note("open in \(probe.littleWindowOpenIn), want \(check.littleSpaceID)"); return
            }
            trace("closing the settings window")
            owner.settings?.window?.performClose(nil)
            step(6)
        case 6:
            guard owner.settings?.window?.isVisible != true else { note("the settings window is still visible"); return }
            trace("reopening the settings window")
            owner.settings?.checkOpen(paneID: "little-window", shownSpaceID: snapshot.shownSpaceId)
            step(7)
        case 7:
            guard probe.isVisible, probe.pageID == "little-window",
                  probe.littleWindowOpenIn == .space(check.littleSpaceID) else {
                note("after reopen visible=\(probe.isVisible) page=\(probe.pageID) open in \(probe.littleWindowOpenIn)"); return
            }
            // The reopened window reads the record rather than the model's last value.
            check.report("open_in_write_reopen",
                         probe.marker(SettingsModel.rowMarker(SettingsModel.littleWindowOpenInRowId)) != nil
                         && probe.littleWindowOpenInLabel == check.littleSpaceTitle)
            trace("recording a global shortcut")
            probe.startLittleWindowHotKeyRecording()
            step(8)
        case 8:
            guard probe.littleWindowHotKeyRecording else { return }
            // ⌃⌥⌘K: recorded through the same entry rule the mounted recorder's keyDown uses.
            guard let event = keyEvent(40, "k", [.command, .control, .option]) else { end("shortcut_recorder", false); return }
            probe.recordLittleWindowHotKey(event)
            step(9)
        case 9:
            let ok = probe.littleWindowHotKey.map { $0.keyCode == 40 && $0.key == "k" && $0.command && $0.control && $0.option && !$0.shift } ?? false
            let registered = probe.littleWindowHotKeyStatus == .registered && probe.littleWindowHotKeyMessage == nil
            check.details["hot_key"] = ["caps": probe.littleWindowHotKeyCaps,
                                        "status": String(describing: probe.littleWindowHotKeyStatus),
                                        "message": probe.littleWindowHotKeyMessage ?? ""]
            check.report("shortcut_recorder", ok && probe.littleWindowHotKeyCaps == ["⌃", "⌥", "⌘", "K"])
            check.report("hot_key_registration", registered)
            trace("opening a Little Window for the bar")
            owner.openLittleWindow(url: check.littlePageURL)
            step(10)
        case 10:
            guard let controller = popup(), let tab = popupTab(controller), !tab.isLoading,
                  tab.url == check.littlePageURL else {
                note("the Little Window's page: \(popupTab(popup())?.url ?? "-") loading=\(popupTab(popup())?.isLoading ?? false)")
                return
            }
            let wanted = "Open in " + check.littleSpaceTitle
            guard controller.bar.checkOpenTitle == wanted, controller.model.destination?.id == check.littleSpaceID else {
                note("the bar reads \(controller.bar.checkOpenTitle), want \(wanted)")
                return
            }
            check.report("open_in_bar", true)
            check.littlePageLive = tab.liveId
            check.littlePageNavigation = tab.navigationCount
            check.littleOpening = controller
            // A frame that differs from the default, so "remembering off opens at the default
            // frame" can be seen: 720 × 480 against the 640 × 400 default.
            if let window = controller.window {
                window.setFrame(NSRect(x: 200, y: 150, width: 720, height: 480), display: true)
                controller.saveFrame()
            }
            trace("close-after off")
            probe.setLittleWindowCloseAfter(false)
            step(11)
        case 11:
            guard probe.littleWindowCloseAfter == false else { note("close-after is still on"); return }
            guard let opening = check.littleOpening, let url = popupTab(opening)?.url, !url.isEmpty else {
                note("no page to open in"); return
            }
            trace("open in with close-after off")
            opening.performOpenIn()
            step(12)
        case 12:
            guard let opening = check.littleOpening, let opened = opening.checkOpenedIn else {
                note("open in has not landed"); return
            }
            guard owner.littleWindows.count == 1, let surviving = owner.littleWindows.first,
                  let tab = popupTab(surviving), !tab.isLoading, tab.url == check.littlePageURL else {
                note("windows=\(owner.littleWindows.count) pages=\(owner.littleWindows.compactMap { popupTab($0)?.url })")
                return
            }
            let destinationTab = (host?.tabs() as? [any ARTabAPI])?.first { $0.liveId == check.littlePageLive }
            let row = snapshot.spaces.flatMap { $0.today }.first { $0.id == opened.item }
            var details: [String: Any] = ["space": opened.space, "row": row?.url ?? "",
                                          "windows": owner.littleWindows.count,
                                          "surviving_page": tab.url ?? "",
                                          "destination_live": destinationTab != nil,
                                          "destination_navigation": destinationTab.map { Int($0.navigationCount) } ?? -1,
                                          "shown": snapshot.shownSpaceId ?? ""]
            details["kind"] = surviving === opening ? "same" : "reopened"
            check.details["close_after"] = details
            check.report("close_after_keeps", opened.space == check.littleSpaceID
                         && row?.url == check.littlePageURL && destinationTab != nil
                         && destinationTab?.navigationCount == 0 && snapshot.shownSpaceId == check.littleSpaceID
                         && surviving !== opening && tab.liveId != check.littlePageLive)
            trace("remember off")
            probe.setLittleWindowRememberFrame(false)
            step(13)
        case 13:
            guard probe.littleWindowRememberFrame == false else { note("remember is still on"); return }
            // The pane's push reaches the opened window as well; close after it, so the close does
            // not write a frame this device was told to forget.
            guard owner.littleWindows.allSatisfy({ $0.rememberFrame == false }) else {
                note("the Little Window has not heard the switch yet"); return
            }
            owner.littleWindows.first?.close()
            step(14)
        case 14:
            guard owner.littleWindows.isEmpty else { note("the Little Window is still open"); return }
            trace("reopening with remembering off")
            owner.openLittleWindow()
            step(15)
        case 15:
            guard let controller = popup(), let window = controller.window, controller.popup.host?.hasBrowser() == true else {
                note("the default-frame Little Window"); return
            }
            // The device record is read after the window exists; wait for it before measuring.
            guard controller.rememberFrame == false else {
                note("the window still believes it remembers its frame"); return
            }
            let size = window.frame.size
            let want = LittleWindowMetrics.defaultSize
            check.details["default_frame"] = ["width": size.width, "height": size.height]
            check.report("remember_off_frame", abs(size.width - want.width) <= 1 && abs(size.height - want.height) <= 1)
            guard capture("little-window") else { end("capture", false); return }
            finish()
        default: break
        }
    }
}
