import Darwin
import Foundation

final class RelaunchTrace {
  let reader = DispatchGroup()
  private let lock = NSLock()
  private var tail = Data()
  private var pending = Data()
  private var trace: String?

  func append(_ data: Data) {
    lock.lock(); defer { lock.unlock() }
    tail.append(data)
    if tail.count > 4096 { tail.removeFirst(tail.count - 4096) }
    pending.append(data)
    while let end = pending.firstIndex(of: 10) {
      let line = String(decoding: pending[..<end], as: UTF8.self)
      if line.hasPrefix("ararat-trace:") { trace = line }
      pending.removeSubrange(...end)
    }
    if pending.count > 4096 { pending.removeFirst(pending.count - 4096) }
  }

  func snapshot() -> (String, String?) {
    lock.lock(); defer { lock.unlock() }
    return (String(decoding: tail, as: UTF8.self), trace)
  }
}

private struct RelaunchChild {
  let pid: pid_t
  let output: Int32
}

private func launchRelaunchChild(_ arguments: [String], processGroup: Bool = false, trace: RelaunchTrace? = nil) throws -> RelaunchChild {
  var descriptors: [Int32] = [0, 0]
  guard pipe(&descriptors) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
  var errors: [Int32] = [-1, -1]
  if trace != nil && pipe(&errors) != 0 {
    let code = errno
    close(descriptors[0]); close(descriptors[1])
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
  }
  defer { if errors[0] >= 0 { close(errors[0]) }; if errors[1] >= 0 { close(errors[1]) } }
  var actions: posix_spawn_file_actions_t?
  posix_spawn_file_actions_init(&actions)
  defer { posix_spawn_file_actions_destroy(&actions) }
  posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO)
  posix_spawn_file_actions_addclose(&actions, descriptors[0])
  posix_spawn_file_actions_addclose(&actions, descriptors[1])
  if trace != nil {
    posix_spawn_file_actions_adddup2(&actions, errors[1], STDERR_FILENO)
    posix_spawn_file_actions_addclose(&actions, errors[0])
    posix_spawn_file_actions_addclose(&actions, errors[1])
  }
  guard let executable = Bundle.main.executablePath else {
    close(descriptors[0]); close(descriptors[1])
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
  }
  var attributes: posix_spawnattr_t?
  let initResult = posix_spawnattr_init(&attributes)
  guard initResult == 0 else {
    close(descriptors[0]); close(descriptors[1])
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(initResult))
  }
  defer { posix_spawnattr_destroy(&attributes) }
  if processGroup {
    let groupResult = posix_spawnattr_setpgroup(&attributes, 0)
    let flagsResult = groupResult == 0 ? posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) : groupResult
    guard flagsResult == 0 else {
      close(descriptors[0]); close(descriptors[1])
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(flagsResult))
    }
  }
  let strings = ([executable] + arguments).map { strdup($0) }
  defer { strings.forEach { free($0) } }
  var argv = strings + [nil]
  var pid: pid_t = 0
  let result = posix_spawn(&pid, executable, &actions, &attributes, &argv, environ)
  close(descriptors[1])
  guard result == 0 else {
    close(descriptors[0])
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(result))
  }
  if let trace {
    let descriptor = errors[0]
    errors[0] = -1
    trace.reader.enter()
    DispatchQueue.global().async {
      defer { trace.reader.leave() }
      var buffer = [UInt8](repeating: 0, count: 4096)
      while true {
        let count = read(descriptor, &buffer, buffer.count)
        if count < 0 && errno == EINTR { continue }
        if count <= 0 { break }
        let data = Data(buffer.prefix(count))
        trace.append(data)
        FileHandle.standardError.write(data)
      }
      close(descriptor)
    }
  }
  return RelaunchChild(pid: pid, output: descriptors[0])
}

