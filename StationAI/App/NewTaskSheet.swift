import AppKit
import SwiftUI

struct NewTaskSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(WorkspaceSettings.defaultParentFolderKey, store: WorkspaceSettings.preferencesStore) private var defaultParentFolderPath = ""
    @FocusState private var isTitleFocused: Bool
    @State private var title = ""
    @State private var parentFolderURL: URL?
    @State private var roots: [URL] = []
    @State private var isChoosingInitialParent = false

    let onCreate: (String, [URL]) -> Void

    private var normalizedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Create a task")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                Text("Choose the folders Codex should use as context. You can include multiple repositories in one task.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField("What needs to get done?", text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($isTitleFocused)
                .accessibilityIdentifier("task-title-field")

            if let parentFolderURL {
                HStack(spacing: 7) {
                    Image(systemName: "folder.badge.gearshape")
                        .foregroundStyle(.secondary)
                    Text("Repository suggestions from \(parentFolderURL.path)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(parentFolderURL.path)
                    Spacer(minLength: 0)
                    Button("Change parent…", action: chooseInitialParent)
                        .font(.system(size: 10))
                        .buttonStyle(.link)
                }
                WorkspaceRootSelector(parentFolderURL: parentFolderURL, roots: $roots)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    if isChoosingInitialParent {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(isChoosingInitialParent
                        ? "Choosing a default parent folder…"
                        : "Choose a default parent folder to find repository suggestions.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Button("Choose parent folder…", action: chooseInitialParent)
                        .buttonStyle(.borderedProminent)
                        .disabled(isChoosingInitialParent)
                }
                .frame(maxWidth: .infinity, minHeight: 180, alignment: .center)
            }

            Label("Codex can access your entire machine and the network. These folders are task context, not an access restriction.", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("full-access-notice")

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("cancel-task-button")

                Button("Done") {
                    onCreate(normalizedTitle, roots)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.34, green: 0.40, blue: 0.86))
                .keyboardShortcut(.defaultAction)
                .disabled(normalizedTitle.isEmpty || roots.isEmpty)
                .accessibilityIdentifier("create-task-button")
            }
        }
        .padding(24)
        .frame(width: 560, height: parentFolderURL == nil ? 430 : 660)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            parentFolderURL = WorkspaceSettingsManager().defaultParentFolderURL
            if parentFolderURL == nil {
                chooseInitialParent()
            } else {
                isTitleFocused = true
            }
        }
    }

    private func chooseInitialParent() {
        guard !isChoosingInitialParent else { return }
        isChoosingInitialParent = true
        let panel = NSOpenPanel()
        panel.title = "Choose default parent folder"
        panel.message = "StationAI will suggest Git repositories found below this folder."
        panel.prompt = "Use This Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = parentFolderURL ?? FileManager.default.homeDirectoryForCurrentUser
        panel.begin { response in
            DispatchQueue.main.async {
                isChoosingInitialParent = false
                guard response == .OK, let selected = panel.url else {
                    if parentFolderURL == nil { dismiss() }
                    return
                }
                let normalized = selected.standardizedFileURL
                do {
                    try WorkspaceSettingsManager().setDefaultParentFolder(normalized.path)
                    defaultParentFolderPath = normalized.path
                } catch {
                    if parentFolderURL == nil { dismiss() }
                    return
                }
                parentFolderURL = normalized
                isTitleFocused = true
            }
        }
    }
}

struct WorkspaceRootsEditor: View {
    @Environment(\.dismiss) private var dismiss
    let parentFolderURL: URL?
    let initialRoots: [URL]
    let onSave: ([URL]) -> Void
    @State private var roots: [URL]

    init(parentFolderURL: URL?, initialRoots: [URL], onSave: @escaping ([URL]) -> Void) {
        self.parentFolderURL = parentFolderURL
        self.initialRoots = initialRoots
        self.onSave = onSave
        _roots = State(initialValue: initialRoots)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit working folders")
                .font(.system(size: 19, weight: .semibold, design: .rounded))
            Text("Changes apply to the next Codex turn. The first folder is used as the working directory.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            WorkspaceRootSelector(parentFolderURL: parentFolderURL, roots: $roots)
            Label("Codex has full machine and network access; this list sets task context only.", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save folders") {
                    onSave(roots)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(roots.isEmpty)
                .accessibilityIdentifier("save-workspace-roots-button")
            }
        }
        .padding(24)
        .frame(width: 560, height: 620)
    }
}
