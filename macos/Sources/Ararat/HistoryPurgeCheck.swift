import AppKit
import AraratEngineAPI
import AraratKit
import Darwin

@MainActor
final class HistoryPurgeCheck {
  private weak var runtime: Runtime?
  private var phase = 0
  private var item = ""
  private var pinned = ""
  private var failedItem = ""
  private var pinnedURL = ""
  private var stale: HistoryPurge?
  private var directory = ""
  private var purgeFailed = false
  private var originalPurge: ((String, String, UInt64, @escaping (Bool) -> Void) -> Void)?

  init(runtime: Runtime) { self.runtime = runtime }

  private func fail(_ message: String) {
    phase = -1
    runtime?.finishBrowserCheck(ok: false, values: ["error": message])
  }

  func cleanup() -> Bool {
    if let originalPurge { runtime?.adapter?.session.purgeHistory = originalPurge }
    originalPurge = nil
    guard !directory.isEmpty else { return true }
    do {
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
      directory = ""
      return true
    } catch { return false }
  }

  private func inspect(_ item: String, _ reply: @escaping ([String: Any]) -> Void) {
    guard let symbol = dlsym(Launcher.handle, "AraratCheckTabHistoryFile") else { fail("missing file check"); return }
    typealias Check = @convention(c) (UnsafeRawPointer, UnsafeRawPointer, @escaping @convention(block) (UnsafeRawPointer) -> Void) -> Void
    let call = unsafeBitCast(symbol, to: Check.self)
    let profile = "Default" as NSString
    let key = item as NSString
    call(Unmanaged.passUnretained(profile).toOpaque(), Unmanaged.passUnretained(key).toOpaque()) { pointer in
      let state = Unmanaged<NSDictionary>.fromOpaque(pointer).takeUnretainedValue() as? [String: Any] ?? [:]
      MainActor.assumeIsolated { reply(state) }
    }
  }

  private func purge(_ purge: HistoryPurge, _ reply: @escaping (Bool) -> Void) {
    guard let symbol = dlsym(Launcher.handle, "AraratPurgeTabHistory") else { fail("missing purge API"); return }
    typealias Purge = @convention(c) (UnsafeRawPointer, UnsafeRawPointer, UInt64, @escaping @convention(block) (Bool) -> Void) -> Void
    let call = unsafeBitCast(symbol, to: Purge.self)
    let profile: NSString
    switch purge.profile { case .default: profile = "Default"; case .named(let name): profile = name as NSString }
    let item = purge.item as NSString
    call(Unmanaged.passUnretained(profile).toOpaque(), Unmanaged.passUnretained(item).toOpaque(), purge.changedAt) { ok in
      MainActor.assumeIsolated { reply(ok) }
    }
  }

  private func historyDirectory() -> String? {
    guard let symbol = dlsym(Launcher.handle, "AraratUserDataDirectory") else { return nil }
    let getPath = unsafeBitCast(symbol, to: (@convention(c) () -> UnsafeRawPointer?).self)
    guard let pointer = getPath() else { return nil }
    let root = Unmanaged<NSString>.fromOpaque(pointer).takeUnretainedValue() as String
    return (root as NSString).appendingPathComponent("Default/Ararat Tab History")
  }

  private func pending(_ item: String) -> Bool {
    guard let session = runtime?.adapter?.session else { return true }
    return session.queue.sync { (try? session.store?.pendingHistoryPurges().contains(where: { $0.item == item })) ?? true }
  }

  private func live(_ item: String) -> Bool {
    guard let session = runtime?.adapter?.session else { return true }
    return session.queue.sync { session.store?.liveTab(item: item) != nil }
  }

  private func selectPinned() {
    guard let runtime, let workspace = runtime.workspace else { fail("workspace missing"); return }
    workspace.select(id: pinned) { result in
      guard case .success = result else { self.fail("pinned selection failed"); return }
      runtime.showAndSelect(result)
    }
  }

