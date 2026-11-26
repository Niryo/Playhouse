// swift-tools-version: 6.0
// The board task card rebuilt with SwiftCrossUI (GTK 4 backend on Linux).
import Foundation
import PackageDescription

// PH_SCUI_FORK=1 builds against the local fork in ../fork/swift-cross-ui (the
// pinned revision plus patches/swiftcrossui-*.patch); see REPORT.md, "Fork".
// PH_SCUI_FORK=remote builds against the same fork pushed to GitHub
// (Niryo/swift-cross-ui, branch playhouse-perf).
let forkMode = ProcessInfo.processInfo.environment["PH_SCUI_FORK"]
let useFork = forkMode == "1" || forkMode == "remote"

let package = Package(
    name: "SCUICard",
    dependencies: [
        // main as of 2026-11-22 (v0.11.0 + 6 days); pinned for reproducibility.
        forkMode == "remote"
            ? .package(url: "https://github.com/Niryo/swift-cross-ui", revision: "3a5e724d6a5ea22e5151efca41f4e83fc97d5bbb")
            : useFork
            ? .package(path: "../fork/swift-cross-ui")
            : .package(url: "https://github.com/moreSwift/swift-cross-ui", revision: "8b39220d81066d5479d3d102482aed2bb6d5cb6f"),
        .package(path: "../shared"),
    ],
    targets: [
        .executableTarget(
            name: "SCUICard",
            dependencies: [
                .product(name: "SwiftCrossUI", package: "swift-cross-ui"),
                .product(name: "GtkBackend", package: "swift-cross-ui"),
                .product(name: "CardModel", package: "shared"),
                .product(name: "CardHarness", package: "shared"),
                .product(name: "GtkProbe", package: "shared"),
            ],
            swiftSettings: useFork ? [.define("PH_SCUI_FORK")] : []
        ),
    ]
)
