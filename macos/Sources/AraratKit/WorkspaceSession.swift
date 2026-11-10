import AppKit
import AraratEngineAPI

public final class WorkspaceSession: @unchecked Sendable {
    private final class WeakAdapter {
        weak var value: EngineAdapter?
        init(_ value: EngineAdapter) { self.value = value }
    }
    public let queue = DispatchQueue(label: "Ararat.workspace")
    public var store: WorkspaceStore?
    public var purgeHistory: ((String, String, UInt64, @escaping (Bool) -> Void) -> Void)?
    public var finishCrashRecovery: (() -> Void)?
    private var inFlight: Set<String> = []
    private var retryScheduled = false
    private var adapters: [String: WeakAdapter] = [:]
    private var keyOrder: [String: UInt64] = [:]
    private var keySequence: UInt64 = 0
    private var snapshots: [String: (image: NSImage, time: TimeInterval)] = [:]
    private var snapshotGeneration: [String: UInt64] = [:]
    private var snapshotSerial: UInt64 = 0
    private var snapshotInFlight: Set<String> = []
    private var expectedTransfers: [String: (destination: String, token: UInt64)] = [:]
    private var transferSerial: UInt64 = 0

    public init() {}

    func register(_ adapter: EngineAdapter, window: String) {
        precondition(Thread.isMainThread)
        adapters[window] = WeakAdapter(adapter)
    }

    func unregister(_ adapter: EngineAdapter, window: String) {
        precondition(Thread.isMainThread)
        if adapters[window]?.value === adapter { adapters.removeValue(forKey: window) }
        keyOrder.removeValue(forKey: window)
    }

    func noteKey(window: String) {
        precondition(Thread.isMainThread)
        keySequence &+= 1
        keyOrder[window] = keySequence
    }

    struct Handoff {
        let live: String
        let item: String
        let profile: String
        let target: EngineAdapter
        let activate: Bool
    }

