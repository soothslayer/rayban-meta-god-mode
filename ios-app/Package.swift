// swift-tools-version: 6.0
import PackageDescription

// Exercise the exact networking and pairing sources without booting a simulator.
let package = Package(
    name: "CJCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "CJCore", targets: ["CJCore"])],
    targets: [
        .target(name: "CJCore", path: "CJ/Core", exclude: ["KeychainStore.swift"]),
        .testTarget(name: "CJCoreTests", dependencies: ["CJCore"], path: "CJTests")
    ],
    swiftLanguageModes: [.v5]
)
