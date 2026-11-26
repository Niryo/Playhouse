// Renders the app's real TaskItemView (compiled from Playhouse/App, see
// build.sh) in a dark NSWindow and writes PNGs at 2x, as the macOS reference
// for the Linux cards. Usage: native-card <sample.json> <out-dir>
import AppKit
import SwiftUI

struct Sample: Decodable { var task: TaskItemModel }

@MainActor
func render(_ view: some View, width: CGFloat, to url: URL) {
    let host = NSHostingView(rootView: view.frame(width: width).environment(\.colorScheme, .dark))
    host.appearance = NSAppearance(named: .darkAqua)
    let size = host.fittingSize
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = host
    host.frame = NSRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    // Let SwiftUI settle (the meter animates in).
    RunLoop.main.run(until: Date().addingTimeInterval(1.6))
    let scale: CGFloat = 2
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    host.cacheDisplay(in: host.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("wrote \(url.path) \(Int(size.width))x\(Int(size.height))pt")
}

@main
struct NativeCard {
    @MainActor static func main() {
        let args = CommandLine.arguments
        let sample = try! JSONDecoder().decode(Sample.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
        let out = URL(fileURLWithPath: args[2])
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // The board column: 264pt wide cards on the window background (the board), 12pt gutter.
        let card = TaskItemView(model: sample.task)
            .padding(12)
            .background(WorkspaceTheme.windowBackground)
        render(card, width: 264 + 24, to: out.appendingPathComponent("native-card.png"))
    }
}
