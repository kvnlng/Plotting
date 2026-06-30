// swift-tools-version: 6.0
//
//  Package.swift
//  Murmur (open-source core)
//
//  Exposes `MurmurCore` as a Swift Package product so the private paid
//  extensions repo (kvnlng/Murmur-Extensions) can depend on it via SPM.
//  The Murmur app target in `Murmur.xcodeproj` continues to consume
//  MurmurCore through its framework target for now (Phase B3 will
//  collapse that into this package). Until then the framework target
//  and the package coexist over the same source tree at `MurmurCore/`.
//

import PackageDescription

let package = Package(
    name: "MurmurCore",
    platforms: [
        .macOS("26.0"),
    ],
    products: [
        .library(
            name: "MurmurCore",
            targets: ["MurmurCore"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "MurmurCore",
            path: "MurmurCore",
            resources: [
                .process("WaveformShaders.metal"),
            ]
        ),
        .testTarget(
            name: "MurmurCoreTests",
            dependencies: ["MurmurCore"],
            path: "MurmurCoreTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
