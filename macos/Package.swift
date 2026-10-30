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
            linkerSettings: [.unsafeFlags(["-L\(coreLib)", "-lararat_ffi"])]
        ),
        .target(
            name: "AraratKit",
            dependencies: ["ararat_ffiFFI"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(name: "AraratUI", dependencies: ["AraratKit"]),
        .executableTarget(
            name: "AraratHarness",
            dependencies: ["AraratUI", "AraratKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
