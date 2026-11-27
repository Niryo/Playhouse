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
        AtomStack(props: StackProps(spacing: 10, align: "leading")) {
            AtomStack(props: StackProps(axis: "h")) {
                AtomText(props: TextProps(text: "Working folders", size: 13, weight: "semibold"))
                AtomSpacer()
                AtomButton(
                    props: ButtonProps(style: "bordered"),
                    common: AtomCommon(testID: "browse-workspace-roots-button", help: "Browse folders"),
                    action: browseForFolders
                ) {
                    AtomLabel(props: LabelProps(text: "Browse…", icon: PHIcon.folder.name, size: 12, weight: "medium"))
                }
            }

            if roots.isEmpty {
                AtomText(props: TextProps(
                    text: "Choose one or more folders. Git repositories under your parent folder appear as suggestions.",
                    size: 11, color: "secondary", wrap: true
                ))
            } else {
                FlowLayout(spacing: 7) {
                    PHForEach(roots, id: \.standardizedFileURL.path) { root in
                        rootChip(root)
                    }
                }
            }

            AtomTextField(
                props: TextFieldProps(text: searchText, placeholder: "Search suggested repositories…"),
                common: AtomCommon(testID: "workspace-repository-search"),
                onChange: { searchText = $0 }
            )

            if isScanning {
                // A small spinner over its title, as a titled native progress view shows.
                AtomStack {
                    AtomSpinner(props: SpinnerProps(size: "small"))
                    AtomText(props: TextProps(text: "Finding Git repositories…", size: 11, color: "secondary"))
                }
            } else if filteredRepositories.isEmpty {
                AtomText(props: TextProps(
                    text: parentFolderURL == nil ? "Choose a default parent folder in Settings to see repository suggestions." : "No matching repositories. Browse to add any folder.",
                    size: 11, color: "secondary"
                ))
            } else {
                AtomStack(props: StackProps(fill: "panel", fillOpacity: 0.5, cornerRadius: 8)) {
                    AtomScroll(props: ScrollProps(spacing: 1, maxHeight: 142, lazy: true)) {
                        PHForEach(filteredRepositories, id: \.path) { repository in
                            suggestionRow(repository)
                        }
                    }
                }
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

    private func displayName(_ root: URL) -> String? {
        displayNames[root.standardizedFileURL.path]
    }

    private func rootChip(_ root: URL) -> some PHView {
        AtomStack(props: StackProps(axis: "h", spacing: 5, fill: "accent", fillOpacity: 0.1, capsule: true), common: AtomCommon(paddingX: 8, paddingY: 5)) {
            AtomIcon(props: IconProps(name: PHIcon.folderFill.name, size: 10))
            AtomText(props: TextProps(
                text: displayName(root) ?? (root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent),
                size: 11, weight: "medium", lineLimit: 1
            ))
            AtomButton(
                common: AtomCommon(label: "Remove \(displayName(root) ?? root.lastPathComponent)", help: "Remove \(displayName(root) ?? root.path)"),
                action: { roots.removeAll { $0.standardizedFileURL.path == root.standardizedFileURL.path } }
            ) {
                AtomIcon(props: IconProps(name: PHIcon.xmarkCircleFill.name, size: 11))
            }
        }
    }

    private func suggestionRow(_ repository: URL) -> some PHView {
        AtomButton(
            common: AtomCommon(
                testID: "repository-suggestion-\(repository.lastPathComponent)", help: "Add repository \(repository.lastPathComponent)",
                fillWidth: true, paddingX: 9, paddingY: 7
            ),
            action: { add(repository) }
        ) {
            AtomStack(props: StackProps(spacing: 2, align: "leading")) {
                AtomText(props: TextProps(text: repository.lastPathComponent, size: 12, weight: "medium", color: "primary"))
                AtomText(props: TextProps(text: repository.path, size: 10, color: "secondary", lineLimit: 1))
            }
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
