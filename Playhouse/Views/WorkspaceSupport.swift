import Foundation
import PlayhouseAtoms
import PlayhouseCore
import PlayhouseUI

package struct WorkspaceRootSelector: PHView {
    package let parentFolderURL: URL?
    @PHBinding package var roots: [URL]
    package var displayNames: [String: String] = [:]
    @PHState private var repositories: [URL] = []
    @PHState private var searchText = ""
    @PHState private var isScanning = false

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

    package var body: some PHView {
        PHVStack(alignment: .leading, spacing: 10) {
            PHHStack {
                PHText("Working folders")
                    .font(.system(size: 13, weight: .semibold))
                PHSpacer()
                PHButton(action: browseForFolders) {
                    PHLabel("Browse…", icon: .folder)
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonHoverPointer()
                .nativeHelp("Browse folders")
                .buttonStyle(.bordered)
                .accessibilityIdentifier("browse-workspace-roots-button")
            }

            if roots.isEmpty {
                PHText("Choose one or more folders. Git repositories under your parent folder appear as suggestions.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                FlowLayout(spacing: 7) {
                    PHForEach(roots, id: \.standardizedFileURL.path) { root in
                        PHHStack(spacing: 5) {
                            PHImage(icon: .folderFill)
                                .font(.system(size: 10))
                            PHText(displayNames[root.standardizedFileURL.path] ?? (root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent))
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                            PHButton {
                                roots.removeAll { $0.standardizedFileURL.path == root.standardizedFileURL.path }
                            } label: {
                                PHImage(icon: .xmarkCircleFill)
                                    .font(.system(size: 11))
                            }
                            .plainButtonHoverPointer()
                            .buttonStyle(.plain)
                            .nativeHelp("Remove \(displayNames[root.standardizedFileURL.path] ?? root.path)")
                            .accessibilityLabel("Remove \(displayNames[root.standardizedFileURL.path] ?? root.lastPathComponent)")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(PHColor.accentColor.opacity(0.1), in: PHCapsule())
                    }
                }
            }

            PHTextField("Search suggested repositories…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("workspace-repository-search")

            if isScanning {
                PHProgressView("Finding Git repositories…")
                    .controlSize(.small)
                    .font(.system(size: 11))
            } else if filteredRepositories.isEmpty {
                PHText(parentFolderURL == nil ? "Choose a default parent folder in Settings to see repository suggestions." : "No matching repositories. Browse to add any folder.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                PHScrollView {
                    PHLazyVStack(spacing: 1) {
                        PHForEach(filteredRepositories, id: \.path) { repository in
                            PHButton {
                                add(repository)
                            } label: {
                                PHVStack(alignment: .leading, spacing: 2) {
                                    PHText(repository.lastPathComponent)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.primary)
                                    PHText(repository.path)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 7)
                                .contentShape(PHRectangle())
                            }
                            .plainButtonHoverPointer()
                            .nativeHelp("Add repository \(repository.lastPathComponent)")
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("repository-suggestion-\(repository.lastPathComponent)")
                        }
                    }
                    .hoverRevealScrollers()
                }
                .frame(maxHeight: 142)
                .background(WorkspaceTheme.panelBackground.opacity(0.5), in: PHRoundedRectangle(cornerRadius: 8))
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
        let request = FileChooserRequest(
            title: "Choose working folders", message: "Choose one or more folders Codex should use as task context.",
            prompt: "Add Folders", choosesFiles: false, choosesDirectories: true, allowsMultipleSelection: true,
            startingDirectory: parentFolderURL
        )
        Platform.services.chooseFiles(request) { urls in
            guard let urls else { return }
            DispatchQueue.main.async {
                urls.forEach(add)
            }
        }
    }

    package init(parentFolderURL: URL?, roots: PHBinding<[URL]>, displayNames: [String: String] = [:]) {
        self.parentFolderURL = parentFolderURL
        _roots = roots
        self.displayNames = displayNames
    }
}

package struct FlowLayout: PHLayout {
    package var spacing: CGFloat = 8

    package func sizeThatFits(proposal: PHProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
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

    package func placeSubviews(in bounds: CGRect, proposal: PHProposedViewSize, subviews: Subviews, cache: inout ()) {
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
            subview.place(at: CGPoint(x: x, y: y), proposal: PHProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }

    package init(spacing: CGFloat = 8) {
        self.spacing = spacing
    }
}
