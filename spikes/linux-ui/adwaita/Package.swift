// swift-tools-version: 6.3
// The board task card rebuilt with Adwaita for Swift (libadwaita / GTK 4).
import PackageDescription

let package = Package(
    name: "AdwCard",
    dependencies: [
        // main as of 2026-10-03 (the only tag, 0.1.0, is from 2024 and fails
        // to build on current Linux); git.aparoksha.dev forwards to Codeberg.
        .package(url: "https://codeberg.org/aparoksha/adwaita-swift", revision: "af5598fbd6f2425841f426ad388d7a7edd6c90e6"),
        .package(path: "../shared"),
    ],
    targets: [
        .executableTarget(
            name: "AdwCard",
            dependencies: [
                .product(name: "Adwaita", package: "adwaita-swift"),
                .product(name: "CardModel", package: "shared"),
                .product(name: "CardHarness", package: "shared"),
                .product(name: "GtkProbe", package: "shared"),
            ],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ]
)
