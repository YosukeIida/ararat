// Folder drag rules adapted from Yab's ColumnDrag.swift (Copyright 2026 Serafim Korablev).
// Apache-2.0, see third_party/yab/LICENSE. Uses Ararat's pointer geometry and preview rows.
import AppKit
import AraratKit

enum SidebarDragMetrics {
    static let threshold: CGFloat = 3
    static let lineWidth: CGFloat = 2
    static let ringDiameter: CGFloat = 7
    static let lineLeading: CGFloat = 16
    static let lineTrailing: CGFloat = 12
    static let settleDuration = 0.100
    static let folderHoverDelay = 0.600
    static let rowBoundaryInset: CGFloat = 2.5
    static let autoscrollEdge: CGFloat = 24
    static let autoscrollSpeed: CGFloat = 240

    static func favoriteColumns(width: CGFloat, slots: Int) -> Int {
        min(max(1, Int((width + 8) / 55)), min(4, max(1, slots)))
    }
}

struct SidebarDragState {
    let row: Row
    let origin: CGPoint
    let originFrame: CGRect
    var position: CGPoint
    var active = false
    var folderHover = SidebarFolderHover()
    var sprungFolders: [(id: String, rows: [Row])] = []
}

struct SidebarFolderHover {
    private(set) var folder: String?
    private var started: TimeInterval?
    private(set) var attempt = 0

    mutating func aim(at folder: String?, now: TimeInterval) {
        guard folder != self.folder else { return }
        self.folder = folder
        started = folder == nil ? nil : now
        attempt += 1
    }

    mutating func ready(now: TimeInterval) -> String? {
        guard let started, now - started >= SidebarDragMetrics.folderHoverDelay else { return nil }
        self.started = nil
        return folder
    }
}

func sidebarSpringCandidate(drop: SidebarDrop, rows: [SidebarDragGeometry.Entry]) -> String? {
    guard case .folder(let id) = drop, let row = rows.first(where: { $0.row.id == id })?.row,
          row.collapsed, row.folderHasTabs else { return nil }
    return id
}

func sidebarShouldRefold(want: CGFloat, last: CGFloat, landsInside: Bool) -> Bool {
    !landsInside && (want < -0.8 || want > last + 1.5)
}

func sidebarAimsIntoSprung(want: CGFloat, alreadyAimingInside: Bool) -> Bool {
    abs(want) <= (alreadyAimingInside ? 0.6 : 0.5)
}

func sidebarPreviewPinned(_ pinned: [Row], sprungFolders: [(id: String, rows: [Row])]) -> [Row] {
    var pinned = pinned
    for (id, children) in sprungFolders {
        guard let head = pinned.firstIndex(where: { $0.id == id }), pinned[head].collapsed else { continue }
        pinned[head].collapsed = false
        let depth = pinned[head].depth + 1
        let first = head + 1
        let end = pinned[first...].firstIndex { $0.depth < depth } ?? pinned.endIndex
        pinned.replaceSubrange(first..<end, with: children.map { row in
            var row = row
            row.depth += depth
            return row
        })
    }
    return pinned
}

struct SidebarDragGeometry {
    struct Entry { let row: Row; var frame: CGRect }
    let bounds: CGRect
    let list: CGRect
    let pinnedArea: CGRect
    let favorites: CGRect
    let rows: [Entry]
    let dock: [(space: SpaceSnapshot, frame: CGRect)]
    let space: SpaceSnapshot

    func isWithin(_ id: String, folder: String) -> Bool {
        var item = id
        while item != folder {
            guard let parent = space.pinned.first(where: { $0.id == item })?.parentId else { return false }
            item = parent
        }
        return true
    }
}

enum SidebarDrop: Equatable {
    case refused
    case insert(container: String, index: Int, lineY: CGFloat, depth: UInt32)
    case folder(String)
    case favorites(container: String, index: Int)
    case dock(space: String, container: String, index: Int)
    // U25d: over one half of the page, which makes a split with the tab it was over.
    case split(SplitSide)

