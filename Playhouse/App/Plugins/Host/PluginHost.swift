import AppKit
import SwiftUI

/// A composer change a plugin asks for through `Playhouse.ui.composer`.
enum PluginComposerEdit {
    case setDraft(String)
    case insertText(String)
    case replaceSelection(String)
    case focus
}

/// What a mounted plugin's `Playhouse.ui` calls do in the window showing it.
struct PluginUIActions {
    var close: () -> Void = {}
    var openTask: (UUID) -> Void = { _ in }
    /// Nil where there is no composer (the board's sidebar).
    var composer: ((PluginComposerEdit) -> Void)? = nil
    /// Shows a `task.changes.list` entry's diff; nil where there is no task.
    var openDiff: ((WorkspaceChangeEntry) -> Void)? = nil
    /// Rereads the task's folders and bumps `props.workspace.revision`; nil where there is no task.
    var refreshWorkspace: (() -> Void)? = nil
    /// Moves a task to another column as dragging its card does; nil where there
    /// is no board. The flag says every linked pull request was just seen
    /// merged, so a move to Done trusts that instead of asking GitHub again.
    var moveTask: ((UUID, TaskStatus, Bool) -> Void)? = nil
    /// Opens a task to resolve its pull request conflicts; nil where there is no board.
    var resolveConflicts: ((UUID) -> Void)? = nil
    /// Shows an alert with a title and a message over the window.
    var alert: ((String, String) -> Void)? = nil
    /// Asks the user to confirm and answers whether they did; nil where the
    /// window can't ask (the board and the composer's `/` commands can).
    var confirm: ((PluginConfirmation) async -> Bool)? = nil
    /// Opens a new task, with its schedule picker up for a schedule kind;
    /// nil where there is no board.
    var newTask: ((TaskScheduleKind?) -> Void)? = nil
    /// Opens Login Items in System Settings; nil where there is no board.
    var openLoginItems: (() -> Void)? = nil
    /// Turns on the composer's plan or goal mode; nil where there is no composer.
    var setMode: ((String) -> Void)? = nil
    /// Opens the task's Skills page, at a skill, an MCP server or its sign-in;
    /// nil where there is no task.
    var openSkills: ((SkillsPageFocus?) -> Void)? = nil
    /// Opens a plugin's editor conversation; nil where the window can't.
    var editPlugin: ((String) -> Void)? = nil
    /// Called before a `plugin.delete` bridge call, so the plugin's editor
    /// conversation lets go of it first.
    var willDeletePlugin: ((String) async -> Void)? = nil
    /// Opens a web link; a test build never opens a browser.
    var openURL: (URL) -> Void = { url in
        guard !BridgeContract.isTestBundle(PlayhouseAppIdentity.applicationIdentifier) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// What a plugin's `Playhouse.ui.confirm` asks.
struct PluginConfirmation: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var confirm: String
    var destructive: Bool
}

/// Hands each plugin `app.launched` once per app launch, the first time one
/// of its views mounts.
@MainActor
enum PluginLaunch {
    private static var delivered: Set<String> = []

    /// True the first time it is asked about `pluginID` in this launch.
    static func claim(_ pluginID: String) -> Bool {
        delivered.insert(pluginID).inserted
    }
}

/// Answers a mounted plugin's host calls, `Playhouse.bridge`, `Playhouse.ui`
/// and `fetch`, the same way for a JavaScript plugin (`PluginSurfaceView`)
/// and a built-in one (`BuiltInPluginView`): bridge commands go to the
/// bridge daemon as the CLI's do, and `PluginHostRules` refuses what the
/// placement can't offer, as `plugin render` does headlessly.
@MainActor
struct PluginHost {
    let plugin: PluginRecord
    let actions: PluginUIActions

