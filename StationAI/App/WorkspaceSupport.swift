import AppKit
import Foundation
import SwiftUI

enum WorkspaceSettings {
    static let defaultParentFolderKey = "defaultWorkspaceParentFolderPath"

    static var preferencesStore: UserDefaults {
        #if DEBUG
        if let suiteName = ProcessInfo.processInfo.environment["STATIONAI_E2E_DEFAULTS_SUITE"],
           let suite = UserDefaults(suiteName: suiteName) {
            return suite
        }
        #endif
        return .standard
    }

    static func validDirectoryURL(for path: String) -> URL? {
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return url
    }
}

struct CodexWorkspaceContext {
    let roots: [URL]

    var cwd: URL { roots[0] }

    init(roots: [URL]) throws {
        let normalized = roots.map(\.standardizedFileURL)
        guard !normalized.isEmpty else {
            throw WorkspaceError.noRoots
        }
        guard normalized.allSatisfy({ WorkspaceSettings.validDirectoryURL(for: $0.path) != nil }) else {
            throw WorkspaceError.unavailableRoot
        }
        self.roots = Array(NSOrderedSet(array: normalized.map(\.path))).compactMap {
            ($0 as? String).map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
    }
}

enum WorkspaceError: LocalizedError {
    case noRoots
    case unavailableRoot

    var errorDescription: String? {
        switch self {
        case .noRoots:
            "Choose at least one working folder before sending a message."
        case .unavailableRoot:
            "One or more working folders are unavailable. Edit the task folders and try again."
        }
    }
}

struct CodexActivity: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let status: String

    static func from(item: [String: Any]) -> CodexActivity? {
        guard let id = item["id"] as? String, let type = item["type"] as? String else { return nil }
        let status = item["status"] as? String ?? "inProgress"
        switch type {
        case "commandExecution":
            let command = item["command"] as? String ?? (item["command"] as? [String])?.joined(separator: " ") ?? ""
            let cwd = item["cwd"] as? String
            let output = item["aggregatedOutput"] as? String
            let detail = [cwd.map { "in \($0)" }, output.map { String($0.suffix(2_000)) }]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            return CodexActivity(
                id: id,
                title: command.isEmpty ? "Running command" : "Running \(command)",
                detail: detail,
                status: status
            )
        case "fileChange":
            let changes = item["changes"] as? [[String: Any]] ?? []
            let paths = changes.compactMap { $0["path"] as? String }
            return CodexActivity(
                id: id,
                title: paths.isEmpty ? "Editing files" : "Editing \(paths.count) \(paths.count == 1 ? "file" : "files")",
                detail: paths.joined(separator: ", "),
                status: status
            )
        case "webSearch":
            return CodexActivity(id: id, title: "Searching the web", detail: item["query"] as? String ?? "", status: status)
        case "imageView":
            return CodexActivity(id: id, title: "Viewing image", detail: item["path"] as? String ?? "", status: status)
        default:
            return nil
        }
    }
}

struct CodexTurnDiff: Codable, Equatable {
    let unifiedDiff: String

    private struct FileChunk {
        let path: String
        let text: String
    }

