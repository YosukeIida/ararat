// swift-tools-version: 6.0
import Foundation
import PackageDescription

let coreLib = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("../core/target/release")
    .standardized.path

let package = Package(
    name: "Ararat",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AraratUI", targets: ["AraratUI"]),
        .executable(name: "AraratHarness", targets: ["AraratHarness"]),
        .executable(name: "Ararat", targets: ["Ararat"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .target(name: "AraratEngineAPI"),
        .target(
            name: "ararat_ffiFFI",
            // Why not -lararat_ffi: the linker prefers the dylib next to the archive and the
            // harness would then load it from this checkout's absolute path at launch.
            linkerSettings: [.unsafeFlags(["\(coreLib)/libararat_ffi.a"])]
        ),
        .target(
            name: "AraratKit",
            dependencies: ["ararat_ffiFFI", "AraratEngineAPI"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(name: "AraratUI", dependencies: ["AraratKit"]),
        .target(name: "WindowGuard", path: "Tests/WindowGuard"),
        .testTarget(name: "AraratUITests", dependencies: ["AraratUI", "AraratKit", "AraratHarness", "WindowGuard"]),
        .testTarget(name: "PromptFixtureTests", dependencies: ["Ararat", "WindowGuard"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "AraratHarness",
            dependencies: ["AraratUI", "AraratKit"],
            resources: [.copy("Fixtures")]
        ),
        // Why not NSApplicationMain: Chromium must create the first NSApplication.
        .executableTarget(
            name: "Ararat",
            dependencies: ["AraratEngineAPI", "AraratKit", "AraratUI", .product(name: "Sparkle", package: "Sparkle")],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
    ]
)
