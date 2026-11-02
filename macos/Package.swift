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
    ],
    targets: [
        .target(
            name: "ararat_ffiFFI",
            // Why not -lararat_ffi: the linker prefers the dylib next to the archive and the
            // harness would then load it from this checkout's absolute path at launch.
            linkerSettings: [.unsafeFlags(["\(coreLib)/libararat_ffi.a"])]
        ),
        .target(
            name: "AraratKit",
            dependencies: ["ararat_ffiFFI"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(name: "AraratUI", dependencies: ["AraratKit"]),
        .testTarget(name: "AraratUITests", dependencies: ["AraratUI", "AraratKit", "AraratHarness"]),
        .executableTarget(
            name: "AraratHarness",
            dependencies: ["AraratUI", "AraratKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