    func answer(kind: String, name: String, arguments: PluginValue) async -> Result<PluginValue, PluginHostError> {
        let text = arguments.object?["text"]?.string ?? ""
        if let refusal = PluginHostRules.refusal(kind: kind, name: name, placement: PluginPlacement(rawValue: plugin.placement), arguments: arguments) {
            return .failure(refusal)
        }
        switch (kind, name) {
        case ("bridge", let command):
            if command == "plugin.delete", let id = arguments.object?["pluginID"]?.string {
                await actions.willDeletePlugin?(id)
            }
            do {
                let value = try await DaemonClient().call(command, BridgeValue(plugin: arguments).object ?? [:])
                return .success(PluginValue(bridge: value))
            } catch let error as BridgeCommandError {
                return .failure(PluginHostError(code: error.code, message: error.message))
            } catch {
                return .failure(PluginHostError(code: "operation_failed", message: error.localizedDescription))
            }
        case ("net", "fetch"):
            return await PluginNetwork.fetch(arguments)
        case ("ui", "close"):
            actions.close()
        case ("ui", "openTask"):
            guard let id = arguments.object?["taskID"]?.string.flatMap(UUID.init(uuidString:)) else {
                return .failure(PluginHostError(code: "invalid_argument", message: "openTask needs a task ID."))
            }
            actions.openTask(id)
        case ("ui", "openDiff"):
            guard let openDiff = actions.openDiff else {
                return .failure(PluginHostError(code: "unavailable", message: "There is no task's workspace here."))
            }
            guard let entry = try? PluginValueDecoder.decode(WorkspaceChangeEntry.self, from: arguments) else {
                return .failure(PluginHostError(code: "invalid_argument", message: "openDiff needs an entry from task.changes.list."))
            }
            openDiff(entry)
        case ("ui", "refreshWorkspace"):
            guard let refreshWorkspace = actions.refreshWorkspace else {
                return .failure(PluginHostError(code: "unavailable", message: "There is no task's workspace here."))
            }
            refreshWorkspace()
        case ("ui", "moveTask"):
            guard let moveTask = actions.moveTask else {
                return .failure(PluginHostError(code: "unavailable", message: "There is no board here to move a task on."))
            }
            guard let id = arguments.object?["taskID"]?.string.flatMap(UUID.init(uuidString:)),
                  let status = arguments.object?["status"]?.string.flatMap(TaskStatus.init(rawValue:)) else {
                return .failure(PluginHostError(code: "invalid_argument", message: "moveTask needs a task ID and a board column (status)."))
            }
            // Only a built-in plugin's word that the pull requests merged is
            // trusted (the merged check, right after its own probe): the move
            // records them merged, so a JavaScript plugin's moves verify as
            // dragging does.
            moveTask(id, status, plugin.builtIn && arguments.object?["pullRequestsMerged"]?.bool == true)
        case ("ui", "resolveConflicts"):
            guard let resolveConflicts = actions.resolveConflicts else {
                return .failure(PluginHostError(code: "unavailable", message: "There is no board here to open a task from."))
            }
            guard let id = arguments.object?["taskID"]?.string.flatMap(UUID.init(uuidString:)) else {
                return .failure(PluginHostError(code: "invalid_argument", message: "resolveConflicts needs a task ID."))
            }
            resolveConflicts(id)
        case ("ui", "alert"):
            guard let alert = actions.alert else {
                return .failure(PluginHostError(code: "unavailable", message: "This window can't show an alert."))
            }
            alert(arguments.object?["title"]?.string ?? "", arguments.object?["message"]?.string ?? "")
        case ("ui", "openURL"):
            // `PluginHostRules` has already refused any other URL.
            if let url = PluginHostRules.openableURL(arguments) { actions.openURL(url) }
        case ("ui", "confirm"):
            guard let confirm = actions.confirm else {
                return .failure(PluginHostError(code: "unavailable", message: "This window can't ask to confirm."))
            }
            let object = arguments.object ?? [:]
            let confirmed = await confirm(PluginConfirmation(
                title: object["title"]?.string ?? "", message: object["message"]?.string ?? "",
                confirm: object["confirm"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "OK",
                destructive: object["destructive"]?.bool == true
            ))
            return .success(.bool(confirmed))
        case ("ui", "newTask"):
            guard let newTask = actions.newTask else {
                return .failure(PluginHostError(code: "unavailable", message: "There is no board here to open a new task on."))
            }
            // `PluginHostRules` has already refused any other schedule.
            newTask(arguments.object?["schedule"]?.string.flatMap(TaskScheduleKind.init(rawValue:)))
        case ("ui", "openLoginItems"):
            guard let openLoginItems = actions.openLoginItems else {
                return .failure(PluginHostError(code: "unavailable", message: "This window can't open Login Items."))
            }
            openLoginItems()
        case ("ui", "composer.setMode"):
            guard let setMode = actions.setMode else {
                return .failure(PluginHostError(code: "unavailable", message: "There is no composer at this placement."))
            }
            // `PluginHostRules` has already refused any other mode.
            setMode(arguments.object?["mode"]?.string ?? "")
        case ("ui", "openSkills"):
            guard let openSkills = actions.openSkills else {
                return .failure(PluginHostError(code: "unavailable", message: "There is no task's Skills page here."))
            }
            let object = arguments.object ?? [:]
            let signIn = object["signIn"]?.object
            if let id = object["skillID"]?.string {
                openSkills(.skill(id: id))
            } else if let id = object["mcpServerID"]?.string {
                openSkills(.mcpServer(id: id))
            } else if let name = signIn?["name"]?.string, let provider = signIn?["provider"]?.string.flatMap(ConversationProvider.init(rawValue:)) {
                openSkills(.mcpSignIn(name: name, provider: provider))
            } else {
                openSkills(nil)
            }
        case ("ui", "editPlugin"):
            guard let editPlugin = actions.editPlugin else {
                return .failure(PluginHostError(code: "unavailable", message: "This window can't open a plugin's editor."))
            }
            editPlugin(arguments.object?["pluginID"]?.string ?? "")
        case ("ui", let name) where name.hasPrefix("composer."):
            guard let composer = actions.composer else {
                return .failure(PluginHostError(code: "unavailable", message: "There is no composer at this placement."))
            }
            switch name {
            case "composer.setDraft": composer(.setDraft(text))
            case "composer.insertText": composer(.insertText(text))
            case "composer.replaceSelection": composer(.replaceSelection(text))
            case "composer.focus": composer(.focus)
            default: return .failure(PluginHostError(code: "invalid_argument", message: "Unknown composer action \(name)."))
            }
        default:
            return .failure(PluginHostError(code: "invalid_argument", message: "Unknown host call \(kind).\(name)."))
        }
        return .success(.null)
    }

    /// A bridge command's result, decoded, for a built-in plugin written in Swift.
    func bridge<T: Decodable>(_ command: String, _ arguments: [String: PluginValue] = [:], as type: T.Type) async throws -> T {
        switch await answer(kind: "bridge", name: command, arguments: .object(arguments)) {
        case .success(let value): return try PluginValueDecoder.decode(type, from: value)
        case .failure(let error): throw error
        }
    }

    /// A host call whose result a built-in plugin doesn't need.
    func call(_ kind: String, _ name: String, _ arguments: [String: PluginValue] = [:]) async throws {
        if case .failure(let error) = await answer(kind: kind, name: name, arguments: .object(arguments)) { throw error }
    }
}

/// The board's pending `ui.confirm`: one question at a time, answered by
/// `PluginConfirmationModifier`'s dialog. A new question answers an
/// unanswered one with false.
@MainActor
@Observable
final class PluginConfirmations {
    private(set) var current: PluginConfirmation?
    @ObservationIgnored private var continuation: CheckedContinuation<Bool, Never>?

