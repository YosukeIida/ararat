import AppKit
import AraratEngineAPI
import AraratKit
import Darwin

@MainActor
final class HistoryClearCheck {
  private weak var runtime: Runtime?
  private var phase = 0
  private var item = ""
  private var newItem = ""
  private var generation = ""

  init(runtime: Runtime) { self.runtime = runtime }

  private func inspect(_ item: String, _ reply: @escaping ([String: Any]) -> Void) {
    guard let symbol = dlsym(Launcher.handle, "AraratCheckTabHistoryFile") else { fail("missing file check"); return }
    typealias Check = @convention(c) (UnsafeRawPointer, UnsafeRawPointer, @escaping @convention(block) (UnsafeRawPointer) -> Void) -> Void
    let check = unsafeBitCast(symbol, to: Check.self)
    let profile = "Default" as NSString
    let key = item as NSString
    check(Unmanaged.passUnretained(profile).toOpaque(), Unmanaged.passUnretained(key).toOpaque()) { pointer in
      let state = Unmanaged<NSDictionary>.fromOpaque(pointer).takeUnretainedValue() as? [String: Any] ?? [:]
      MainActor.assumeIsolated { reply(state) }
    }
  }

  private func delete(_ mode: Int, _ reply: @escaping (Bool) -> Void) {
    guard let symbol = dlsym(Launcher.handle, "AraratCheckDeleteHistory") else { fail("missing delete check"); return }
    typealias Check = @convention(c) (UnsafeRawPointer, Int, @escaping @convention(block) (Bool) -> Void) -> Void
    let check = unsafeBitCast(symbol, to: Check.self)
    let profile = "Default" as NSString
    check(Unmanaged.passUnretained(profile).toOpaque(), mode) { ok in MainActor.assumeIsolated { reply(ok) } }
  }

  private func fail(_ message: String) {
    phase = -1
    runtime?.finishBrowserCheck(ok: false, values: ["error": message])
  }

  func tick(_ host: any ARWindowHostAPI) {
    guard let runtime else { return }
    let tabs = (host.tabs() as? [any ARTabAPI]) ?? []
    if phase == 0, let row = runtime.sliceRows.first, row.url != nil {
      item = row.id
      phase = 1
      runtime.selectCheckSeed(row)
    } else if phase == 1, runtime.sliceActive == item,
              let tab = tabs.first(where: { $0.itemId == item }), !tab.isLoading, tab.navigationCount > 0 {
      phase = 2
      host.checkNavigate("data:text/html,<title>history-clear-b</title>", disposition: "current")
    } else if phase == 2, let tab = tabs.first(where: { $0.itemId == item }), !tab.isLoading, tab.navigationCount > 1 {
      phase = 3
      host.checkNavigate("data:text/html,<title>history-clear-c</title>", disposition: "current")
    } else if phase == 3, let tab = tabs.first(where: { $0.itemId == item }), !tab.isLoading, tab.navigationCount > 2 {
      phase = 100
      tab.checkFlushHistory { written in MainActor.assumeIsolated {
        guard written else { self.fail("initial flush failed"); return }
        self.inspect(self.item) { state in
          guard state["exists"] as? Bool == true, let old = state["generation"] as? String else { self.fail("initial file missing"); return }
          self.generation = old
          self.delete(0) { ok in
            guard ok else { self.fail("clear failed"); return }
            self.inspect(self.item) { state in
              guard state["exists"] as? Bool == false, let current = state["generation"] as? String, current != self.generation else { self.fail("clear retained file or generation"); return }
              guard let currentHost = self.runtime?.host else { self.fail("host closed"); return }
              self.phase = 4
              currentHost.checkNavigate("data:text/html,<title>history-clear-d</title>", disposition: "current")
            }
          }
        }
      } }
    } else if phase == 4, let tab = tabs.first(where: { $0.itemId == item }), !tab.isLoading, tab.navigationCount > 3 {
      phase = 100
      tab.checkFlushHistory { written in MainActor.assumeIsolated {
        guard !written, let workspace = runtime.workspace else { self.fail("old writer was not fenced"); return }
        workspace.createTab(url: "data:text/html,<title>history-clear-new</title>") { result in
          guard case .success(let snapshot) = result, let id = snapshot.selectedId else { self.fail("new tab creation failed"); return }
          self.newItem = id
          self.phase = 5
          runtime.showAndSelect(result)
        }
      } }
    } else if phase == 5, runtime.sliceActive == newItem,
              let tab = tabs.first(where: { $0.itemId == newItem }), !tab.isLoading, tab.navigationCount > 0 {
      phase = 100
      tab.checkFlushHistory { written in MainActor.assumeIsolated {
        guard written else { self.fail("new writer failed"); return }
        self.inspect(self.newItem) { state in
          guard state["exists"] as? Bool == true, state["generation_current"] as? Bool == true else { self.fail("new file invalid"); return }
          self.delete(2) { ok in
            guard ok else { self.fail("expiration check failed"); return }
            self.inspect(self.newItem) { after in
              guard after["exists"] as? Bool == true else { self.fail("expiration deleted history"); return }
              self.delete(1) { ok in
                guard ok else { self.fail("DeleteURLs failed"); return }
                self.inspect(self.newItem) { final in
                  guard final["exists"] as? Bool == false else { self.fail("DeleteURLs retained file"); return }
                  self.phase = 6
                  runtime.finishBrowserCheck(ok: true, values: ["clear": true, "expiration_ignored": true, "delete_url": true])
                }
              }
            }
          }
        }
      } }
    }
  }
}