    var changedFiles: [String] {
        var paths: [String] = []
        for line in unifiedDiff.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.hasPrefix("+++ b/") else { continue }
            let path = String(line.dropFirst(6))
            if path != "/dev/null", !paths.contains(path) { paths.append(path) }
        }
        return paths
    }

    func merging(_ update: CodexTurnDiff) -> CodexTurnDiff {
        var chunks = fileChunks()
        for updateChunk in update.fileChunks() {
            if let index = chunks.firstIndex(where: { $0.path == updateChunk.path }) {
                chunks[index] = updateChunk
            } else {
                chunks.append(updateChunk)
            }
        }
        guard !chunks.isEmpty else { return CodexTurnDiff(unifiedDiff: update.unifiedDiff) }
        return CodexTurnDiff(unifiedDiff: chunks.map(\.text).joined(separator: "\n"))
    }

    private func fileChunks() -> [FileChunk] {
        let lines = unifiedDiff.components(separatedBy: "\n")
        var chunks: [FileChunk] = []
        var chunkStart = 0
        var currentPath: String?

        func appendCurrentChunk(endingAt end: Int) {
            guard let path = currentPath else {
                chunkStart = end
                return
            }
            let text = lines[chunkStart..<end].joined(separator: "\n")
            chunks.append(FileChunk(path: path, text: text))
            chunkStart = end
            currentPath = nil
        }

        for index in lines.indices {
            let line = lines[index]
            if line.hasPrefix("diff --git "), index > chunkStart {
                appendCurrentChunk(endingAt: index)
            } else if line.hasPrefix("--- a/"), currentPath != nil {
                appendCurrentChunk(endingAt: index)
            }

            if line.hasPrefix("+++ b/") {
                currentPath = String(line.dropFirst(6))
            } else if line.hasPrefix("--- a/"), currentPath == nil {
                currentPath = String(line.dropFirst(6))
            }
        }
        appendCurrentChunk(endingAt: lines.count)
        return chunks
    }

    static func fromFileChangeItems(_ items: [[String: Any]]) -> CodexTurnDiff? {
        var chunks: [String] = []
        for item in items where item["type"] as? String == "fileChange" {
            let changes = item["changes"] as? [[String: Any]] ?? []
            for change in changes {
                guard let path = change["path"] as? String,
                      let diff = change["diff"] as? String, !diff.isEmpty else { continue }
                chunks.append("--- a/\(path)\n+++ b/\(path)\n\(diff)")
            }
        }
        guard !chunks.isEmpty else { return nil }
        return CodexTurnDiff(unifiedDiff: chunks.joined(separator: "\n"))
    }
}

struct CodexThreadHistory: Codable, Equatable {
    let messages: [CodexChatMessage]
    let activities: [CodexActivity]
    let diff: CodexTurnDiff?
}

enum RepositoryScanner {
    static func scan(parent: URL) async -> [URL] {
        await Task.detached(priority: .utility) {
            scanSynchronously(parent: parent)
        }.value
    }

    private static func scanSynchronously(parent: URL) -> [URL] {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let enumerator = manager.enumerator(
                at: parent,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [],
                errorHandler: { _, _ in true }
              ) else { return [] }

        let markerAtParent = parent.appendingPathComponent(".git", isDirectory: false)
        if manager.fileExists(atPath: markerAtParent.path) {
            return [parent.standardizedFileURL]
        }

        var repositories: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values?.isDirectory == true else { continue }

            let marker = url.appendingPathComponent(".git", isDirectory: false)
            if manager.fileExists(atPath: marker.path) {
                repositories.append(url.standardizedFileURL)
                enumerator.skipDescendants()
            }
        }
        return repositories.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }
}

struct WorkspaceRootSelector: View {
    let parentFolderURL: URL?
    @Binding var roots: [URL]
    @State private var repositories: [URL] = []
    @State private var searchText = ""
    @State private var isScanning = false

    private var filteredRepositories: [URL] {
        let available = repositories.filter { candidate in
            !roots.contains(where: { $0.standardizedFileURL.path == candidate.standardizedFileURL.path })
        }
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return available }
        let query = searchText.lowercased()
        return available.filter {
            $0.lastPathComponent.lowercased().contains(query) || $0.path.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Working folders")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: browseForFolders) {
                    Label("Browse…", systemImage: "folder")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("browse-workspace-roots-button")
            }

