import Foundation
import AraratKit

@MainActor
public final class AutoArchive {
    private let adapter: WorkspaceAdapter
    private let now: () -> UInt64
    private let canPublish: () -> Bool
    private let receive: WorkspaceAdapter.Completion<WorkspaceSnapshot>
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
        guard canPublish() else { return }
        if needsPublish {
            needsPublish = false
            adapter.snapshot { [weak self] result in self?.deliver(result) }
        } else {
            adapter.autoArchive(now: now()) { [weak self] result in
                switch result {
                case .success(let snapshot): if let snapshot { self?.deliver(.success(snapshot)) }
                case .failure(let error): self?.deliver(.failure(error))
                }
            }
        }
    }
    private func deliver(_ result: Result<WorkspaceSnapshot, Error>) {
        guard canPublish() else { needsPublish = true; return }
        receive(result)
    }
    public func stop() { timer?.invalidate(); timer = nil }
}
