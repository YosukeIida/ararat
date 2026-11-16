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

    func begin(_ detail: String) {
        finish("interrupted-by-next-switch")
        switches += 1
        start = CACurrentMediaTime()
        samples = []
        marks = []
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
        let value: [String: Any] = ["trace": "space-wheel-motion", "switch": switches,
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
