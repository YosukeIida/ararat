import Foundation

struct SpaceScrollEvent {
    enum Phase { case none, mayBegin, began, changed, ended, cancelled }
    enum Kind { case wheel, trackpad }
    var dx: Double
    var dy: Double = 0
    var phase: Phase = .none
    var momentum = false
    var inverted = false
    var time: TimeInterval
    var kind: Kind { phase == .none && !momentum ? .wheel : .trackpad }
}

@MainActor
struct SpaceScrollState {
    enum Action: Equatable {
        case vertical, ignored
        case follow(Double)
        case settle(index: Int, offset: Double, switched: Bool)
    }
    private enum Axis { case horizontal, vertical }
    private var axis: Axis?
    private var tracking = false
    private var ignoreMomentum = false
    private var ignoreUntilBegan = false
    private var rawOffset = 0.0
    private var motion: [(time: TimeInterval, delta: Double)] = []
    private var wheel: [(time: TimeInterval, delta: Double)] = []
    private var wheelPausedUntil = -Double.infinity

    mutating func handle(_ event: SpaceScrollEvent, index: Int, count: Int, pitch: Double, presentationOffset: Double = 0) -> Action {
        guard count > 0 else { return .vertical }
        if event.kind == .wheel {
            guard abs(event.dx) > abs(event.dy) else { return .vertical }
            guard index >= 0 && index < count else { return .ignored }
            guard event.time >= wheelPausedUntil else { return .ignored }
            wheel.removeAll { $0.time < event.time - SidebarMetrics.spaceWheelWindow }
            wheel.append((event.time, event.inverted ? -event.dx : event.dx))
            let delta = wheel.reduce(0) { $0 + $1.delta }
            guard abs(delta) > SidebarMetrics.spaceWheelThreshold else { return .ignored }
            wheel.removeAll()
            let target = index + (delta < 0 ? 1 : -1)
            guard (0..<count).contains(target) else { return .ignored }
            wheelPausedUntil = event.time + SidebarMetrics.spaceWheelPause
            tracking = false
            axis = nil
            ignoreMomentum = true
            return .settle(index: target, offset: presentationOffset, switched: true)
        }
        if event.momentum { return ignoreMomentum ? .ignored : .vertical }
        if event.phase == .began {
            tracking = true
            axis = nil
            ignoreMomentum = false
            ignoreUntilBegan = false
            rawOffset = 0
            motion.removeAll()
        }
        guard !ignoreUntilBegan else { return .ignored }
        guard tracking else { return .vertical }
        guard pitch > 0 else { return .ignored }
        if axis == nil && (event.dx != 0 || event.dy != 0) {
            axis = abs(event.dx) > abs(event.dy) ? .horizontal : .vertical
            let boundary = min(Double(index + 1) * pitch, max(-Double(count - index) * pitch, presentationOffset))
            let excess = presentationOffset - boundary
            rawOffset = boundary + excess / (SidebarMetrics.spaceRubberCoefficient * (1 - abs(excess) / SidebarMetrics.spaceRubberDistance))
        }
        let ending = event.phase == .ended || event.phase == .cancelled
        guard axis == .horizontal else {
            if ending { tracking = false; axis = nil }
            return .vertical
        }
        motion.removeAll { $0.time < event.time - SidebarMetrics.spaceVelocityWindow }
        rawOffset += event.dx * SidebarMetrics.spaceFollowFactor
        if event.dx != 0 { motion.append((event.time, event.dx)) }
        let firstOffset = Double(index + 1) * pitch
        let lastOffset = -Double(count - index) * pitch
        let boundary = min(firstOffset, max(lastOffset, rawOffset))
        let outside = rawOffset != boundary
        let offset = outside ? boundary + Self.rubberBand(rawOffset - boundary) : rawOffset
        guard ending else { return .follow(offset) }
        tracking = false
        axis = nil
        ignoreMomentum = true
        let velocity = motion.reduce(0) { $0 + $1.delta }
        var target = index
        if event.phase != .cancelled {
            if outside {
                target = rawOffset > firstOffset ? -1 : count
            } else if velocity != 0 {
                target = index + Int(velocity < 0 ? ceil(-rawOffset / pitch) : floor(-rawOffset / pitch))
            } else {
                let pages = Int(ceil(abs(rawOffset) / pitch - 0.5))
                target += rawOffset < 0 ? pages : -pages
            }
        }
        target = min(count, max(-1, target))
        return .settle(index: target, offset: offset, switched: target != index)
    }

    mutating func cancelGesture() {
        tracking = false
        axis = nil
        ignoreMomentum = true
        ignoreUntilBegan = true
        rawOffset = 0
        motion.removeAll()
    }

    static func rubberBand(_ offset: Double) -> Double {
        let distance = SidebarMetrics.spaceRubberDistance
        let result = distance * (1 - 1 / (SidebarMetrics.spaceRubberCoefficient * abs(offset) / distance + 1))
        return offset < 0 ? -result : result
    }
}
