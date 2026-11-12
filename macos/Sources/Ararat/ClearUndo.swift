import AppKit
import AraratKit

func clearUndoSelection(_ snapshot: WorkspaceSnapshot) -> Row? {
  guard let selected = snapshot.selectedId,
        let space = snapshot.spaces.first(where: { $0.id == snapshot.shownSpaceId }) else { return nil }
  let rows = space.today + space.pinned + space.favorites
  guard rows.contains(where: { $0.id == splitOwner(selected, rows: rows) }) else { return nil }
  return rows.first { $0.id == selected && $0.kind == .tab && $0.unloaded }
}

@MainActor
final class ClearUndo {
  private var action: (() -> Void)?
  private var generation = 0
  var schedule: (TimeInterval, @escaping () -> Void) -> Void = { delay, action in
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
  }
  var available: Bool { action != nil }

  func offer(_ action: @escaping () -> Void) {
    generation += 1
    let current = generation
    self.action = action
    schedule(5) { [weak self] in
      guard let self, self.generation == current else { return }
      self.action = nil
    }
  }

  func run() {
    let action = action
    self.action = nil
    generation += 1
    action?()
  }
}
