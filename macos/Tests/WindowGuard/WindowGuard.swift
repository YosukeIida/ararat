import CoreGraphics
import Darwin
import Foundation

func ownOnscreenWindows(_ windows: [[String: Any]], pid: Int32) -> [String] {
    windows.compactMap { window in
        guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
              window[kCGWindowIsOnscreen as String] as? Bool == true else { return nil }
        return "\(window[kCGWindowName as String] as? String ?? "Untitled") (#\(window[kCGWindowNumber as String] ?? "?"))"
    }
}

public func installWindowGuard() -> Int32 {
    atexit {
        guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            FileHandle.standardError.write(Data("Window guard failed to read onscreen windows\n".utf8))
            _exit(1)
        }
        let leaked = ownOnscreenWindows(windows, pid: getpid())
        if !leaked.isEmpty {
            FileHandle.standardError.write(Data("Test process leaked onscreen windows: \(leaked.joined(separator: ", "))\n".utf8))
            _exit(1)
        }
        FileHandle.standardError.write(Data("Test window guard: no onscreen windows for pid \(getpid())\n".utf8))
    }
}
