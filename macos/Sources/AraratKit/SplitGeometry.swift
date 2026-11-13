import Foundation

public struct SplitDivider: Equatable {
    public let split: String
    public let index: Int
    public let frame: CGRect
    public let horizontal: Bool
}

public struct SplitGeometry {
    public private(set) var panes: [String: CGRect] = [:]
    public private(set) var frames: [String: CGRect] = [:]
    public private(set) var dividers: [SplitDivider] = []
    private static let minimum: CGFloat = 240
    private static let gap: CGFloat = 10

    public init(root: SplitPane, bounds: CGRect) {
        layout(root, in: bounds)
    }

    private static func minimumSize(_ pane: SplitPane) -> CGSize {
        guard !pane.children.isEmpty else { return CGSize(width: minimum, height: minimum) }
        let sizes = pane.children.map(minimumSize)
        let gaps = gap * CGFloat(sizes.count - 1)
        switch pane.kind {
        case .splitHorizontal: return CGSize(width: sizes.reduce(gaps) { $0 + $1.width }, height: sizes.map(\.height).max() ?? minimum)
        case .splitVertical: return CGSize(width: sizes.map(\.width).max() ?? minimum, height: sizes.reduce(gaps) { $0 + $1.height })
        default: return CGSize(width: minimum, height: minimum)
        }
    }

    private mutating func layout(_ pane: SplitPane, in bounds: CGRect) {
        frames[pane.id] = bounds
        guard !pane.children.isEmpty, pane.kind == .splitHorizontal || pane.kind == .splitVertical else {
            panes[pane.id] = bounds
            return
        }
        let horizontal = pane.kind == .splitHorizontal
        let length = max(0, horizontal ? bounds.width : bounds.height)
        let gap = min(Self.gap, length / CGFloat(max(1, pane.children.count - 1)))
        let available = max(0, length - gap * CGFloat(pane.children.count - 1))
        let minimums = pane.children.map { child in
            let size = Self.minimumSize(child)
            return horizontal ? size.width : size.height
        }
        let weights = pane.children.map { CGFloat($0.factor.isFinite && $0.factor > 0 ? $0.factor : 1) }
        let minTotal = minimums.reduce(0, +)
        var lengths = [CGFloat](repeating: 0, count: weights.count)
        if minTotal >= available {
            for i in lengths.indices { lengths[i] = minTotal > 0 ? available * minimums[i] / minTotal : 0 }
        } else {
            var remaining = Set(lengths.indices)
            var space = available
            while !remaining.isEmpty {
                let total = remaining.reduce(CGFloat.zero) { $0 + weights[$1] }
                let constrained = remaining.filter { space * weights[$0] / total < minimums[$0] }
                if constrained.isEmpty {
                    for i in remaining { lengths[i] = space * weights[i] / total }
                    break
                }
                for i in constrained { lengths[i] = minimums[i]; space -= minimums[i]; remaining.remove(i) }
            }
        }
        // A vertical split's first pane sits at the top: the card is unflipped, so y grows upward
        // and the first child takes the band at maxY. Row order and screen order agree, so Move Up
        // moves a pane up and a drop on the top half inserts before the target.
        var position = horizontal ? bounds.minX : bounds.maxY
        for i in pane.children.indices {
            let frame = horizontal
                ? CGRect(x: position, y: bounds.minY, width: lengths[i], height: bounds.height)
                : CGRect(x: bounds.minX, y: position - lengths[i], width: bounds.width, height: lengths[i])
            layout(pane.children[i], in: frame)
            position += horizontal ? lengths[i] : -lengths[i]
            if i + 1 < pane.children.count {
                let frame = horizontal
                    ? CGRect(x: position, y: bounds.minY, width: gap, height: bounds.height)
                    : CGRect(x: bounds.minX, y: position - gap, width: bounds.width, height: gap)
                dividers.append(SplitDivider(split: pane.id, index: i, frame: frame, horizontal: horizontal))
                position += horizontal ? gap : -gap
            }
        }
    }

    public func factorsAfterDragging(root: SplitPane, split: String, index: Int, delta: CGFloat) -> [SplitFactor]? {
        func find(_ node: SplitPane) -> SplitPane? {
            if node.id == split { return node }
            for child in node.children { if let found = find(child) { return found } }
            return nil
        }
        guard let node = find(root), node.kind == .splitHorizontal || node.kind == .splitVertical,
              index >= 0, index + 1 < node.children.count, delta.isFinite else { return nil }
        let horizontal = node.kind == .splitHorizontal
        let lengths = node.children.compactMap { child -> CGFloat? in
            guard let frame = frames[child.id] else { return nil }
            return horizontal ? frame.width : frame.height
        }
        guard lengths.count == node.children.count else { return nil }
        let minimums = node.children.map { child in
            let size = Self.minimumSize(child)
            return horizontal ? size.width : size.height
        }
        let total = lengths.reduce(0, +)
        let minTotal = minimums.reduce(0, +)
        guard total > 0, minTotal > 0 else { return nil }
        let scale = min(1, total / minTotal)
        // A divider dragged up (a positive y delta) shrinks the pane above it, which is the first
        // child of a vertical split after the top-first layout.
        let moved = horizontal ? delta : -delta
        let bounded = max(minimums[index] * scale - lengths[index],
                          min(moved, lengths[index + 1] - minimums[index + 1] * scale))
        var adjusted = lengths
        adjusted[index] += bounded
        adjusted[index + 1] -= bounded
        return zip(node.children, adjusted).map { SplitFactor(id: $0.id, factor: Double(max($1 / total, .leastNonzeroMagnitude))) }
    }
}
