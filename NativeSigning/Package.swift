// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NativeSigning",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "NativeSigning", targets: ["NativeSigning"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", "3.15.1"..<"6.0.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", "1.5.1"..<"2.0.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", "1.17.1"..<"2.0.0"),
        .package(url: "https://github.com/krzyzanowskim/OpenSSL.git", "3.6.1"..<"4.0.0"),
        .package(path: "../Zsign"),
        .package(path: "../NimbleKit"),
    ],
    targets: [
        .target(
            name: "NativeSigning",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "CryptoExtras", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "OpenSSL", package: "OpenSSL"),
                .product(name: "ZsignSwift", package: "Zsign"),
                .product(name: "NimbleExtensions", package: "NimbleKit"),
            ],
            path: ".",
            exclude: [
                "README.md",
                "inputs.lock.json",
                "prepare_smoke.py",
                "prepare_server_compatibility.py",
                "prepare_combined_smoke.py",
                "patches",
                "tests",
                "Smoke",
                "ServerCompatibility",
                "app-dependency-review.json",
                "apple-cms-policy-review.json",
                "combined-inputs.json",
                "designated-requirement-review.json",
                "development-certificate-review.json",
            ],
            sources: [
                "Authentication",
                "Codec",
                "Identity",
                "Provisioning",
                "Signing",
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "NativeSigningTests",
            dependencies: ["NativeSigning"],
            path: "Tests"
        ),
    ]
)