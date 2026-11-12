import AppKit
import AraratEngineAPI
import AraratKit
import AraratUI

/// U26f pass 4: the private-durability driver's two in-app halves. The seed opens two private
/// windows with uniquely titled tabs and reports them; the verify, run after a clean quit and
/// after a SIGKILL, proves nothing private was restored or written.
@MainActor
extension Runtime {
    func privateDurabilityTick(_ host: any ARWindowHostAPI, mode: String) {
        let relaunch = CommandLine.arguments.first(where: { $0.hasPrefix("--ararat-relaunch-mode=") })
            .map { String($0.dropFirst("--ararat-relaunch-mode=".count)) } ?? ""
        if mode == "private-durability-seed" {
            switch browserCheckPhase {
            case 0:
                guard let row = sliceRows.first, let url = row.url else {
                    FileHandle.standardError.write(Data("ararat-trace: private-durability wait=seed row\n".utf8)); return
                }
                browserCheckSeedID = row.id
                selectCheckSeed(row)
                browserCheckPhase = 1
            case 1:
                guard let seed = browserCheckSeedID, snapshot.selectedId == seed, sliceActive == seed else {
                    FileHandle.standardError.write(Data("ararat-trace: private-durability wait=seed selected\n".utf8)); return
                }
                host.checkCreateIncognito()
                browserCheckPhase = 2
            case 2:
                guard let child = children.first(where: { $0.isPrivateWindow && $0.host != nil }),
                      let snap = child.adapter?.session.queue.sync(execute: { child.adapter?.session.store?.snapshot(windowId: child.windowID) }),
                      let space = snap.shownSpaceId else {
                    FileHandle.standardError.write(Data("ararat-trace: private-durability wait=private window\n".utf8)); return
                }
                let unique = UUID().uuidString
                privateDurabilityTitles = ["ararat-private-\(unique)-a", "ararat-private-\(unique)-b"]
                let profile = child.privateProfile ?? "Default"
                for title in privateDurabilityTitles {
                    child.adapter?.openCommandURL("data:text/html,<title>\(title)</title>", expectedSpace: space, profile: profile)
                }
                browserCheckPhase = 3
            case 3:
                guard let child = children.first(where: { $0.isPrivateWindow && $0.host != nil }),
                      let snap = child.adapter?.session.queue.sync(execute: { child.adapter?.session.store?.snapshot(windowId: child.windowID) }),
                      let today = snap.spaces.first?.today,
                      privateDurabilityTitles.allSatisfy({ title in today.contains { $0.title == title } }) else {
                    FileHandle.standardError.write(Data("ararat-trace: private-durability wait=private tabs\n".utf8)); return
                }
                let ready: [String: Any] = ["ready": true, "titles": privateDurabilityTitles,
                                            "urls": privateDurabilityTitles.map { "data:text/html,<title>\($0)</title>" }]
                if let data = try? JSONSerialization.data(withJSONObject: ready, options: [.sortedKeys]),
                   let line = String(data: data, encoding: .utf8) { print(line); fflush(stdout) }
                if relaunch == "private-clean" { finishBrowserCheck(ok: true, values: ["ready": true]) }
                // In the crash run the driver kills this process after the ready line.
            default:
                break
            }
            return
        }
        // Verify: wait for the initial regular snapshot, then prove nothing private came back.
        if privateDurabilityTitles.isEmpty,
           let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--ararat-private-titles=") }),
           let data = Data(base64Encoded: String(argument.dropFirst("--ararat-private-titles=".count))),
           let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String] {
            privateDurabilityTitles = parsed
        }
        guard !snapshot.spaces.isEmpty else {
            FileHandle.standardError.write(Data("ararat-trace: private-durability wait=regular snapshot\n".utf8)); return
        }
        let titles = privateDurabilityTitles
        let rows = snapshot.spaces.flatMap { $0.today + $0.pinned + $0.favorites }
        let archived = snapshot.archive
        let privateRows = rows.filter { titles.contains($0.title) }
        let privateArchive = archived.filter { titles.contains($0.title) }
        let privateChildren = children.filter(\.isPrivateWindow).count
        let liveOTR = (host.checkProfileState()["browsers"] as? [[String: Any]] ?? []).contains { $0["off_the_record"] as? Bool == true }
        let ok = privateChildren == 0 && PrivateWorkspaces.liveCount == 0 && privateRows.isEmpty &&
            privateArchive.isEmpty && !liveOTR
        finishBrowserCheck(ok: ok, values: ["ready": true, "private_children": privateChildren,
                                            "private_live": PrivateWorkspaces.liveCount,
                                            "private_rows": privateRows.map(\.title),
                                            "private_archive": privateArchive.map(\.title),
                                            "live_off_the_record": liveOTR,
                                            "restored_regular_rows": rows.count])
    }
}
