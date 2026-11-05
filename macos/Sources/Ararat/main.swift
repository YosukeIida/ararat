// The bundle's main executable. No AppKit import, no @main, no NSApplicationMain:
// Chrome's BrowserCrApplication must be the first NSApplication, so the process
// reaches the framework before any AppKit state exists.

import Darwin
import Foundation

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("engine: \(message)\n".utf8))
  exit(1)
}

// The versioned framework path the way chrome_exe_main_mac.cc builds it, the
// version taken from the outer bundle's Info.plist, so the launcher loads the
// framework it shipped with even when a second Versions/<new> is staged next
// to the running one.
var size: UInt32 = 0
guard _NSGetExecutablePath(nil, &size) == -1 else { fail("cannot get the executable path") }
var buffer = [CChar](repeating: 0, count: Int(size))
guard _NSGetExecutablePath(&buffer, &size) == 0 else { fail("cannot get the executable path") }
let end = buffer.firstIndex(of: 0) ?? buffer.count
let executableDir = (String(decoding: buffer[..<end].map { UInt8.init($0) }, as: UTF8.self) as NSString)
  .deletingLastPathComponent

guard let info = Bundle.main.infoDictionary,
      let version = info["CFBundleShortVersionString"] as? String, !version.isEmpty else {
  fail("no CFBundleShortVersionString in the bundle's Info.plist")
}

let frameworkPath = ((executableDir + "/../Frameworks/Chromium Framework.framework/Versions/\(version)/Chromium Framework") as NSString)
  .standardizingPath
guard FileManager.default.fileExists(atPath: frameworkPath) else {
  fail("no engine framework at \(frameworkPath)")
}

guard let handle = dlopen(frameworkPath, RTLD_LAZY | RTLD_LOCAL | RTLD_FIRST) else {
  fail("cannot load \(frameworkPath): \(String(cString: dlerror()))")
}
guard let symbol = dlsym(handle, "ChromeMain") else {
  fail("cannot find ChromeMain: \(String(cString: dlerror()))")
}
typealias ChromeMain = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
let chromeMain = unsafeBitCast(symbol, to: ChromeMain.self)

exit(chromeMain(CommandLine.argc, CommandLine.unsafeArgv))
