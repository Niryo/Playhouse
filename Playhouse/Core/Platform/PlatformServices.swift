import Foundation

/// The operating system services Playhouse uses beyond Foundation: the clipboard, opening files
/// and URLs, sounds, the pointer, windows, and the login item that runs scheduled tasks.
///
/// Core code and the composites call `Platform.services`; the macOS app target and the bridge
/// daemon install `MacPlatformServices` at launch. A Linux port installs its own implementation
/// (GTK clipboard, `xdg-open`, a systemd user timer for schedules) without touching callers.
package protocol PlatformServices: AnyObject {
    // MARK: Clipboard

    /// Replaces the clipboard's contents with `text`.
    func copyToClipboard(_ text: String)
    /// Replaces the clipboard's contents with a PNG image.
    func copyImageToClipboard(_ png: Data)
    /// The clipboard's text, if it holds any.
    func clipboardText() -> String?

    // MARK: Files and URLs

    /// Opens a file or URL in the app the system chooses for it. False when nothing opened it.
    @discardableResult func open(_ url: URL) -> Bool
    /// Shows files selected in the system file browser.
    func revealInFileBrowser(_ urls: [URL])
    /// Opens a folder with a specific application, such as an editor or a terminal.
    @discardableResult func open(_ url: URL, withApplicationAt application: URL) -> Bool
    /// Installed applications that can open folders, such as editors and terminals.
    func applicationURL(bundleIdentifier: String) -> URL?

    // MARK: Sounds

    /// Plays a named system alert sound; with `muted` it plays at volume 0. Returns whether it
    /// played and whether it played muted.
    func playSystemSound(named name: String, muted: Bool) -> (played: Bool, muted: Bool)

    // MARK: Pointer and windows

    /// Shows the pointer as `cursor` until a matching `popCursor()`, as while a divider is dragged.
    func pushCursor(_ cursor: PlatformCursor)
    func popCursor()
    /// The key window's frame on screen, nil without one.
    var keyWindowFrame: CGRect? { get }
    /// The visible area (without the menu bar and Dock) of the screen showing the key window,
    /// or of the main screen without a key window.
    var activeScreenVisibleFrame: CGRect? { get }
    /// The visible area of the main screen.
    var mainScreenVisibleFrame: CGRect? { get }
    /// Whether the primary mouse button is down right now, as during a drag the app can't see.
    var isPrimaryMouseButtonDown: Bool { get }
    /// Shows an error in a modal alert, returning once the user dismisses it.
    func showErrorAlert(_ error: Error)
    /// Asks a question in a modal alert with a confirm button and Cancel; true when confirmed.
    func confirmAlert(title: String, message: String, confirmTitle: String, destructive: Bool) -> Bool

    // MARK: Choosing files

    /// Shows the open panel without blocking the window. `completion` gets the chosen URLs, or
    /// nil when the user cancels. The returned panel can be brought back to the front.
    @discardableResult func chooseFiles(_ request: FileChooserRequest, completion: @escaping ([URL]?) -> Void) -> any FileChooserPanel
    /// Whether the file at `url` is an image, by its type.
    func isImageFile(_ url: URL) -> Bool
    /// An image read from `data` and encoded to attach to a message (within 10 MB, shrunk and
    /// JPEG-compressed when it must be), with PNG data for its preview. Nil when `data` isn't a
    /// readable image or can't be made small enough.
    func attachmentImage(from data: Data) -> AttachmentImage?
    /// Brings Playhouse to the front.
    func activateApp()
    /// Quits Playhouse.
    func terminateApp()

    // MARK: Login item

    /// Whether the background agent that fires scheduled tasks while the app is closed is
    /// registered, needs the user's approval, or is off.
    var schedulerAgentStatus: SchedulerAgentStatus { get }
    /// Registers that agent, or removes it.
    func registerSchedulerAgent() throws
    func unregisterSchedulerAgent() throws
    /// Opens the system settings where the user approves the agent.
    func openLoginItemSettings()
}

