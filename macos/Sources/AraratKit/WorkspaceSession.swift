import Foundation

public final class WorkspaceSession: @unchecked Sendable {
    public let queue = DispatchQueue(label: "Ararat.workspace")
    public var store: WorkspaceStore?
    public var purgeHistory: ((String, String, UInt64, @escaping (Bool) -> Void) -> Void)?
    public var finishCrashRecovery: (() -> Void)?
    private var inFlight: Set<String> = []
    private var retryScheduled = false

    public init() {}

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
