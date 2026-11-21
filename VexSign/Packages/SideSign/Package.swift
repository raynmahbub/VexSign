// swift-tools-version: 6.0
//
// Vendored from SideStore/Catalyst (Dependencies/SideSign), AGPL-3.0.
// Odysseus only uses the library; the upstream CLI target is left out. A local SideSignTests
// target (Tests/) covers the library's own pure helpers and ships in no product.
//

import PackageDescription

let package = Package(
    name: "SideSign",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
        .watchOS(.v8),
        .visionOS(.v1)
    ],

    products: [
        .library(
            name: "SideSign",
            type: .static,
            targets: ["SideSign"]
        ),
        .library(
            name: "SideSign-Dynamic",
            type: .dynamic,
            targets: ["SideSign"]
        ),
    ],

    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git",    exact: "4.3.1"),

        .package(url: "https://github.com/mahee96/CodeSignKit.git",   branch: "main"),
        .package(url: "https://github.com/mahee96/GSACryptoKit.git",  branch: "main"),
        .package(url: "https://github.com/SideStore/libdeflate",      branch: "master"),
        .package(url: "https://github.com/mahee96/AnisetteKit.git",   branch: "main"),

//        .package(name: "CodeSignKit",  path: "../../local/CodeSignKit"),
//        .package(name: "GSACryptoKit", path: "../../local/GSACryptoKit"),
//        .package(name: "libdeflate",   path: "../../local/libdeflate"),
//        .package(name: "AnisetteKit",   path: "../../local/AnisetteKit")
    ],

    targets: [
        .target(
            name: "SideSign",
            dependencies: [
                .product(name: "libdeflate", package: "libdeflate"),
                .product(name: "Crypto", package: "swift-crypto"),
                "AnisetteKit",
                "CodeSignKit",
                "GSACryptoKit"
            ],
            path: "Sources"
        ),
        // Pure-helper tests for the vendored library's own deterministic API (PEM/DER
        // passthrough, bundle-id sanitizing, log-header redaction). They build and run only
        // under `swift test --package-path VexSign/Packages/SideSign`; the app and the
        // synthesized native-signing-smoke graph link the library product, never this target.
        .testTarget(
            name: "SideSignTests",
            dependencies: ["SideSign"],
            path: "Tests"
        )
    ],

    swiftLanguageModes: [.v6],
    cLanguageStandard: .gnu11
)
