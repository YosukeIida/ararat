import Foundation

public final class WorkspaceSession: @unchecked Sendable {
    public let queue = DispatchQueue(label: "Ararat.workspace")
    public var store: WorkspaceStore?

    public init() {}
}