    var move: (container: String, index: Int)? {
        switch self {
        case let .insert(container, index, _, _), let .dock(_, container, index): (container, index)
        case let .favorites(container, index): (container, index)
        case let .folder(id): (id, 0)
        case .refused, .split: nil
        }
    }

    var folder: String? {
        if case .folder(let id) = self { return id }
        return nil
    }

    func haptic(from previous: SidebarDrop, today: String) -> NSHapticFeedbackManager.FeedbackPattern? {
        guard let move, let old = previous.move else { return nil }
        if (folder != nil) != (previous.folder != nil) || (move.container == today) != (old.container == today) {
            return .levelChange
        }
        return move != old ? .alignment : nil
    }
}

func resolveSidebarDrop(position: CGPoint, geometry g: SidebarDragGeometry, dragged: Row) -> SidebarDrop {
    guard g.bounds.contains(position) else { return .refused }
    let all = g.space.favorites + g.space.pinned + g.space.today
    let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    func descendant(_ id: String, of ancestor: String) -> Bool {
        var parent: String? = id
        var visited = Set<String>()
        while let id = parent, visited.insert(id).inserted {
            if id == ancestor { return true }
            parent = byID[id]?.parentId
        }
        return false
    }
    func insertion(_ container: String, index: Int, lineY: CGFloat) -> SidebarDrop {
        guard lineY >= g.list.minY, lineY <= g.list.maxY, !container.isEmpty, !descendant(container, of: dragged.id) else { return .refused }
        let inToday = container == g.space.todayId || descendant(container, of: g.space.todayId)
        if dragged.kind == .folder && inToday { return .refused }
        if let parent = byID[container], parent.kind != .folder { return .refused }
        let depth = container == g.space.pinnedId || container == g.space.todayId ? UInt32(0) : (byID[container]?.depth ?? 0) + 1
        let adjusted = index - (dragged.parentId == container && Int(dragged.siblingIndex) < index ? 1 : 0)
        return .insert(container: container, index: max(0, adjusted), lineY: lineY, depth: depth)
    }
    if let cell = g.dock.first(where: { $0.frame.contains(position) }) {
        guard cell.space.profileKey == g.space.profileKey else { return .refused }
        if g.space.favorites.contains(where: { $0.id == dragged.id }) {
            guard let container = cell.space.favoritesId else { return .refused }
            let index = cell.space.favorites.filter { $0.id != dragged.id }.count
            return .dock(space: cell.space.id, container: container, index: index)
        }
        let cameFromToday = g.space.today.contains { $0.id == dragged.id }
        let container = cameFromToday && dragged.kind != .folder ? cell.space.todayId : cell.space.pinnedId
        guard !container.isEmpty else { return .refused }
        return .dock(space: cell.space.id, container: container,
                     index: max(0, Int(container == cell.space.todayId ? cell.space.todayCount : cell.space.pinnedCount) - (dragged.parentId == container ? 1 : 0)))
    }
    if g.favorites.contains(position) {
        guard dragged.kind == .tab, let container = g.space.favoritesId else { return .refused }
        let count = g.space.favorites.filter { $0.id != dragged.id }.count
        let columns = SidebarDragMetrics.favoriteColumns(width: g.favorites.width, slots: count + 1)
        let pitch = (g.favorites.width + 8) / CGFloat(columns)
        let column = min(columns - 1, max(0, Int((position.x - g.favorites.minX) / pitch)))
        let line = max(0, Int((position.y - g.favorites.minY) / 55))
        return .favorites(container: container, index: min(count, line * columns + column))
    }
    if g.pinnedArea.contains(position) {
        // A row dropped on the space name pins at the top of pinned, with or without pins; the
        // 2 pt line under the name is its indicator (no extra drop zone).
        return insertion(g.space.pinnedId, index: 0, lineY: max(g.list.minY, g.pinnedArea.maxY))
    }
    guard g.list.contains(position) else { return .refused }
    let entries = g.rows.sorted { $0.frame.minY < $1.frame.minY }
    func boundary(above: Row, next: Row?, lineY: CGFloat) -> SidebarDrop? {
        var candidates: [(container: String, index: Int, depth: UInt32)] = []
        var folder: Row?
        var ancestorID = above.parentId
        while let ending = byID[ancestorID], ending.kind == .folder, !ending.collapsed,
              entries.last(where: { descendant($0.row.id, of: ending.id) })?.row.id == above.id {
            // A marker under a closed folder ends that folder: there is nothing above to count.
            let index = above.kind == .noTabs ? 0 : (folder.map { Int($0.siblingIndex) + 1 } ?? Int(above.siblingIndex) + 1)
            candidates.append((container: ending.id, index: index, depth: ending.depth + 1))
            folder = ending
            ancestorID = ending.parentId
        }
        var inPinned = false
        var parentID: String? = above.parentId
        while let id = parentID {
            if id == g.space.pinnedId { inPinned = true; break }
            parentID = byID[id]?.parentId
        }
        if inPinned,
           next == nil || (next?.parentId == g.space.todayId && next?.siblingIndex == 0) {
            candidates.append((container: g.space.pinnedId, index: Int(g.space.pinnedCount), depth: 0))
        }
        guard let chosen = candidates.first(where: { SidebarDragMetrics.lineLeading + 16 * CGFloat($0.depth) <= position.x }) ?? candidates.last else { return nil }
        return insertion(chosen.container, index: chosen.index, lineY: lineY)
    }
    if let entry = entries.first(where: { $0.frame.contains(position) }), entry.row.kind == .noTabs {
        // F3: the empty folder's line is a drop target for that folder.
        guard !descendant(entry.row.parentId, of: dragged.id) else { return .refused }
        return .folder(entry.row.parentId)
    }
    if let entry = entries.first(where: { $0.frame.contains(position) }), entry.row.kind == .folder,
       position.y > entry.frame.minY + SidebarDragMetrics.rowBoundaryInset,
       position.y < entry.frame.maxY - SidebarDragMetrics.rowBoundaryInset {
        guard !descendant(entry.row.id, of: dragged.id),
              !descendant(entry.row.id, of: g.space.todayId) || dragged.kind != .folder else { return .refused }
        return .folder(entry.row.id)
    }
    if let entry = entries.first(where: { $0.frame.contains(position) }) {
        if position.y < entry.frame.midY {
            return insertion(entry.row.parentId, index: Int(entry.row.siblingIndex), lineY: entry.frame.minY)
        }
        if entry.row.kind == .folder && !entry.row.collapsed,
           entries.contains(where: { $0.row.parentId == entry.row.id }) {
            return insertion(entry.row.id, index: 0, lineY: entry.frame.maxY)
        }
        let end = entry.row.kind == .folder
            ? entries.filter { descendant($0.row.id, of: entry.row.id) }.map(\.frame.maxY).max() ?? entry.frame.maxY
            : entry.frame.maxY
        if let index = entries.firstIndex(where: { $0.row.id == entry.row.id }),
           let drop = boundary(above: entry.row, next: index + 1 < entries.count ? entries[index + 1].row : nil, lineY: end) {
            return drop
        }
        return insertion(entry.row.parentId, index: Int(entry.row.siblingIndex) + 1, lineY: end)
    }
    if let next = entries.first(where: { position.y < $0.frame.minY }) {
        if next.row.parentId == g.space.todayId, next.row.siblingIndex == 0,
           let lastPin = entries.last(where: { g.space.pinned.contains($0.row) }),
           position.y <= (lastPin.frame.maxY + next.frame.minY) / 2 {
            if let drop = boundary(above: lastPin.row, next: next.row, lineY: lastPin.frame.maxY) { return drop }
            return insertion(g.space.pinnedId, index: Int(g.space.pinnedCount), lineY: lastPin.frame.maxY)
        }
        return insertion(next.row.parentId, index: Int(next.row.siblingIndex), lineY: next.frame.minY)
    }
    if let last = entries.last {
        if g.space.today.isEmpty {
            // T2: no 20 pt empty-Today zone; below the last row is Today itself.
            return insertion(g.space.todayId, index: 0, lineY: last.frame.maxY)
        }
        return insertion(g.space.todayId, index: Int(g.space.todayCount), lineY: last.frame.maxY)
    }
    return insertion(g.space.todayId, index: 0, lineY: g.list.minY)
}
