import AppKit
import AraratEngineAPI
import AraratKit
import AraratUI

@MainActor
final class PrivateDownloadsCheckState {
    static let names = ["private_window", "private_download_saved", "private_no_prompt",
                        "private_list_has_download", "private_regular_list_clean",
                        "private_list_released", "private_file_kept"]
    var conditions: [String: Bool] = [:]
    var waitName = ""
    var waitCount = 0
    var directory = ""
    var guid = ""

    func mark(_ name: String, _ value: Bool = true) {
        conditions[name] = value
        FileHandle.standardError.write(Data("ararat-trace: private-downloads \(name)=\(value)\n".utf8))
    }

    func wait(_ name: String, _ value: @autoclosure () -> String) {
        if waitName != name || waitCount % 20 == 0 {
            FileHandle.standardError.write(Data("ararat-trace: private-downloads wait=\(name) \(value())\n".utf8))
        }
        if waitName != name { waitName = name; waitCount = 0 }
        waitCount += 1
    }

    func diagnostics() -> [String: Any] {
        ["check": "private-downloads",
         "conditions": Dictionary(uniqueKeysWithValues: Self.names.map { ($0, conditions[$0] == true) }),
         "failed_conditions": Self.names.filter { conditions[$0] != true },
         "wait": waitName, "directory": directory, "guid": guid]
    }
}

/// U26f pass 4: a private window's download lists only in that window's Library button list, is
/// gone after the last private window closes, and saves to the regular folder without asking.
@MainActor
extension Runtime {
    func privateDownloadsCheckTick(_ host: any ARWindowHostAPI) {
        if privateDownloadsCheck == nil { privateDownloadsCheck = PrivateDownloadsCheckState() }
        guard let check = privateDownloadsCheck else { return }
        func wait(_ name: String) {
            check.wait(name, "phase=\(browserCheckPhase) children=\(children.count) private=\(children.filter(\.isPrivateWindow).count) live=\(PrivateWorkspaces.liveCount)")
        }
        func privateChildren() -> [Runtime] { children.filter { $0.isPrivateWindow && $0.host != nil } }

        switch browserCheckPhase {
        case 0:
            guard let row = sliceRows.first, let url = row.url else { wait("seed row"); return }
            browserCheckSeedID = row.id
            selectCheckSeed(row)
            browserCheckPhase = 1
        case 1:
            guard let seed = browserCheckSeedID, snapshot.selectedId == seed, sliceActive == seed else {
                wait("seed selected"); return
            }
            quitBefore = captureCheckRows()
            browserCheckBefore = snapshot
            host.checkCreateIncognito()
            browserCheckPhase = 2
        case 2:
            guard let child = privateChildren().first, let privateHost = child.host,
                  privateHost.isPrivateWindow(), privateHost.hasBrowser(),
                  promptFixturePort != nil else { wait("private window"); return }
            check.mark("private_window")
            guard privateHost.prepareCheckDownload() else { wait("private download directory"); return }
            let settings = privateHost.downloadsCheckSettings()
            check.directory = settings["directory"] as? String ?? ""
            check.mark("private_no_prompt", (settings["prompt"] as? Bool) == false)
            guard let port = promptFixturePort, !check.directory.isEmpty else { wait("fixture port"); return }
            privateHost.window().makeKeyAndOrderFront(nil)
            privateHost.checkNavigate("http://127.0.0.1:\(port)/private-download?pass=0", disposition: "current")
            browserCheckPhase = 3
        case 3:
            guard let child = privateChildren().first, let privateHost = child.host else { wait("private download window"); return }
            let path = (check.directory as NSString).appendingPathComponent("private-check.txt")
            guard FileManager.default.fileExists(atPath: path),
                  privateHost.checkInProgressDownloadCount() == 0,
                  privateHost.window().attachedSheet == nil else { wait("private file completed without a prompt"); return }
            check.mark("private_download_saved", true)
            let items = privateHost.downloads()
            check.guid = items.first?["id"] as? String ?? ""
            check.mark("private_list_has_download", !items.isEmpty)
            guard let guid = items.first?["id"] as? String else { wait("private list item"); return }
            check.guid = guid
            // The regular window's own model never receives the private manager's items.
            let regularIDs = Set(sidebar?.checkDownloadIDs ?? [])
            check.mark("private_regular_list_clean", !regularIDs.contains(guid))
            guard regularIDs.isDisjoint(with: Set(items.compactMap { $0["id"] as? String })) else {
                wait("regular list clean"); return
            }
            privateHost.close()
            browserCheckPhase = 4
        case 4:
            guard privateChildren().isEmpty, PrivateWorkspaces.liveCount == 0 else { wait("last private window closed"); return }
            guard FileManager.default.fileExists(atPath: (check.directory as NSString).appendingPathComponent("private-check.txt")) else {
                wait("downloaded file kept"); return
            }
            check.mark("private_file_kept")
            host.checkCreateIncognito()
            browserCheckPhase = 5
        case 5:
            guard let child = privateChildren().first, let privateHost = child.host else { wait("new private window"); return }
            check.mark("private_list_released", privateHost.downloads().isEmpty)
            let result = check.diagnostics()
            finishBrowserCheck(ok: (result["failed_conditions"] as? [String] ?? ["invalid"]).isEmpty &&
                               host.checkStockBrowsers() == 0, values: result)
        default:
            break
        }
    }
}
