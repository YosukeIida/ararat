import AppKit
import AraratUI
import AraratKit

@MainActor
final class SpaceWheelMotionCheck {
    static let enabled = CommandLine.arguments.contains("--ararat-trace-space-scroll")
        || CommandLine.arguments.contains("--ararat-screen=space-wheel-motion")

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func recording(_ text: String) throws -> [Input] {
        let inputs = try Input.parse(text)
        guard let first = inputs.first, let last = inputs.last else { throw Failure(description: "recording_empty count=0") }
        guard inputs.count <= 10000 else { throw Failure(description: "recording_count value=\(inputs.count) limit=10000") }
        let span = last.time - first.time
        guard span <= 20 else { throw Failure(description: "recording_span_seconds value=\(span) limit=20") }
        guard zip(inputs, inputs.dropFirst()).allSatisfy({ $0.time <= $1.time }) else {
            throw Failure(description: "recording_order times=\(inputs.map(\.time))")
        }
        return inputs
    }

    static func seed(_ session: WorkspaceSession, windowID: String) throws -> WorkspaceSnapshot {
        try session.queue.sync {
            guard let store = session.store else { throw Failure(description: "seed_store missing") }
            var snapshot = store.snapshot(windowId: windowID)
            while snapshot.spaces.count < 6 {
                let id = "wheel-\(UUID().uuidString)"
                snapshot = try store.createSpace(windowId: windowID, name: "Wheel \(snapshot.spaces.count + 1)", spaceId: id)
            }
            guard snapshot.spaces.count >= 6 else { throw Failure(description: "seed_spaces count=\(snapshot.spaces.count) minimum=6") }
            return snapshot
        }
    }

    struct Input {
        let time: Double
        let fields: [CGEventField: Double]

