import Foundation
import AraratKit

@MainActor
public final class AutoArchive {
    private let adapter: WorkspaceAdapter
    private let now: () -> UInt64
    private let canPublish: () -> Bool
    private let receive: WorkspaceAdapter.Completion<WorkspaceSnapshot>
    public var onPublishReady: (() -> Void)?
    private var needsPublish = false
    private(set) var timer: Timer?

    public init(adapter: WorkspaceAdapter, now: @escaping () -> UInt64 = { UInt64(max(0, Date().timeIntervalSince1970 * 1000)) }, canPublish: @escaping () -> Bool = { true }, receive: @escaping WorkspaceAdapter.Completion<WorkspaceSnapshot>) {
        self.adapter = adapter
        self.now = now
        self.canPublish = canPublish
        self.receive = receive
    }
    public func start() {
        stop()
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 20
    }
    public func tick() {
        adapter.autoArchive(now: now()) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let snapshot):
                if let snapshot { self.deliver(.success(snapshot)) }
                else { self.publishDeferred() }
            case .failure(let error): self.deliver(.failure(error))
            }
        }
    }
    public func publishDeferred() {
        guard canPublish() else { return }
        onPublishReady?()
        guard needsPublish else { return }
        needsPublish = false
        adapter.snapshot { [weak self] result in self?.deliver(result) }
    }
    private func deliver(_ result: Result<WorkspaceSnapshot, Error>) {
        guard canPublish() else { needsPublish = true; return }
        needsPublish = false
        onPublishReady?()
        receive(result)
    }
    public func stop() { timer?.invalidate(); timer = nil }
}