private func readRelaunchLine(_ descriptor: Int32, seconds: TimeInterval) -> String? {
  let deadline = Date().addingTimeInterval(seconds)
  var bytes: [UInt8] = []
  while Date() < deadline && bytes.count < 65536 {
    var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
    let milliseconds = max(1, Int32(deadline.timeIntervalSinceNow * 1000))
    let ready = poll(&event, 1, milliseconds)
    if ready < 0 && errno == EINTR { continue }
    guard ready > 0 else { return nil }
    var byte: UInt8 = 0
    let count = read(descriptor, &byte, 1)
    if count < 0 && errno == EINTR { continue }
    guard count == 1 else { return nil }
    if byte == 10 { return String(bytes: bytes, encoding: .utf8) }
    bytes.append(byte)
  }
  return nil
}

private func reapRelaunchChild(_ pid: pid_t, seconds: TimeInterval) -> Int32? {
  let deadline = Date().addingTimeInterval(seconds)
  var status: Int32 = 0
  while Date() < deadline {
    let result = waitpid(pid, &status, WNOHANG)
    if result == pid { return status }
    if result < 0 && errno != EINTR { return nil }
    usleep(20_000)
  }
  return nil
}

func runRelaunchDriver(_ mode: String) -> Int32 {
  var child: RelaunchChild?
  var group: pid_t?
  var root: URL?
  let trace = RelaunchTrace()
  var firstStatus: Int32?
  var firstPID: pid_t?
  defer {
    if let group { kill(-group, SIGKILL) }
    if let child {
      kill(child.pid, SIGKILL)
      close(child.output)
    }
  }
  func cleanup() -> String? {
    if let group { kill(-group, SIGKILL) }
    if let current = child {
      kill(current.pid, SIGKILL)
      guard let status = reapRelaunchChild(current.pid, seconds: 30) else {
        close(current.output); child = nil
        return "child could not be reaped; scratch directory kept at \(root?.path ?? "unknown")"
      }
      if current.pid == firstPID { firstStatus = status }
      close(current.output); child = nil
    }
    if let current = group {
      let deadline = Date().addingTimeInterval(30)
      while kill(-current, 0) == 0 || errno == EPERM {
        if Date() >= deadline { return "process group still alive; scratch directory kept at \(root?.path ?? "unknown")" }
        usleep(20_000)
      }
      guard errno == ESRCH else { return "cannot check process group; scratch directory kept at \(root?.path ?? "unknown")" }
      group = nil
    }
    if let current = root {
      do { try FileManager.default.removeItem(at: current); root = nil }
      catch { return "cannot remove scratch directory at \(current.path): \(error)" }
    }
    return nil
  }
  func failure(_ message: String) -> Int32 {
    let detail = cleanup().map { "\(message); \($0)" } ?? message
    _ = trace.reader.wait(timeout: .now() + 2)
    let (tail, lastTrace) = trace.snapshot()
    let status: [String: Any] = firstStatus.map { ($0 & 0x7f) == 0 ? ["exit_status": Int(($0 >> 8) & 0xff)] : ["signal": Int($0 & 0x7f)] } ?? [:]
    let result: [String: Any] = ["check": mode == "pins" ? "relaunch-pins" : mode, "ok": false, "error": detail, "exit": 1,
                                 "run1_stderr_tail": tail, "run1_last_trace": lastTrace as Any? ?? NSNull(),
                                 "run1_status": status.isEmpty ? NSNull() : status as Any]
    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
       let line = String(data: data, encoding: .utf8) { print(line); fflush(stdout) }
    return 1
  }
  guard let temp = ProcessInfo.processInfo.environment["TMPDIR"], !temp.isEmpty else { return failure("TMPDIR missing") }
  let scratch = URL(fileURLWithPath: temp, isDirectory: true).appendingPathComponent("ararat-relaunch-\(UUID().uuidString)", isDirectory: true)
  do {
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
    root = scratch
    let forwarded = CommandLine.arguments.filter { $0.hasPrefix("--load-extension=") }
    let common = ["--user-data-dir=\(scratch.appendingPathComponent("profile").path)", "--ararat-db=\(scratch.appendingPathComponent("workspace.sqlite").path)", "--use-mock-keychain"] + forwarded
    let first = try launchRelaunchChild(common + ["--ararat-check=relaunch-seed", "--ararat-relaunch-mode=\(mode)"], processGroup: true, trace: trace)
    firstPID = first.pid
    child = first
    group = first.pid
    guard let ready = readRelaunchLine(first.output, seconds: 60),
          let bytes = ready.data(using: .utf8),
          let json = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
          json["ready"] as? Bool == true else { return failure("run 1 did not become ready") }
    if mode == "crash" && kill(-first.pid, SIGKILL) != 0 { return failure("cannot kill run 1") }
    guard let status = reapRelaunchChild(first.pid, seconds: 30) else { return failure("run 1 did not exit") }
    firstStatus = status
    close(first.output)
    child = nil
    if mode != "crash" && status != 0 { return failure("run 1 did not quit cleanly") }
    if mode == "crash" && (status & 0x7f) != SIGKILL { return failure("run 1 was not killed") }
    kill(-first.pid, SIGKILL)
    let deadline = Date().addingTimeInterval(30)
    while kill(-first.pid, 0) == 0 || errno == EPERM {
      if Date() >= deadline { return failure("run 1 process group did not exit") }
      usleep(20_000)
    }
    guard errno == ESRCH else { return failure("cannot check run 1 process group") }
    group = nil
    let second = try launchRelaunchChild(common + ["--ararat-check=relaunch-verify", "--ararat-relaunch-expected=\(bytes.base64EncodedString())", "--ararat-relaunch-mode=\(mode)"] + (mode == "pins" ? ["--profile-directory=Default"] : []))
    child = second
    guard let line = readRelaunchLine(second.output, seconds: 60),
          let result = line.data(using: .utf8),
          let object = try JSONSerialization.jsonObject(with: result) as? [String: Any],
          let ok = object["ok"] as? Bool,
          let status = reapRelaunchChild(second.pid, seconds: 30) else { return failure("run 2 did not finish") }
    close(second.output)
    child = nil
    if mode == "pins" {
      // A second profile in the same store must not inherit the Default profile's pin.
      let third = try launchRelaunchChild(common + ["--ararat-check=relaunch-verify", "--ararat-relaunch-expected=\(bytes.base64EncodedString())", "--ararat-relaunch-mode=pins-isolated", "--profile-directory=Profile 1"])
      child = third
      guard let thirdLine = readRelaunchLine(third.output, seconds: 60),
            let thirdResult = thirdLine.data(using: .utf8),
            let thirdObject = try JSONSerialization.jsonObject(with: thirdResult) as? [String: Any],
            let isolated = thirdObject["ok"] as? Bool,
            let thirdStatus = reapRelaunchChild(third.pid, seconds: 30) else { return failure("run 3 did not finish") }
      close(third.output)
      child = nil
      if let error = cleanup() { return failure(error) }
      let verified = thirdObject["profile_isolation_verified"] as? Bool ?? false
      let combined: [String: Any] = ["check": "relaunch-pins", "ok": ok && status == 0 && isolated && thirdStatus == 0,
                                     "pinned_after_relaunch": ok, "other_profile_run_ok": isolated,
                                     "profile_isolation_verified": verified,
                                     "run2": object, "run3": thirdObject]
      if let data = try? JSONSerialization.data(withJSONObject: combined, options: [.sortedKeys]),
         let output = String(data: data, encoding: .utf8) { print(output); fflush(stdout) }
      return (ok && status == 0 && isolated && thirdStatus == 0) ? 0 : 1
    }
    if let error = cleanup() { return failure(error) }
    print(line); fflush(stdout)
    return ok && status == 0 ? 0 : 1
  } catch { return failure(String(describing: error)) }
}