/// What the open panel asks for.
package struct FileChooserRequest {
    package var title: String
    package var message: String?
    package var prompt: String
    package var choosesFiles: Bool
    package var choosesDirectories: Bool
    package var allowsMultipleSelection: Bool
    /// Only image files can be chosen.
    package var imagesOnly = false
    package var startingDirectory: URL?

    package init(title: String, message: String? = nil, prompt: String, choosesFiles: Bool, choosesDirectories: Bool,
                 allowsMultipleSelection: Bool, imagesOnly: Bool = false, startingDirectory: URL? = nil) {
        self.title = title
        self.message = message
        self.prompt = prompt
        self.choosesFiles = choosesFiles
        self.choosesDirectories = choosesDirectories
        self.allowsMultipleSelection = allowsMultipleSelection
        self.imagesOnly = imagesOnly
        self.startingDirectory = startingDirectory
    }
}

/// An open panel on screen.
package protocol FileChooserPanel: AnyObject {
    var isVisible: Bool { get }
    func bringToFront()
}

/// An image ready to attach: its encoded data and type, and PNG data to preview it.
package struct AttachmentImage {
    package var data: Data
    package var mimeType: String
    package var previewData: Data

    package init(data: Data, mimeType: String, previewData: Data) {
        self.data = data
        self.mimeType = mimeType
        self.previewData = previewData
    }
}

/// The pointer shapes Playhouse shows.
package enum PlatformCursor: Equatable, Sendable {
    case arrow
    case pointingHand
    case resizeLeftRight
    case resizeUpDown
    case iBeam
}

package enum SchedulerAgentStatus: Equatable, Sendable {
    case enabled
    case requiresApproval
    case notRegistered
    /// This build has no agent to register, as in a test build.
    case unavailable
}

package enum Platform {
    /// The running process's services. Until the app or daemon installs its implementation,
    /// every service is unavailable and does nothing.
    package nonisolated(unsafe) static var services: any PlatformServices = UnavailablePlatformServices()
}

/// The services of a process that installed none: nothing opens, plays or registers.
package final class UnavailablePlatformServices: PlatformServices {
    package init() {}

    package func copyToClipboard(_ text: String) {}
    package func copyImageToClipboard(_ png: Data) {}
    package func clipboardText() -> String? { nil }
    package func open(_ url: URL) -> Bool { false }
    package func revealInFileBrowser(_ urls: [URL]) {}
    package func open(_ url: URL, withApplicationAt application: URL) -> Bool { false }
    package func applicationURL(bundleIdentifier: String) -> URL? { nil }
    package func playSystemSound(named name: String, muted: Bool) -> (played: Bool, muted: Bool) { (false, muted) }
    package func pushCursor(_ cursor: PlatformCursor) {}
    package func popCursor() {}
    package var keyWindowFrame: CGRect? { nil }
    package var activeScreenVisibleFrame: CGRect? { nil }
    package var mainScreenVisibleFrame: CGRect? { nil }
    package var isPrimaryMouseButtonDown: Bool { false }
    package func showErrorAlert(_ error: Error) {}
    package func confirmAlert(title: String, message: String, confirmTitle: String, destructive: Bool) -> Bool { false }
    package func chooseFiles(_ request: FileChooserRequest, completion: @escaping ([URL]?) -> Void) -> any FileChooserPanel {
        completion(nil)
        return ClosedFileChooserPanel()
    }
    package func isImageFile(_ url: URL) -> Bool { false }
    package func attachmentImage(from data: Data) -> AttachmentImage? { nil }
    package func activateApp() {}
    package func terminateApp() {}
    package var schedulerAgentStatus: SchedulerAgentStatus { .unavailable }
    package func registerSchedulerAgent() throws {}
    package func unregisterSchedulerAgent() throws {}
    package func openLoginItemSettings() {}
}

private final class ClosedFileChooserPanel: FileChooserPanel {
    var isVisible: Bool { false }
    func bringToFront() {}
}
