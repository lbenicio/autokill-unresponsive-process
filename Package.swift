// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "autokill-unresponsive-process",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "autokill-unresponsive-process",
            path: "Sources/autokill-unresponsive-process",
            linkerSettings: [
                .unsafeFlags(["-F/System/Library/PrivateFrameworks"])
            ]
        )
    ]
)
