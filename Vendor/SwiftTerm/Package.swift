// swift-tools-version:6.0

// Vendored from https://github.com/migueldeicaza/SwiftTerm at tag v1.20.0
// (commit 5d14406844143538cd8f8851d2d8a67c1fe443e5). Only the SwiftTerm library
// target is kept. Its build-info plugin output is committed as
// Sources/SwiftTerm/SwiftTermBuildInfo.swift, so the package has no plugins and
// no remote dependencies to resolve. The optional Metal renderer's shader is
// excluded so the build needs no Metal toolchain; Playhouse uses the default
// CoreGraphics renderer.

import PackageDescription

let package = Package(
    name: "SwiftTerm",
    platforms: [
        .macOS(.v11)
    ],
    products: [
        .library(name: "SwiftTerm", targets: ["SwiftTerm"])
    ],
    targets: [
        .target(
            name: "SwiftTerm",
            path: "Sources/SwiftTerm",
            exclude: ["Mac/README.md", "iOS", "Apple/Metal/Shaders.metal"]
        )
    ],
    swiftLanguageModes: [.v5]
)
