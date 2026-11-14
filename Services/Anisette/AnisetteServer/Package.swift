// swift-tools-version: 5.9
// PROTOCOL MOCK — see main.swift. macOS only: it uses Apple's Network framework,
// which does not exist on Linux, so no Linux platform is declared.

import PackageDescription

let package = Package(
    name: "AnisetteServer",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "AnisetteServer",
            path: ".",
            exclude: ["README.md"],
            sources: ["main.swift"]
        )
    ]
)