            if roots.isEmpty {
                Text("Choose one or more folders. Git repositories under your parent folder appear as suggestions.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                FlowLayout(spacing: 7) {
                    ForEach(roots, id: \.standardizedFileURL.path) { root in
                        HStack(spacing: 5) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 10))
                            Text(root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                            Button {
                                roots.removeAll { $0.standardizedFileURL.path == root.standardizedFileURL.path }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .help("Remove \(root.path)")
                            .accessibilityLabel("Remove \(root.lastPathComponent)")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.accentColor.opacity(0.1), in: Capsule())
                    }
                }
            }

            TextField("Search suggested repositories…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("workspace-repository-search")

            if isScanning {
                ProgressView("Finding Git repositories…")
                    .controlSize(.small)
                    .font(.system(size: 11))
            } else if filteredRepositories.isEmpty {
                Text(parentFolderURL == nil ? "Choose a default parent folder in Settings to see repository suggestions." : "No matching repositories. Browse to add any folder.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(filteredRepositories, id: \.path) { repository in
                            Button {
                                add(repository)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(repository.lastPathComponent)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.primary)
                                    Text(repository.path)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("repository-suggestion-\(repository.lastPathComponent)")
                        }
                    }
                }
                .frame(maxHeight: 142)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .task(id: parentFolderURL?.path) {
            guard let parentFolderURL else {
                repositories = []
                return
            }
            isScanning = true
            repositories = (try? await WorkspaceManager().suggestedRepositories(parentPath: parentFolderURL.path).map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }) ?? []
            isScanning = false
        }
    }

    private func add(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard !roots.contains(where: { $0.standardizedFileURL.path == path }) else { return }
        roots.append(URL(fileURLWithPath: path, isDirectory: true))
    }

    private func browseForFolders() {
        let panel = NSOpenPanel()
        panel.title = "Choose working folders"
        panel.message = "Choose one or more folders Codex should use as task context."
        panel.prompt = "Add Folders"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = parentFolderURL
        panel.begin { response in
            guard response == .OK else { return }
            DispatchQueue.main.async {
                panel.urls.forEach(add)
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += (x > 0 ? spacing : 0) + size.width
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(maxWidth, x), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct WorkspaceSettingsView: View {
    @AppStorage(WorkspaceSettings.defaultParentFolderKey, store: WorkspaceSettings.preferencesStore) private var defaultParentFolderPath = ""
    @State private var pickerError: String?

    private var parentFolderURL: URL? {
        WorkspaceSettings.validDirectoryURL(for: defaultParentFolderPath)
    }

    var body: some View {
        Form {
            Section("Workspace suggestions") {
                Text("Choose a parent folder. New tasks will search below it for Git repositories to suggest as working folders.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(parentFolderURL?.path ?? "No default parent folder selected")
                        .lineLimit(2)
                        .textSelection(.enabled)
                        .accessibilityLabel(parentFolderURL?.path ?? "No default parent folder selected")
                        .accessibilityIdentifier("default-parent-folder-path")
                    Spacer()
                    Button(parentFolderURL == nil ? "Choose…" : "Change…", action: chooseParentFolder)
                        .accessibilityIdentifier("choose-default-parent-folder-button")
                    if parentFolderURL != nil {
                        Button("Clear") {
                            do {
                                try WorkspaceSettingsManager().setDefaultParentFolder(nil)
                                defaultParentFolderPath = ""
                            } catch {
                                pickerError = error.localizedDescription
                            }
                        }
                        .accessibilityIdentifier("clear-default-parent-folder-button")
                    }
                }
                if !defaultParentFolderPath.isEmpty && parentFolderURL == nil {
                    Label("This folder is unavailable. Choose another parent folder.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            Section {
                Text("Changing this setting affects suggestions for new tasks. It does not change the working folders saved on existing tasks.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 260)
        .alert("Couldn't choose folder", isPresented: Binding(
            get: { pickerError != nil },
            set: { if !$0 { pickerError = nil } }
        )) {
            Button("OK", role: .cancel) { pickerError = nil }
        } message: {
            Text(pickerError ?? "Please try again.")
        }
    }

    private func chooseParentFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose default parent folder"
        panel.message = "StationAI will suggest Git repositories found under this folder."
        panel.prompt = "Use This Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = parentFolderURL ?? FileManager.default.homeDirectoryForCurrentUser
        panel.begin { response in
            guard response == .OK, let selected = panel.url else { return }
            DispatchQueue.main.async {
                let path = selected.standardizedFileURL.path
                do {
                    try WorkspaceSettingsManager().setDefaultParentFolder(path)
                    defaultParentFolderPath = path
                } catch {
                    pickerError = error.localizedDescription
                }
            }
        }
    }
}
