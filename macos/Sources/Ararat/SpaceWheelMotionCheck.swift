import AppKit
import AraratUI

@MainActor
final class SpaceWheelMotionCheck {
    static let enabled = CommandLine.arguments.contains("--ararat-trace-space-scroll")
        || CommandLine.arguments.contains("--ararat-screen=space-wheel-motion")

    struct Input {
        let time: Double
        let fields: [CGEventField: Double]

        static func parse(_ text: String) throws -> [Input] {
            try text.split(separator: "\n").map { line in
                let tokens = line.split(separator: " ")
                guard let first = tokens.first, let stamp = Double(first), stamp.isFinite, stamp >= 0 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                var values: [String: String] = [:]
                for token in tokens.dropFirst() {
                    let pair = token.split(separator: "=", maxSplits: 1)
                    guard pair.count == 2, values[String(pair[0])] == nil else { throw CocoaError(.fileReadCorruptFile) }
                    values[String(pair[0])] = String(pair[1])
                }
                var fields: [CGEventField: Double] = [:]
                for (key, axes) in [("line", [CGEventField.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2]),
                                    ("pt", [.scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2]),
                                    ("fix", [.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2])] {
                    let pair = (values[key] ?? "").split(separator: ",")
                    guard pair.count == 2 else { throw CocoaError(.fileReadCorruptFile) }
                    for (axis, text) in zip(axes, pair) {
                        guard let value = Double(text), value.isFinite, abs(value) <= 32767 else { throw CocoaError(.fileReadCorruptFile) }
                        fields[axis] = value
                    }
                }
                for (key, field) in [("cont", CGEventField.scrollWheelEventIsContinuous),
                                     ("phase", .scrollWheelEventScrollPhase), ("mom", .scrollWheelEventMomentumPhase),
                                     ("inv", CGEventField(rawValue: 137)!)] {
                    guard let value = Int(values[key] ?? ""), (0...255).contains(value) else { throw CocoaError(.fileReadCorruptFile) }
                    fields[field] = Double(value)
                }
                return Input(time: stamp / 1000, fields: fields)
            }
        }

        func event(at time: Double) -> NSEvent? {
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
                                      wheel1: 0, wheel2: 0, wheel3: 0) else { return nil }
            // Why this order: writing line deltas after point/fixed deltas recalculates them.
            for field in [CGEventField.scrollWheelEventIsContinuous, .scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2,
                          .scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2,
                          .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2,
                          .scrollWheelEventScrollPhase, .scrollWheelEventMomentumPhase, CGEventField(rawValue: 137)!] {
                event.setDoubleValueField(field, value: fields[field] ?? 0)
            }
            event.timestamp = UInt64(time * 1_000_000_000)
            return NSEvent(cgEvent: event)
        }
    }

    var sent = 0
    var expected = 0
    var failed = false
    var done = false
    var timer: Timer?
}

extension Runtime {
    func spaceWheelMotionTick() {
        guard let sidebar else { return }
        if let check = spaceWheelMotionCheck {
            guard check.done else { return }
            check.timer?.invalidate()
            sidebar.checkFinishSpaceWheelMotion()
            let counts = sidebar.checkSpaceWheelMotionCounts
            finishBrowserCheck(ok: !check.failed && check.sent == check.expected && (counts["switches"] ?? 0) > 0
                && (counts["check-timer"] ?? 0) > 0, values: ["check": "space-wheel-motion", "samples": counts,
                "events_sent": check.sent, "input_failed": check.failed, "motion_trace": "stderr JSON lines",
                "curve_verdict": "diagnostic-only"])
            return
        }
        do {
            guard let path = CommandLine.arguments.first(where: { $0.hasPrefix("--ararat-wheel-recording=") })
                .map({ String($0.dropFirst("--ararat-wheel-recording=".count)) }) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let inputs = try SpaceWheelMotionCheck.Input.parse(String(contentsOfFile: path, encoding: .utf8))
            guard let first = inputs.first, let last = inputs.last, inputs.count <= 10000,
                  last.time - first.time <= 20,
                  zip(inputs, inputs.dropFirst()).allSatisfy({ $0.time <= $1.time }), snapshot.spaces.count >= 3 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let check = SpaceWheelMotionCheck()
            check.expected = inputs.count
            spaceWheelMotionCheck = check
            sidebar.spaceScrollDirection = .natural
            sidebar.showSpace(at: min(4, snapshot.spaces.count - 2))
            let timer = Timer(timeInterval: 1 / 120, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sidebar?.checkSampleSpaceWheelMotion() }
            }
            check.timer = timer
            RunLoop.main.add(timer, forMode: .common)
            let start = ProcessInfo.processInfo.systemUptime + 0.2
            for input in inputs {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2 + input.time - first.time) { [weak sidebar, weak check] in
                    guard let sidebar, let check else { return }
                    let now = ProcessInfo.processInfo.systemUptime
                    guard let event = input.event(at: start + input.time - first.time) else { check.failed = true; return }
                    sidebar.traceSpaceWheelMotion("replay", detail: "recorded=\(input.time) scheduled=\(start + input.time - first.time) actual=\(now)")
                    sidebar.scrollWheel(with: event)
                    check.sent += 1
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2 + last.time - first.time) { [weak check] in check?.done = true }
        } catch {
            finishBrowserCheck(ok: false, values: ["check": "space-wheel-motion", "error": "wheel recording: \(error)"])
        }
    }
}
