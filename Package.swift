// swift-tools-version: 6.0

import PackageDescription

var products: [Product] = [
    .executable(name: "sneekd", targets: ["sneekd"]),
    .library(name: "SneekLib", targets: ["SneekLib"]),
]

// Glibc's Swift overlay does not expose prctl(2) (used by Sys.hideProcessMemory);
// on Linux, SneekLib links a tiny system-library shim that imports <sys/prctl.h>
// directly. macOS has no such header and no need for it.
var sneekLibPlatformDependencies: [Target.Dependency] = []
#if os(Linux)
sneekLibPlatformDependencies.append("CPrctl")
#endif

var targets: [Target] = [
    .executableTarget(
        name: "sneekd",
        dependencies: [
            "SneekLib",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]
    ),
    .target(name: "SneekLib", dependencies: sneekLibPlatformDependencies),
    .executableTarget(
        name: "SneekTests",
        dependencies: ["SneekLib"],
        path: "Tests/SneekLibTests"
    ),
]

// The SwiftUI menubar app is macOS-only; the daemon and library also build on Linux.
#if os(macOS)
products.append(.executable(name: "Sneek", targets: ["SneekApp"]))
targets.append(.executableTarget(name: "SneekApp", dependencies: ["SneekLib"], path: "Sources/SneekApp"))
#endif

#if os(Linux)
targets.append(.target(name: "CPrctl", path: "Sources/CPrctl"))
#endif

let package = Package(
    name: "Sneek",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: targets
)
