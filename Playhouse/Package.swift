// swift-tools-version:6.0
// Playhouse's shared modules, which the macOS app target (Playhouse.xcodeproj) builds on and a
// Linux port can reuse. Dependencies only point down:
//
//   app (Xcode target: windows, menus, AppKit views, platform services)
//     -> PlayhouseViews (composites)  -> PlayhouseAtoms (atoms, plugin host)
//     -> PlayhouseUI (SwiftUI typealiases and shims)  -> PlayhouseCore (Foundation only)
//
// Declarations shared across modules use `package` access. The app target and the daemon's
// raw swiftc build pass the same package name (`-package-name playhouse`) to see them.
// See docs/linux-port-readiness.md.
import PackageDescription

/// PlayhouseCore must stay Foundation-only. Aliasing the Apple UI frameworks to modules that
/// don't exist makes an `import` of any of them fail to compile here, on macOS too. Combine
/// can't be aliased (Foundation's overlay loads it), so scripts/check-module-boundaries.py
/// rejects `import Combine` instead.
let coreForbiddenImports: [SwiftSetting] = [
    .unsafeFlags([
        "-module-alias", "AppKit=PlayhouseCore_must_not_import_AppKit",
        "-module-alias", "SwiftUI=PlayhouseCore_must_not_import_SwiftUI",
        "-module-alias", "SwiftData=PlayhouseCore_must_not_import_SwiftData",
    ]),
]

var targets: [Target] = [
    .target(
        name: "PlayhouseCore",
        dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
        path: "Core",
        swiftSettings: coreForbiddenImports
    ),
    .target(
        name: "PlayhouseUI",
        dependencies: ["PlayhouseCore"],
        path: "UI"
    ),
    .testTarget(
        name: "PlayhouseCoreTests",
        dependencies: ["PlayhouseCore"],
        path: "CoreTests"
    ),
]

var products: [Product] = [
    .library(name: "PlayhouseCore", targets: ["PlayhouseCore"]),
    .library(name: "PlayhouseUI", targets: ["PlayhouseUI"]),
]

#if os(macOS)
// The atoms and composites compile against PlayhouseUI; until PlayhouseUI has a SwiftCrossUI
// implementation they build on macOS only.
targets += [
    .target(
        name: "PlayhouseAtoms",
        dependencies: ["PlayhouseUI"],
        path: "Atoms"
    ),
    .target(
        name: "PlayhouseViews",
        dependencies: ["PlayhouseAtoms"],
        path: "Views"
    ),
]
products += [
    .library(name: "PlayhouseAtoms", targets: ["PlayhouseAtoms"]),
    .library(name: "PlayhouseViews", targets: ["PlayhouseViews"]),
]
#endif

let package = Package(
    name: "Playhouse",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: [
        .package(path: "../Vendor/GRDB.swift"),
    ],
    targets: targets,
    swiftLanguageModes: [.v5]
)
