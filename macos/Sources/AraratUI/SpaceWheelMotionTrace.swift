import AppKit

@MainActor
final class SpaceWheelMotionTrace {
    static let enabled = CommandLine.arguments.contains("--ararat-trace-space-scroll")
        || CommandLine.arguments.contains("--ararat-screen=space-wheel-motion")

    var start: CFTimeInterval?
    var samples: [[String: Any]] = []
    var marks: [[String: Any]] = []
    var switches = 0
    var sampleCounts: [String: Int] = [:]
    var displayLink: CADisplayLink?
    private var animation: (from: Double, pitch: Double, time: Double)?
    private(set) var conditions: [String: Bool] = [:]

    struct Frame {
        let t: Double
        let offset: Double
    }

    static func conditions(frames: [Frame], from: Double, pitch: Double) -> [String: Bool] {
        let pairs = Array(zip(frames, frames.dropFirst()))
        return ["first_frame_full_offset": frames.first.map { abs($0.offset - from) <= abs(from) * 0.15 } ?? false,
                "monotone_approach": !frames.isEmpty && pairs.allSatisfy { abs($1.offset) <= abs($0.offset) + 2 },
                "no_late_jump": !frames.isEmpty && pairs.filter { $0.1.t >= 0.06 }
                    .allSatisfy { abs($1.offset - $0.offset) <= pitch * 0.25 },
                "landed": frames.last.map { abs($0.offset) <= 2 } ?? false]
    }

    func animationStarted(from: Double, pitch: Double, at time: Double) {
        guard let start else { return }
        animation = (from, pitch, time - start)
        mark("animation-start", detail: "from=\(from) pitch=\(pitch) jump_limit=\(pitch * 0.25)")
    }

    func begin(_ detail: String) {
        finish("interrupted-by-next-switch")
        switches += 1
        start = CACurrentMediaTime()
        samples = []
        marks = []
        animation = nil
        mark("switch", detail: detail)
    }

    func mark(_ name: String, detail: String = "") {
        guard let start else { return }
        marks.append(["t": CACurrentMediaTime() - start, "name": name, "detail": detail])
    }

    func sample(_ pages: [[String: Any]], source: String) {
        guard let start else { return }
        samples.append(["t": CACurrentMediaTime() - start, "source": source, "pages": pages])
        sampleCounts[source, default: 0] += 1
    }

    func finish(_ reason: String) {
        guard let start else { return }
        mark("trace-end", detail: reason)
        var verdict: [String: Bool] = [:]
        if let animation {
            let frames: [Frame] = samples.compactMap { sample in
                guard ["display-link", "check-timer"].contains(sample["source"] as? String ?? ""),
                      let t = sample["t"] as? Double, t >= animation.time,
                      let pages = sample["pages"] as? [[String: Any]],
                      let active = pages.first(where: { $0["active"] as? Bool == true && $0["animation"] as? Bool == true }),
                      let offset = active["offset"] as? Double else { return nil }
                return Frame(t: t - animation.time, offset: offset)
            }
            verdict = Self.conditions(frames: frames, from: animation.from, pitch: animation.pitch)
            conditions.merge(verdict) { $0 && $1 }
        }
        let value: [String: Any] = ["trace": "space-wheel-motion", "switch": switches, "conditions": verdict,
                                    "start": start, "samples": samples, "marks": marks]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            FileHandle.standardError.write(data)
            FileHandle.standardError.write(Data([10]))
        }
        self.start = nil
        displayLink?.invalidate()
        displayLink = nil
    }
}
