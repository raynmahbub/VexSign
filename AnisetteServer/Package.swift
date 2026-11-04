// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "AnisetteServer",
    platforms: [
        .macOS(.v13),
        .linux(.ubuntu2204)
    ],
    dependencies: [
        // Network framework is part of the Swift standard library on macOS
        // and available via swift-nio on Linux
    ],
    targets: [
        .executableTarget(
            name: "AnisetteServer",
            path: "."
        )
    ]
)