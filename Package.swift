// swift-tools-version: 6.0
import PackageDescription
import Foundation

let rustLibraryPath = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(".build/rust/release").path

// SwiftPM 6.4 marks the executable with the deployment target as its SDK
// version (`minos 14.0`, `sdk 14.0`). macOS uses that field to decide whether
// an app opts into Liquid Glass and the macOS 27 window chrome. Pass the real
// SDK version to the linker while keeping macOS 14 as the minimum.
let macOSDeploymentTarget = "14.0"
let macOSSDKVersion: String = {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["--sdk", "macosx", "--show-sdk-version"]
    let pipe = Pipe()
    process.standardOutput = pipe
    do {
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !value.isEmpty { return value }
    } catch {}
    return "27.0"
}()

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
        .executableTarget(name: "DropNest", dependencies: ["DropNestCore"], linkerSettings: [
            .unsafeFlags([
                "-Xlinker", "-platform_version",
                "-Xlinker", "macos",
                "-Xlinker", macOSDeploymentTarget,
                "-Xlinker", macOSSDKVersion
            ])
        ]),
        .testTarget(name: "DropNestCoreTests", dependencies: ["DropNestCore"]),
        .testTarget(name: "DropNestTests", dependencies: ["DropNest", "DropNestCore"])
    ],
    swiftLanguageModes: [.v5]
)