private func searchPrivateScratch(_ root: URL, needles: [String]) -> [String: Any] {
  let manager = FileManager.default
  let database = root.appendingPathComponent("workspace.sqlite")
  var files: [String] = []
  var hits: [String] = []
  func search(_ url: URL) -> Bool {
    guard let attributes = try? manager.attributesOfItem(atPath: url.path),
          let size = attributes[.size] as? NSNumber, size.int64Value <= 64 * 1024 * 1024,
          let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return false }
    return needles.contains { needle in data.range(of: Data(needle.utf8)) != nil }
  }
  for suffix in ["", "-wal", "-shm"] {
    let url = URL(fileURLWithPath: database.path + suffix)
    guard manager.fileExists(atPath: url.path) else { continue }
    files.append(url.lastPathComponent)
    if search(url) { hits.append(url.lastPathComponent) }
  }
  let profile = root.appendingPathComponent("profile")
  if let enumerator = manager.enumerator(atPath: profile.path) {
    while let entry = enumerator.nextObject() as? String {
      let url = profile.appendingPathComponent(entry)
      var isDirectory: ObjCBool = false
      guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
      files.append(entry)
      if search(url) { hits.append(entry) }
    }
  }
  return ["files": files.count, "hits": hits]
}

func runPrivateDurabilityDriver() -> Int32 {
  var child: RelaunchChild?
  var group: pid_t?
  var root: URL?
  let trace = RelaunchTrace()
  var firstStatus: Int32?
  var firstPID: pid_t?
  defer {
    if let group { kill(-group, SIGKILL) }
    if let child { kill(child.pid, SIGKILL); close(child.output) }
  }
  func cleanup() -> String? {
    if let group { kill(-group, SIGKILL) }
    if let current = child {
      kill(current.pid, SIGKILL)
      guard let status = reapRelaunchChild(current.pid, seconds: 30) else {
        close(current.output); child = nil
        return "child could not be reaped; scratch kept at \(root?.path ?? "unknown")"
      }
      if current.pid == firstPID { firstStatus = status }
      close(current.output); child = nil
    }
    if let current = group {
      let deadline = Date().addingTimeInterval(30)
      while kill(-current, 0) == 0 || errno == EPERM {
        if Date() >= deadline { return "process group still alive; scratch kept at \(root?.path ?? "unknown")" }
        usleep(20_000)
      }
      group = nil
    }
    if let current = root {
      do { try FileManager.default.removeItem(at: current); root = nil }
      catch { return "cannot remove scratch at \(current.path): \(error)" }
    }
    return nil
  }
  func failure(_ message: String) -> Int32 {
    let detail = cleanup().map { "\(message); \($0)" } ?? message
    _ = trace.reader.wait(timeout: .now() + 2)
    let (tail, lastTrace) = trace.snapshot()
    let result: [String: Any] = ["check": "private-durability", "ok": false, "error": detail, "exit": 1,
                                 "run1_stderr_tail": tail, "run1_last_trace": lastTrace as Any? ?? NSNull()]
    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
       let line = String(data: data, encoding: .utf8) { print(line); fflush(stdout) }
    return 1
  }
  guard let temp = ProcessInfo.processInfo.environment["TMPDIR"], !temp.isEmpty else { return failure("TMPDIR missing") }
  let scratch = URL(fileURLWithPath: temp, isDirectory: true).appendingPathComponent("ararat-private-durability-\(UUID().uuidString)", isDirectory: true)
  do {
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
    root = scratch
    let forwarded = CommandLine.arguments.filter { $0.hasPrefix("--load-extension=") }
    func common(_ round: URL) -> [String] {
      ["--user-data-dir=\(round.appendingPathComponent("profile").path)",
       "--ararat-db=\(round.appendingPathComponent("workspace.sqlite").path)",
       "--use-mock-keychain"] + forwarded
    }
    let clean = scratch.appendingPathComponent("clean", isDirectory: true)
    let crash = scratch.appendingPathComponent("crash", isDirectory: true)
    try FileManager.default.createDirectory(at: clean, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: crash, withIntermediateDirectories: false)
    func seed(_ mode: String, round: URL) throws -> (ready: [String: Any], pid: pid_t) {
      let run = try launchRelaunchChild(common(round) + ["--ararat-check=private-durability-seed", "--ararat-relaunch-mode=\(mode)"], processGroup: true, trace: trace)
      child = run; group = run.pid; firstPID = run.pid
      guard let line = readRelaunchLine(run.output, seconds: 90), let data = line.data(using: .utf8),
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["ready"] as? Bool == true else { throw NSError(domain: "Ararat.durability", code: 1) }
      return (object, run.pid)
    }
    func verify(_ titles: [String], round: URL) throws -> (object: [String: Any], status: Int32) {
      let encoded = (try JSONSerialization.data(withJSONObject: titles)).base64EncodedString()
      let run = try launchRelaunchChild(common(round) + ["--ararat-check=private-durability-verify", "--ararat-private-titles=\(encoded)"])
      child = run
      guard let line = readRelaunchLine(run.output, seconds: 90), let data = line.data(using: .utf8),
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let status = reapRelaunchChild(run.pid, seconds: 30) else { throw NSError(domain: "Ararat.durability", code: 2) }
      close(run.output); child = nil
      return (object, status)
    }
    // 1. Clean quit with private tabs open.
    let cleanSeed = try seed("private-clean", round: clean)
    guard let cleanStatus = reapRelaunchChild(cleanSeed.pid, seconds: 30) else { return failure("clean run did not exit") }
    close(child!.output); child = nil
    kill(-cleanSeed.pid, SIGKILL); group = nil
    guard cleanStatus == 0 else { return failure("clean run did not quit cleanly") }
    let titles = cleanSeed.ready["titles"] as? [String] ?? []
    let urls = cleanSeed.ready["urls"] as? [String] ?? []
    guard !titles.isEmpty else { return failure("seed reported no titles") }
    let cleanDisk = searchPrivateScratch(clean, needles: titles + urls)
    let cleanVerify = try verify(titles, round: clean)
    // 2. SIGKILL with private tabs open.
    let crashSeed = try seed("private-crash", round: crash)
    guard kill(-crashSeed.pid, SIGKILL) == 0 else { return failure("cannot kill the crash run") }
    guard let crashStatus = reapRelaunchChild(crashSeed.pid, seconds: 30) else { return failure("crash run did not exit") }
    close(child!.output); child = nil
    group = nil
    guard (crashStatus & 0x7f) == SIGKILL else { return failure("crash run was not killed") }
    let crashTitles = crashSeed.ready["titles"] as? [String] ?? titles
    let crashUrls = crashSeed.ready["urls"] as? [String] ?? urls
    let crashDisk = searchPrivateScratch(crash, needles: crashTitles + crashUrls)
    let crashVerify = try verify(crashTitles, round: crash)
    if let error = cleanup() { return failure(error) }
    let cleanDiskClean = (cleanDisk["hits"] as? [String] ?? []).isEmpty
    let crashDiskClean = (crashDisk["hits"] as? [String] ?? []).isEmpty
    let cleanOK = cleanVerify.object["ok"] as? Bool == true && cleanVerify.status == 0 && cleanDiskClean
    let crashOK = crashVerify.object["ok"] as? Bool == true && crashVerify.status == 0 && crashDiskClean
    let result: [String: Any] = ["check": "private-durability", "ok": cleanOK && crashOK,
                                 "clean": ["disk": cleanDisk, "verify": cleanVerify.object],
                                 "crash": ["disk": crashDisk, "verify": crashVerify.object],
                                 "titles": titles]
    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
       let line = String(data: data, encoding: .utf8) { print(line); fflush(stdout) }
    return cleanOK && crashOK ? 0 : 1
  } catch { return failure(String(describing: error)) }
}
