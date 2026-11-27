import AppKit
import ImageIO
import PlayhouseCore
import ServiceManagement
import UniformTypeIdentifiers

/// `PlatformServices` on macOS: AppKit's pasteboard, workspace, sounds, cursors and app, and
/// the `SMAppService` launch agent that fires scheduled tasks. The app and the bridge daemon
/// both install it at launch.
final class MacPlatformServices: PlatformServices {
    /// Sounds keep playing only while something holds them; each one is held until it ends.
    private var playingSounds: [NSSound] = []

    init() {}

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copyImageToClipboard(_ png: Data) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(png, forType: .png)
    }

    func clipboardText() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }

    func revealInFileBrowser(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func open(_ url: URL, withApplicationAt application: URL) -> Bool {
        NSWorkspace.shared.open([url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    func applicationURL(bundleIdentifier: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    func playSystemSound(named name: String, muted: Bool) -> (played: Bool, muted: Bool) {
        let sound = NSSound(contentsOfFile: "/System/Library/Sounds/\(name).aiff", byReference: true)
        if muted { sound?.volume = 0 }
        let played = sound?.play() == true
        // Each transition owns its sound, so overlapping transitions do not interrupt one another.
        if let sound, played {
            playingSounds.append(sound)
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                self?.playingSounds.removeAll { $0 === sound }
            }
        }
        return (played, sound?.volume == 0)
    }

    func pushCursor(_ cursor: PlatformCursor) {
        cursor.nsCursor.push()
    }

    func popCursor() {
        NSCursor.pop()
    }

    var keyWindowFrame: CGRect? {
        NSApp.keyWindow?.frame
    }

    var activeScreenVisibleFrame: CGRect? {
        (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame
    }

    var mainScreenVisibleFrame: CGRect? {
        NSScreen.main?.visibleFrame
    }

    var isPrimaryMouseButtonDown: Bool {
        NSEvent.pressedMouseButtons & 1 != 0
    }

    func showErrorAlert(_ error: Error) {
        NSAlert(error: error).runModal()
    }

    func confirmAlert(title: String, message: String, confirmTitle: String, destructive: Bool) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = destructive
        return alert.runModal() == .alertFirstButtonReturn
    }

    func chooseFiles(_ request: FileChooserRequest, completion: @escaping ([URL]?) -> Void) -> any FileChooserPanel {
        let panel = NSOpenPanel()
        panel.title = request.title
        if let message = request.message { panel.message = message }
        panel.prompt = request.prompt
        panel.canChooseFiles = request.choosesFiles
        panel.canChooseDirectories = request.choosesDirectories
        panel.allowsMultipleSelection = request.allowsMultipleSelection
        if request.imagesOnly { panel.allowedContentTypes = [.image] }
        if let directory = request.startingDirectory { panel.directoryURL = directory }
        panel.begin { response in
            completion(response == .OK ? panel.urls : nil)
        }
        return OpenPanel(panel: panel)
    }

    func isImageFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .image) == true
    }

    func attachmentImage(from data: Data) -> AttachmentImage? {
        // A picture too large to send as it is is decoded at a bounded size and sent as JPEG.
        let wasOversizedInput = data.count > 10_000_000
        guard let bitmap = wasOversizedInput ? Self.thumbnailBitmap(from: data) : NSBitmapImageRep(data: data),
              let encoded = Self.encodedImage(bitmap, preferJPEG: wasOversizedInput), encoded.data.count <= 10_000_000 else { return nil }
        let previewData = wasOversizedInput ? bitmap.representation(using: .png, properties: [:]) : encoded.data
        guard let previewData else { return nil }
        return AttachmentImage(data: encoded.data, mimeType: encoded.mimeType, previewData: previewData)
    }

    private static func thumbnailBitmap(from data: Data) -> NSBitmapImageRep? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1600
                ] as CFDictionary
              ) else {
            return nil
        }
        return NSBitmapImageRep(cgImage: image)
    }

    /// The bitmap as PNG, or JPEG when preferred, shrunk until it fits in 10 MB.
    private static func encodedImage(_ bitmap: NSBitmapImageRep, preferJPEG: Bool = false) -> (data: Data, mimeType: String)? {
        if preferJPEG,
           let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]),
           jpeg.count <= 10_000_000 {
            return (jpeg, "image/jpeg")
        }
        if !preferJPEG,
           let png = bitmap.representation(using: .png, properties: [:]), png.count <= 10_000_000 {
            return (png, "image/png")
        }

        let maximumDimension = 1600
        let scale = min(1, Double(maximumDimension) / Double(max(bitmap.pixelsWide, bitmap.pixelsHigh)))
        var width = max(1, Int((Double(bitmap.pixelsWide) * scale).rounded()))
        var height = max(1, Int((Double(bitmap.pixelsHigh) * scale).rounded()))
        while width > 0 && height > 0 {
            guard let resized = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 3,
                hasAlpha: false,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else { return nil }
            guard let context = NSGraphicsContext(bitmapImageRep: resized) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            bitmap.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
            context.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
            for quality in stride(from: 0.85, through: 0.35, by: -0.1) {
                if let jpeg = resized.representation(using: .jpeg, properties: [.compressionFactor: quality]), jpeg.count <= 10_000_000 {
                    return (jpeg, "image/jpeg")
                }
            }
            guard width > 1, height > 1 else { return nil }
            width = max(1, Int(Double(width) * 0.85))
            height = max(1, Int(Double(height) * 0.85))
        }
        return nil
    }

    func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
    }

    func terminateApp() {
        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
    }

    /// The scheduler agent's plist ships in the app bundle, named for the bundle identifier so
    /// worktree builds never share an agent. Test builds register none.
    private var schedulerService: SMAppService? {
        guard let identifier = Bundle.main.bundleIdentifier,
              !BridgeContract.isTestBundle(PlayhouseAppIdentity.applicationIdentifier) else { return nil }
        let plistName = "\(identifier).scheduler.plist"
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchAgents/\(plistName)").path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return SMAppService.agent(plistName: plistName)
    }

    var schedulerAgentStatus: SchedulerAgentStatus {
        guard let service = schedulerService else { return .unavailable }
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered, .notFound: return .notRegistered
        @unknown default: return .notRegistered
        }
    }

    func registerSchedulerAgent() throws {
        try schedulerService?.register()
    }

    func unregisterSchedulerAgent() throws {
        try schedulerService?.unregister()
    }

    func openLoginItemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// An open panel the app can bring back to the front.
private final class OpenPanel: FileChooserPanel {
    let panel: NSOpenPanel
    init(panel: NSOpenPanel) { self.panel = panel }
    var isVisible: Bool { panel.isVisible }
    func bringToFront() { panel.makeKeyAndOrderFront(nil) }
}

extension PlatformCursor {
    var nsCursor: NSCursor {
        switch self {
        case .arrow: .arrow
        case .pointingHand: .pointingHand
        case .resizeLeftRight: .resizeLeftRight
        case .resizeUpDown: .resizeUpDown
        case .iBeam: .iBeam
        }
    }
}
