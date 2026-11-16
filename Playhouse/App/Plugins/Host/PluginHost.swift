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
        if let refusal = PluginHostRules.refusal(kind: kind, name: name, placement: PluginPlacement(rawValue: plugin.placement)) {
            return .failure(refusal)
        }
        switch (kind, name) {
        case ("bridge", let command):
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
