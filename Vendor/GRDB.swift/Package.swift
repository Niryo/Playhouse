// swift-tools-version:6.0
// GRDB.swift v7.12.0 (92a554cd0d5e8d67cb18993c6054e73fe42c066c), vendored so the app and the
// raw-swiftc daemon build (scripts/build-grdb.sh) compile the same sources without network access.
// Only the library targets are kept; upstream tests and documentation are omitted.
import PackageDescription

let package = Package(
    name: "GRDB",
    platforms: [.macOS(.v10_15)],
    products: [
        .library(name: "GRDB", targets: ["GRDB"]),
    ],
    targets: [
        .systemLibrary(name: "GRDBSQLite"),
        .target(
            name: "GRDB",
            dependencies: ["GRDBSQLite"],
            path: "GRDB",
            resources: [.copy("PrivacyInfo.xcprivacy")],
            swiftSettings: [
                .define("SQLITE_ENABLE_FTS5"),
                .define("SQLITE_ENABLE_SNAPSHOT"),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