  func tick(_ host: any ARWindowHostAPI) {
    guard let runtime else { return }
    let tabs = (host.tabs() as? [any ARTabAPI]) ?? []
    if phase == 0, let row = runtime.sliceRows.first, row.url != nil {
      item = row.id; phase = 1; runtime.selectCheckSeed(row)
    } else if phase == 1, runtime.sliceActive == item,
              let tab = tabs.first(where: { $0.itemId == item }), !tab.isLoading, tab.navigationCount > 0 {
      phase = 2; host.checkNavigate("data:text/html,<title>history-purge-a2</title>", disposition: "current")
    } else if phase == 2, let tab = tabs.first(where: { $0.itemId == item }), !tab.isLoading, tab.navigationCount > 1 {
      phase = 100
      tab.checkFlushHistory { written in MainActor.assumeIsolated {
        guard written, let session = runtime.adapter?.session else { self.fail("initial history flush failed"); return }
        let archiveItem = self.item
        guard let original = session.purgeHistory else { self.fail("purge API missing"); return }
        self.originalPurge = original
        session.purgeHistory = { profile, item, stamp, completion in
          if item == archiveItem, self.stale == nil {
            self.stale = session.queue.sync {
              try? session.store?.pendingHistoryPurges().first(where: { $0.item == archiveItem })
            }
            session.purgeHistory = original
          }
          original(profile, item, stamp, completion)
        }
        session.queue.async {
          do {
            guard let store = session.store else { throw NSError(domain: "history-check", code: 1) }
            let command = try store.liveArchive(item: archiveItem)
            session.drainHistoryPurges()
            DispatchQueue.main.async {
              guard let host = self.runtime?.host,
                    let tab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == self.item }) else { self.fail("archive tab missing"); return }
              self.phase = 3
              tab.close(withCommandId: command.id)
            }
          } catch { DispatchQueue.main.async { self.fail("archive failed: \(error)") } }
        }
      } }
    } else if phase == 3, stale != nil, !pending(item), !live(item), !tabs.contains(where: { $0.itemId == item }) {
      phase = 100
      inspect(item) { state in
        guard state["exists"] as? Bool == false, let workspace = runtime.workspace else { self.fail("archived file still exists"); return }
        workspace.restore(id: self.item) { result in
          guard case .success = result else { self.fail("restore failed"); return }
          self.phase = 4; runtime.showAndSelect(result, selectedItem: self.item)
        }
      }
    } else if phase == 4, runtime.sliceActive == item,
              let tab = tabs.first(where: { $0.itemId == item }), !tab.isLoading, tab.navigationCount > 0 {
      phase = 5; host.checkNavigate("data:text/html,<title>history-purge-restored</title>", disposition: "current")
    } else if phase == 5, let tab = tabs.first(where: { $0.itemId == item }), !tab.isLoading, tab.navigationCount > 1 {
      phase = 100
      tab.checkFlushHistory { written in MainActor.assumeIsolated {
        guard written, let stale = self.stale else { self.fail("restored flush failed"); return }
        self.purge(stale) { ok in
          guard ok else { self.fail("stale purge failed"); return }
          self.inspect(self.item) { state in
            guard state["exists"] as? Bool == true, state["count"] as? Int == 2,
                  let workspace = runtime.workspace else { self.fail("stale purge removed new file"); return }
            self.phase = 100
            workspace.createTab(url: "data:text/html,<title>history-pinned-a</title>") { result in
              guard case .success(let created) = result, let id = created.id else { self.fail("pinned fixture failed"); return }
              self.pinned = id; self.phase = 6; runtime.showAndSelect(result.map(\.snapshot))
            }
          }
        }
      } }
    } else if phase == 6, runtime.sliceActive == pinned,
              let tab = tabs.first(where: { $0.itemId == pinned }), !tab.isLoading, tab.navigationCount > 0,
              let space = runtime.snapshot.spaces.first(where: { $0.id == runtime.snapshot.shownSpaceId }),
              let workspace = runtime.workspace {
      pinnedURL = tab.url; phase = 100
      workspace.move(id: pinned, container: space.pinnedId, index: 0, openFolder: false) { result in
        guard case .success = result else { self.fail("pin failed"); return }
        runtime.showResult(result); self.phase = 7
        runtime.host?.checkNavigate("data:text/html,<title>history-pinned-b</title>", disposition: "current")
      }
    } else if phase == 7, let tab = tabs.first(where: { $0.itemId == pinned }), !tab.isLoading, tab.navigationCount > 1 {
      phase = 8; host.checkKeyboardCommand("back")
    } else if phase == 8, let tab = tabs.first(where: { $0.itemId == pinned }), !tab.isLoading, tab.url == pinnedURL, !tab.canGoBack {
      phase = 100
      tab.checkFlushHistory { written in MainActor.assumeIsolated {
        guard written else { self.fail("pinned flush failed"); return }
        self.phase = 9; runtime.adapter?.close(id: self.pinned, archive: false)
      } }
    } else if phase == 9, !live(pinned), !tabs.contains(where: { $0.itemId == pinned }) {
      guard !pending(pinned) else { fail("unload queued purge"); return }
      phase = 100
      inspect(pinned) { state in
        guard state["exists"] as? Bool == true else { self.fail("unload removed file"); return }
        self.phase = 10; self.selectPinned()
      }
    } else if phase == 10, runtime.sliceActive == pinned,
              let tab = tabs.first(where: { $0.itemId == pinned }), !tab.isLoading, tab.navigationCount > 0 {
      guard tab.entryCount == 2, !tab.canGoBack else { fail("pinned matching history not restored"); return }
      phase = 11; host.checkNavigate("data:text/html,<title>history-pinned-c</title>", disposition: "current")
    } else if phase == 11, let tab = tabs.first(where: { $0.itemId == pinned }), !tab.isLoading, tab.url != pinnedURL, tab.navigationCount > 1 {
      phase = 100
      tab.checkFlushHistory { written in MainActor.assumeIsolated {
        guard written else { self.fail("pinned moved flush failed"); return }
        self.phase = 12; runtime.adapter?.close(id: self.pinned, archive: false)
      } }
    } else if phase == 12, !live(pinned), !tabs.contains(where: { $0.itemId == pinned }) {
      phase = 13; selectPinned()
    } else if phase == 13, runtime.sliceActive == pinned,
              let tab = tabs.first(where: { $0.itemId == pinned }), !tab.isLoading, tab.navigationCount > 0 {
      guard tab.entryCount == 1, tab.url == pinnedURL else { fail("pinned mismatch did not open fresh"); return }
      phase = 100
      tab.checkFlushHistory { written in MainActor.assumeIsolated {
        guard written else { self.fail("corrupt fixture setup failed"); return }
        self.phase = 14; runtime.adapter?.close(id: self.pinned, archive: false)
      } }
    } else if phase == 14, !live(pinned), !tabs.contains(where: { $0.itemId == pinned }) {
      guard let directory = historyDirectory() else { fail("missing history directory"); return }
      let name = pinned.utf8.map { String(format: "%02X", $0) }.joined()
      do { try Data("garbage".utf8).write(to: URL(fileURLWithPath: directory).appendingPathComponent(name)) }
      catch { fail("cannot corrupt file: \(error)"); return }
      phase = 15; selectPinned()
    } else if phase == 15, runtime.sliceActive == pinned,
              let tab = tabs.first(where: { $0.itemId == pinned }), !tab.isLoading, tab.navigationCount > 0 {
      guard tab.entryCount == 1 else { fail("corrupt file restored history"); return }
      phase = 100
      inspect(pinned) { state in
        let removed = state["exists"] as? Bool == false
        let replaced = state["generation_current"] as? Bool == true && (state["count"] as? Int ?? 0) > 0
        guard (removed || replaced), let workspace = runtime.workspace else { self.fail("corrupt file remained"); return }
        workspace.createTab(url: "data:text/html,<title>history-purge-failure</title>") { result in
          guard case .success(let created) = result, let id = created.id else { self.fail("failure fixture failed"); return }
          self.failedItem = id; self.phase = 16; runtime.showAndSelect(result.map(\.snapshot))
        }
      }
    } else if phase == 16, runtime.sliceActive == failedItem,
              let tab = tabs.first(where: { $0.itemId == failedItem }), !tab.isLoading, tab.navigationCount > 0 {
      phase = 100
      tab.checkFlushHistory { written in MainActor.assumeIsolated {
        guard written, let dir = self.historyDirectory(), let session = runtime.adapter?.session,
              let original = session.purgeHistory else { self.fail("failure fixture flush failed"); return }
        self.originalPurge = original
        session.purgeHistory = { profile, item, stamp, completion in
          original(profile, item, stamp) { ok in
            if !ok && item == self.failedItem { self.purgeFailed = true }
            completion(ok)
          }
        }
        self.directory = dir
        do { try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir) }
        catch { self.fail("cannot restrict directory: \(error)"); return }
        self.phase = 17; runtime.adapter?.close(id: self.failedItem, archive: false)
      } }
    } else if phase == 17, purgeFailed, pending(failedItem), !live(failedItem), !tabs.contains(where: { $0.itemId == failedItem }) {
      do { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory) }
      catch { fail("cannot restore directory: \(error)"); return }
      directory = ""; phase = 18
      if let originalPurge { runtime.adapter?.session.purgeHistory = originalPurge }
      if let session = runtime.adapter?.session { session.queue.async { session.drainHistoryPurges() } }
    } else if phase == 18, !pending(failedItem) {
      phase = 100
      inspect(failedItem) { state in
        let ok = state["exists"] as? Bool == false
        runtime.finishBrowserCheck(ok: ok, values: ["purge_retry_removed_file": ok, "stale_purge_preserved_file": true, "pinned_history": true, "corrupt_rejected": true])
      }
    }
  }
}
