// swift-tools-version: 6.0
// Code both Linux card demos share: the @Observable app model, sample data,
// measurement helpers, and GtkProbe, a small C library that reaches GTK
// directly for things neither UI library exposes (frame-clock timing, driving
// a scroll benchmark, rendering a widget to a PNG). Its header takes plain
// pointers, so it never clashes with each library's own GTK module.
import PackageDescription

let package = Package(
    name: "LinuxCardShared",
    products: [
        .library(name: "CardModel", targets: ["CardModel"]),
        .library(name: "GtkProbe", targets: ["GtkProbe"]),
        .library(name: "CardHarness", targets: ["CardHarness"]),
    ],
    targets: [
        .systemLibrary(name: "CGtk4", pkgConfig: "gtk4"),
        .target(name: "GtkProbe", dependencies: ["CGtk4"]),
        .target(name: "CardModel"),
        // Sample data, theme values and the benchmark/screenshot driver.
        .target(name: "CardHarness", dependencies: ["CardModel", "GtkProbe"]),
    ]
)