    func handoffs(from source: EngineAdapter) -> [Handoff] {
        precondition(Thread.isMainThread)
        guard let host = source.host else { return [] }
        let tabs = (host.tabs() as? [any ARTabAPI]) ?? []
        var result: [Handoff] = []
        for tab in tabs {
            guard let item = tab.itemId else { continue }
            let profile: String? = queue.sync {
                guard let profile = store?.itemProfile(itemId: item) else { return nil }
                switch profile { case .default: return "Default"; case .named(let name): return name }
            }
            guard let profile else { continue }
            let candidates: [(EngineAdapter, Bool)] = adapters.values.compactMap { entry in
                guard let adapter = entry.value, adapter !== source, let target = adapter.host,
                      !target.isClosing(), !target.isClosingAll(),
                      (target as AnyObject).responds(to: #selector(ARWindowHostAPI.handoffTab(_:activate:))),
                      (target as AnyObject).responds(to: #selector(ARWindowHostAPI.prepareTransferProfile(_:))) else { return nil }
                let shown: (Bool, Bool) = queue.sync {
                    guard let store else { return (false, false) }
                    let snapshot = store.snapshot(windowId: adapter.windowID)
                    guard let selected = snapshot.selectedId,
                          let space = snapshot.spaces.first(where: { $0.id == snapshot.shownSpaceId }),
                          (space.today + space.pinned + space.favorites).contains(where: { $0.id == selected }) else { return (false, false) }
                    if selected == item { return (true, true) }
                    guard let split = store.splitLayout(itemId: selected) else { return (false, false) }
                    func contains(_ pane: SplitPane) -> Bool { pane.id == item || pane.children.contains(where: contains) }
                    return (contains(split), false)
                }
                return shown.0 ? (adapter, shown.1) : nil
            }
            let sorted = candidates.sorted { left, right in
                func isKey(_ adapter: EngineAdapter) -> Bool {
                    guard let host = adapter.host, (host as AnyObject).responds(to: #selector(ARWindowHostAPI.window)) else { return false }
                    return host.window().isKeyWindow
                }
                let leftKey = isKey(left.0), rightKey = isKey(right.0)
                if leftKey != rightKey { return leftKey }
                let leftOrder = keyOrder[left.0.windowID, default: 0], rightOrder = keyOrder[right.0.windowID, default: 0]
                if leftOrder != rightOrder { return leftOrder > rightOrder }
                return left.0.windowID < right.0.windowID
            }
            if let chosen = sorted.first { result.append(Handoff(live: tab.liveId, item: item, profile: profile, target: chosen.0, activate: chosen.1)) }
        }
        return result.sorted { $0.live < $1.live }
    }

    func tab(_ id: String) -> (any ARTabAPI)? {
        precondition(Thread.isMainThread)
        for adapter in adapters.values {
            if let tab = adapter.value?.tab(id) { return tab }
        }
        return nil
    }

    func cancelPendingOpen(_ id: String) -> Bool {
        precondition(Thread.isMainThread)
        return adapters.values.contains { $0.value?.cancelPendingOpen(id) == true }
    }

    func snapshot(_ live: String) -> NSImage? {
        precondition(Thread.isMainThread)
        guard let cached = snapshots[live], Date.timeIntervalSinceReferenceDate - cached.time <= 15 else {
            snapshots.removeValue(forKey: live)
            return nil
        }
        return cached.image
    }

    func invalidateSnapshot(_ live: String) {
        precondition(Thread.isMainThread)
        snapshotGeneration.removeValue(forKey: live)
        snapshots.removeValue(forKey: live)
        snapshotInFlight.remove(live)
    }

    func beginTransfer(_ live: String, destination: String) {
        precondition(Thread.isMainThread)
        snapshotGeneration.removeValue(forKey: live)
        snapshotInFlight.remove(live)
        transferSerial &+= 1
        let token = transferSerial
        expectedTransfers[live] = (destination, token)
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(35)) { [weak self] in
            guard let self, self.expectedTransfers[live]?.token == token else { return }
            self.expectedTransfers.removeValue(forKey: live)
            self.invalidateSnapshot(live)
        }
    }

    func noteTransfer(_ live: String, destination: String) {
        precondition(Thread.isMainThread)
        if expectedTransfers[live]?.destination == destination { expectedTransfers.removeValue(forKey: live); return }
        invalidateSnapshot(live)
        expectedTransfers.removeValue(forKey: live)
    }

    func cancelTransfer(_ live: String, destination: String) {
        precondition(Thread.isMainThread)
        guard expectedTransfers[live]?.destination == destination else { return }
        expectedTransfers.removeValue(forKey: live)
        invalidateSnapshot(live)
    }

    func captureSnapshot(_ tab: any ARTabAPI, item: String) {
        precondition(Thread.isMainThread)
        let live = tab.liveId
        guard snapshot(live) == nil, (tab as AnyObject).responds(to: #selector(ARTabAPI.captureSnapshot(_:))),
              snapshotInFlight.insert(live).inserted else { return }
        snapshotSerial &+= 1
        let generation = snapshotSerial
        snapshotGeneration[live] = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(1)) { [weak self] in
            guard let self, self.snapshotGeneration[live] == generation,
                  self.snapshotInFlight.contains(live) else { return }
            self.invalidateSnapshot(live)
        }
        tab.captureSnapshot { [weak self] image in
            DispatchQueue.main.async {
                guard let self, self.snapshotGeneration[live] == generation else { return }
                self.snapshotGeneration.removeValue(forKey: live)
                self.snapshotInFlight.remove(live)
                guard let image, self.queue.sync(execute: { self.store?.liveTab(item: item) == live }) else { return }
                if self.snapshots.count >= 16, let oldest = self.snapshots.min(by: { $0.value.time < $1.value.time })?.key {
                    self.snapshots.removeValue(forKey: oldest)
                }
                self.snapshots[live] = (image, Date.timeIntervalSinceReferenceDate)
                for adapter in self.adapters.values { adapter.value?.refresh() }
            }
        }
    }

    public func drainHistoryPurges() {
        dispatchPrecondition(condition: .onQueue(queue))
        do {
            guard let store else { return }
            let pending = try store.pendingHistoryPurges().filter { inFlight.insert($0.id).inserted }
            DispatchQueue.main.async { for purge in pending { self.submitHistoryPurge(purge) } }
        } catch {
            FileHandle.standardError.write(Data("ararat-history: purge-list-failed \(error)\n".utf8))
            scheduleHistoryRetry()
        }
    }

    public func submitHistoryPurge(_ purge: HistoryPurge) {
        precondition(Thread.isMainThread)
        let directory: String
        switch purge.profile { case .default: directory = "Default"; case .named(let name): directory = name }
        guard let purgeHistory else {
            queue.async {
                self.inFlight.remove(purge.id)
                self.scheduleHistoryRetry()
            }
            return
        }
        purgeHistory(directory, purge.item, purge.changedAt) { ok in
            self.queue.async {
                self.inFlight.remove(purge.id)
                do {
                    if ok { try self.store?.acknowledgeHistoryPurge(id: purge.id); return }
                } catch {
                    FileHandle.standardError.write(Data("ararat-history: purge-ack-failed id=\(purge.id) \(error)\n".utf8))
                }
                FileHandle.standardError.write(Data("ararat-history: purge-failed id=\(purge.id) item=\(purge.item)\n".utf8))
                self.scheduleHistoryRetry()
            }
        }
    }

    private func scheduleHistoryRetry() {
        guard !retryScheduled else { return }
        retryScheduled = true
        queue.asyncAfter(deadline: .now() + 30) {
            self.retryScheduled = false
            self.drainHistoryPurges()
        }
    }
}