    func ask(_ confirmation: PluginConfirmation) async -> Bool {
        answer(false)
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            current = confirmation
        }
    }

    func answer(_ confirmed: Bool) {
        current = nil
        continuation?.resume(returning: confirmed)
        continuation = nil
    }
}

/// The confirmation dialog a plugin's `ui.confirm` shows over the board, or
/// inside a popover plugin's popover.
struct PluginConfirmationModifier: ViewModifier {
    let confirmations: PluginConfirmations

    func body(content: Content) -> some View {
        content.confirmationDialog(
            confirmations.current?.title ?? "",
            isPresented: Binding(get: { confirmations.current != nil }, set: { if !$0 { confirmations.answer(false) } }),
            titleVisibility: .visible,
            presenting: confirmations.current
        ) { confirmation in
            Button(confirmation.confirm, role: confirmation.destructive ? .destructive : nil) { confirmations.answer(true) }
                .buttonHoverPointer()
                .nativeHelp(confirmation.confirm)
                .accessibilityIdentifier("plugin-confirm-button")
            Button("Cancel", role: .cancel) { confirmations.answer(false) }
                .buttonHoverPointer()
                .nativeHelp("Cancel")
                .accessibilityIdentifier("plugin-confirm-cancel")
        } message: { confirmation in
            Text(confirmation.message)
        }
    }
}