        static func parse(_ text: String) throws -> [Input] {
            try text.split(separator: "\n").enumerated().map { lineIndex, line in
                let tokens = line.split(separator: " ")
                guard let first = tokens.first, let stamp = Double(first), stamp.isFinite, stamp >= 0 else {
                    throw Failure(description: "recording_timestamp line=\(lineIndex + 1) value=\(tokens.first.map(String.init) ?? "missing")")
                }
                var values: [String: String] = [:]
                for token in tokens.dropFirst() {
                    let pair = token.split(separator: "=", maxSplits: 1)
                    guard pair.count == 2, values[String(pair[0])] == nil else { throw Failure(description: "recording_field line=\(lineIndex + 1) token=\(token)") }
                    values[String(pair[0])] = String(pair[1])
                }
                var fields: [CGEventField: Double] = [:]
                for (key, axes) in [("line", [CGEventField.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2]),
                                    ("pt", [.scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2]),
                                    ("fix", [.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2])] {
                    let pair = (values[key] ?? "").split(separator: ",")
                    guard pair.count == 2 else { throw Failure(description: "recording_pair line=\(lineIndex + 1) field=\(key) value=\(values[key] ?? "missing")") }
                    for (axis, text) in zip(axes, pair) {
                        guard let value = Double(text), value.isFinite, abs(value) <= 32767 else { throw Failure(description: "recording_delta line=\(lineIndex + 1) field=\(key) value=\(text)") }
                        fields[axis] = value
                    }
                }
                for (key, field) in [("cont", CGEventField.scrollWheelEventIsContinuous),
                                     ("phase", .scrollWheelEventScrollPhase), ("mom", .scrollWheelEventMomentumPhase),
                                     ("inv", CGEventField(rawValue: 137)!)] {
                    guard let value = Int(values[key] ?? ""), (0...255).contains(value) else { throw Failure(description: "recording_flag line=\(lineIndex + 1) field=\(key) value=\(values[key] ?? "missing")") }
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
    var replayScheduled = false
    var timer: Timer?
    var capture: SpaceWheelDrawnCapture?
    var finishing = false
    var switches: [SpaceWheelDrawnCapture.Switch] = []
    var captureError: String?
    private var captureStage = "not_started"
    private var captureTimeout = false

    private enum CaptureOutcome {
        case finished(String?)
        case timedOut
    }

    var diagnostics: [String: Any] {
        ["capture_stage": captureStage, "capture_timeout": captureTimeout,
         "replay_scheduled": replayScheduled, "events_sent": sent, "events_expected": expected, "replay_done": done]
    }

    func prepareCapture(timeout: Duration = .seconds(4), _ operation: @escaping @MainActor () async throws -> Void) async {
        await captureWithinDeadline(stage: "start", timeout: timeout) {
            defer {
                if Task.isCancelled, let capture = self.capture {
                    Task { await capture.stop() }
                }
            }
            try await operation()
        }
    }

    func finish(presentation: [String: Bool], timeout: Duration = .seconds(1),
                stopCapture: @escaping @MainActor () async -> Void,
                drawnReport: () -> [String: Any]) async -> (ok: Bool, values: [String: Any]) {
        var verdict = result(presentation: presentation, drawnReport: [:])
        if !captureTimeout { await captureWithinDeadline(stage: "stop", timeout: timeout, operation: stopCapture) }
        verdict.values["capture_stage"] = captureStage
        verdict.values["capture_timeout"] = captureTimeout
        verdict.values["drawn_report_only"] = captureTimeout ? NSNull() : drawnReport()
        return verdict
    }

    private func captureWithinDeadline(stage: String, timeout: Duration,
                                       operation: @escaping @MainActor () async throws -> Void) async {
        captureStage = stage
        let deadline = ContinuousClock.now + timeout
        let (outcomes, output) = AsyncStream<CaptureOutcome>.makeStream(bufferingPolicy: .bufferingOldest(1))
        // Why not a task group: leaving it would still wait for an unresponsive capture.
        let capture = Task { @MainActor in
            do {
                try await operation()
                output.yield(.finished(nil))
            } catch {
                output.yield(.finished(String(describing: error)))
            }
        }
        let timer = Task { @MainActor in
            do { try await ContinuousClock().sleep(until: deadline) }
            catch { return }
            output.yield(.timedOut)
        }
        var pending = outcomes.makeAsyncIterator()
        switch await pending.next() {
        case .finished(let error):
            if let error { captureError = error }
        case .timedOut:
            captureTimeout = true
        case nil:
            break
        }
        output.finish()
        capture.cancel()
        timer.cancel()
    }

    func result(presentation: [String: Bool], drawnReport: [String: Any]) -> (ok: Bool, values: [String: Any]) {
        var conditions = Dictionary(uniqueKeysWithValues:
            ["first_frame_full_offset", "monotone_approach", "no_late_jump", "landed"].map { ($0, presentation[$0] ?? false) })
        conditions["events_sent"] = !failed && sent == expected
        conditions["space_switched"] = !switches.isEmpty
        return (conditions.values.allSatisfy { $0 }, ["check": "space-wheel-motion", "conditions": conditions,
            "failed_conditions": conditions.filter { !$0.value }.keys.sorted(),
            "events_sent": sent, "input_failed": failed, "switches": switches.count,
            "drawn_report_only": drawnReport, "motion_trace": "stderr JSON lines"])
    }
}

extension Runtime {
    private func requireWheelSession() throws -> WorkspaceSession {
        guard let session = adapter?.session else { throw SpaceWheelMotionCheck.Failure(description: "seed_session missing") }
        return session
    }

    func spaceWheelMotionTick() {
        guard let sidebar else { return }
        if let check = spaceWheelMotionCheck {
            guard check.done, !check.finishing else { return }
            check.finishing = true
            check.timer?.invalidate()
            sidebar.checkFinishSpaceWheelMotion()
            let counts = sidebar.checkSpaceWheelMotionCounts
            let presentation = sidebar.checkSpaceWheelMotionConditions
            Task { @MainActor [self, sidebar, check] in
                let result = await check.finish(presentation: presentation, stopCapture: {
                    await check.capture?.stop()
                }, drawnReport: {
                    let drawn = SpaceWheelDrawnCapture.report(check.capture?.samples() ?? [], switches: check.switches)
                    var report = check.capture?.diagnostics(source: check.switches.first?.source ?? sidebar.spaceShown,
                        pitch: Int(sidebar.bounds.width), directory: SpaceWheelDrawnCapture.resultDirectory()) ?? [:]
                    report["conditions"] = drawn.conditions
                    report["switches"] = drawn.switches
                    report["capture_error"] = check.captureError as Any? ?? NSNull()
                    report["drawn_marker"] = sidebar.checkSpaceWheelDrawnDiagnostics
                    return report
                })
                var values = result.values
                values["samples"] = counts
                finishBrowserCheck(ok: result.ok, values: values)
            }
            return
        }
        do {
            guard let path = CommandLine.arguments.first(where: { $0.hasPrefix("--ararat-wheel-recording=") })
                .map({ String($0.dropFirst("--ararat-wheel-recording=".count)) }) else {
                throw SpaceWheelMotionCheck.Failure(description: "recording_path missing --ararat-wheel-recording")
            }
            let inputs = try SpaceWheelMotionCheck.recording(String(contentsOfFile: path, encoding: .utf8))
            let seeded = try SpaceWheelMotionCheck.seed(try requireWheelSession(), windowID: windowID)
            show(seeded)
            guard let first = inputs.first, let last = inputs.last else { throw SpaceWheelMotionCheck.Failure(description: "recording_empty count=0") }
            let check = SpaceWheelMotionCheck()
            check.expected = inputs.count
            spaceWheelMotionCheck = check
            sidebar.spaceScrollDirection = .natural
            sidebar.showSpace(at: min(4, snapshot.spaces.count - 2))
            Task { @MainActor [self, sidebar, check] in
                await check.prepareCapture {
                    sidebar.layoutSubtreeIfNeeded()
                    let rect = sidebar.checkSpaceWheelDrawnRect
                    guard let window = sidebar.window, rect.width > 0, rect.height > 0 else {
                        throw SpaceWheelMotionCheck.Failure(description: "drawn_capture_rect value=\(rect)")
                    }
                    let capture = SpaceWheelDrawnCapture(width: Int(rect.width), filter: try SpaceWheelDrawnCapture.Filter.selected(arguments: CommandLine.arguments))
                    check.capture = capture
                    try await capture.start(window: window, row: rect)
                    for _ in 0..<100 {
                        if let frame = capture.samples().last,
                           SpaceWheelDrawnPattern.offset(pixels: frame.pixels, source: sidebar.spaceShown,
                               target: sidebar.spaceShown, pitch: Int(sidebar.bounds.width)) != nil { break }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    guard let baseline = capture.samples().last,
                          SpaceWheelDrawnPattern.offset(pixels: baseline.pixels, source: sidebar.spaceShown,
                              target: sidebar.spaceShown, pitch: Int(sidebar.bounds.width)) != nil else {
                        throw SpaceWheelMotionCheck.Failure(description: "drawn_pattern_baseline source=\(sidebar.spaceShown) width=\(capture.width)")
                    }
                }
                check.replayScheduled = true
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
                        let source = sidebar.spaceShown
                        let received = SpaceWheelDrawnCapture.hostTime()
                        sidebar.scrollWheel(with: event)
                        if sidebar.spaceShown != source {
                            check.switches.append(.init(time: received, source: source, target: sidebar.spaceShown, pitch: Int(sidebar.bounds.width)))
                        }
                        check.sent += 1
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2 + last.time - first.time) { [weak check] in check?.done = true }
            }
        } catch {
            finishBrowserCheck(ok: false, values: ["check": "space-wheel-motion", "error": "wheel recording: \(error)"])
        }
    }
}
