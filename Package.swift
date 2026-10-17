// swift-tools-version: 6.0
import PackageDescription
import Foundation

let rustLibraryPath = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(".build/rust/release").path

let package = Package(
    name: "DropNest",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "DropNest", targets: ["DropNest"])],
    targets: [
        .target(name: "DropNestRust", linkerSettings: [
            .unsafeFlags(["-L", rustLibraryPath]),
            .linkedLibrary("dropnest_filecheck"), .linkedLibrary("iconv"), .linkedLibrary("resolv")
        ]),
        .target(name: "DropNestCore", dependencies: ["DropNestRust"]),
        .executableTarget(name: "DropNest", dependencies: ["DropNestCore"]),
        .testTarget(name: "DropNestCoreTests", dependencies: ["DropNestCore"]),
        .testTarget(name: "DropNestTests", dependencies: ["DropNest", "DropNestCore"])
    ],
    swiftLanguageModes: [.v5]
)
