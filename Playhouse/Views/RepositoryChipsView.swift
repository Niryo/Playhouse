import Foundation
import PlayhouseAtoms
import PlayhouseCore
import PlayhouseUI

/// What the task header's repository chips show: plain values the native
/// chips and the catalog's JavaScript copy (catalog/RepositoryChips.js, as
/// `Playhouse.props.repositoryChips`) compose the same way. `prefix` starts
/// every accessibility identifier ("" in the header).
package struct RepositoryChipsModel: Codable, Equatable {
    package struct Chip: Codable, Equatable {
        /// The repository folder's name, which its identifiers end with; with the
        /// branch appended when the task has several worktrees of the repository.
        package var name: String
        /// The source repository's path.
        package var path: String
        /// The worktree the chip stands for, which its actions name; the path when absent.
        package var key: String?
        /// Shown beside the name when the task has several worktrees of the repository.
        package var branch: String?

        package var id: String { key ?? path }
        /// The repository folder's name, the chip's text.
        package var title: String { URL(fileURLWithPath: path).lastPathComponent }

        package init(name: String, path: String, key: String? = nil, branch: String? = nil) {
            self.name = name
            self.path = path
            self.key = key
            self.branch = branch
        }
    }

    package var prefix: String
    package var chips: [Chip]
    /// The branch icon's color, the workspace accent as #RRGGBB.
    package var accent: String
    /// The task can't change its repositories: the chips and Add are
    /// disabled and the remove badges hidden.
    package var readOnly: Bool

    package init(prefix: String, chips: [Chip], accent: String, readOnly: Bool) {
        self.prefix = prefix
        self.chips = chips
        self.accent = accent
        self.readOnly = readOnly
    }
}

extension RepositoryChipsModel {
    /// A chip per worktree. A repository the task has once keeps the chip and
    /// identifiers it always had; several worktrees of one repository each show
    /// their branch and end their identifiers with it.
    package init(records: [RepositoryWorktreeRecord], readOnly: Bool) {
        prefix = ""
        let counts = Dictionary(grouping: records, by: \.repositoryPath).mapValues(\.count)
        chips = records.indices.map { index in
            let record = records[index]
            let name = URL(fileURLWithPath: record.repositoryPath).lastPathComponent
            guard (counts[record.repositoryPath] ?? 0) > 1 else {
                return Chip(name: name, path: record.repositoryPath, key: records.chipKey(at: index))
            }
            return Chip(name: "\(name)-\(record.branch)", path: record.repositoryPath, key: records.chipKey(at: index), branch: record.branch)
        }
        accent = AtomColor.hex(WorkspaceTheme.accent)
        self.readOnly = readOnly
    }
}

extension Array where Element == RepositoryWorktreeRecord {
    /// What a header chip names its worktree by: the worktree's path once it is
    /// created, else the repository and the record's place among that
    /// repository's pending records, which a branch edit doesn't change.
    package func chipKey(at index: Int) -> String {
        let record = self[index]
        guard record.isPending else { return record.worktreePath }
        let ordinal = self[..<index].filter { $0.isPending && $0.repositoryPath == record.repositoryPath }.count
        return "\(record.repositoryPath)#\(ordinal)"
    }

    package func chipKey(of record: RepositoryWorktreeRecord) -> String? {
        firstIndex { $0.isSameWorktree(as: record) }.map(chipKey(at:))
    }

    package func record(chipKey key: String) -> RepositoryWorktreeRecord? {
        indices.first { chipKey(at: $0) == key }.map { self[$0] }
    }
}

/// What the Add repository picker (the hint under the header's + button)
/// shows, already derived from the suggestion folder, the recent and
/// suggested repositories and the search.
package struct RepositoryPickerModel: Codable, Equatable {
    package struct Repository: Codable, Equatable {
        package var name: String
        package var path: String

        package init(name: String, path: String) {
            self.name = name
            self.path = path
        }
    }

    package var prefix: String
    /// The folder suggestions come from; nil until one is chosen.
    package var parentFolder: String?
    /// Its open panel is showing, so its button is disabled.
    package var isChoosingParent: Bool
    package var placeholder: String
    package var search: String
    /// recent (nothing typed yet) or suggestion: the list's header and its
    /// rows' identifiers.
    package var listing: String
    /// The list, or its empty text, shows; a search without a suggestion
    /// folder has nothing to list.
    package var showsList: Bool
    package var repositories: [Repository]
    /// The list's height: a row is about 42 points, and the list scrolls past 180.
    package var listHeight: Double
    /// The row Return adds, moved by the arrows.
    package var highlighted: Int
    /// The search takes the keyboard focus when the picker opens (a new task).
    package var focusesSearch: Bool
    /// Return adds something: the saved repositories or the highlighted row.
    package var canSubmit: Bool
    /// The task already has repositories, so each row offers Replace.
    package var canReplace: Bool

    package init(prefix: String, parentFolder: String? = nil, isChoosingParent: Bool, placeholder: String, search: String, listing: String, showsList: Bool, repositories: [Repository], listHeight: Double, highlighted: Int, focusesSearch: Bool, canSubmit: Bool, canReplace: Bool) {
        self.prefix = prefix
        self.parentFolder = parentFolder
        self.isChoosingParent = isChoosingParent
        self.placeholder = placeholder
        self.search = search
        self.listing = listing
        self.showsList = showsList
        self.repositories = repositories
        self.listHeight = listHeight
        self.highlighted = highlighted
        self.focusesSearch = focusesSearch
        self.canSubmit = canSubmit
        self.canReplace = canReplace
    }
}

extension RepositoryPickerModel {
    package init(
        parentFolder: String?, isChoosingParent: Bool, placeholder: String, search: String, isListingRecent: Bool,
        repositories: [URL], highlighted: Int, focusesSearch: Bool, canSubmit: Bool, canReplace: Bool
    ) {
        prefix = ""
        self.parentFolder = parentFolder
        self.isChoosingParent = isChoosingParent
        self.placeholder = placeholder
        self.search = search
        listing = isListingRecent ? "recent" : "suggestion"
        showsList = isListingRecent || parentFolder != nil
        self.repositories = repositories.map { Repository(name: $0.lastPathComponent, path: $0.path) }
        listHeight = min(Double(repositories.count * 42), 180)
        self.highlighted = highlighted
        self.focusesSearch = focusesSearch
        self.canSubmit = canSubmit
        self.canReplace = canReplace
    }
}

/// What the chips do; each chip's actions name its `Chip.id`.
package struct RepositoryChipsActions {
    /// Opens the chip's settings.
    package var edit: (String) -> Void = { _ in }
    package var remove: (String) -> Void = { _ in }
    /// The + button: opens or closes the picker.
    package var add: () -> Void = {}

    package init(edit: @escaping (String) -> Void = { _ in }, remove: @escaping (String) -> Void = { _ in }, add: @escaping () -> Void = {}) {
        self.edit = edit
        self.remove = remove
        self.add = add
    }
}

/// What the picker's controls do. `select` names the row's path; `arrow`
/// is "up" or "down".
package struct RepositoryPickerActions {
    package var chooseParent: () -> Void = {}
    package var search: (String) -> Void = { _ in }
    package var arrow: (String) -> Void = { _ in }
    package var submit: () -> Void = {}
    /// The row or its + button: adds the repository next to the others.
    package var select: (String) -> Void = { _ in }
    /// Removes every selected repository and adds this one.
    package var replace: (String) -> Void = { _ in }

    package init(chooseParent: @escaping () -> Void = {}, search: @escaping (String) -> Void = { _ in }, arrow: @escaping (String) -> Void = { _ in }, submit: @escaping () -> Void = {}, select: @escaping (String) -> Void = { _ in }, replace: @escaping (String) -> Void = { _ in }) {
        self.chooseParent = chooseParent
        self.search = search
        self.arrow = arrow
        self.submit = submit
        self.select = select
        self.replace = replace
    }
}

/// The task header's repository chips and their + button, composed only of
/// plugin atoms. The header presents the picker from the + button
/// (`picker`) and a chip's settings from that chip (`settings`); both stay
/// native presentations, like the board's Token Stats sheet. Without them
/// (the catalog) nothing is presented.
package struct RepositoryChipsView<PHPicker: PHView, Settings: PHView>: PHView {
    package let model: RepositoryChipsModel
    package var actions = RepositoryChipsActions()
    package var isPickerPresented: PHBinding<Bool> = .constant(false)
    /// The `Chip.id` of the chip whose settings are open.
    package var editingPath: PHBinding<String?> = .constant(nil)
    /// The + button's keyboard shortcut: the task header's; the catalog's copy takes none.
    package var addShortcut: String? = nil
    @PHViewBuilder package var picker: () -> PHPicker
    @PHViewBuilder package var settings: (RepositoryChipsModel.Chip) -> Settings

    private var prefix: String { model.prefix }

    package var body: some PHView {
        AtomStack(props: StackProps(axis: "h", spacing: 10)) {
            PHForEach(model.chips, id: \.id) { chip($0) }
            AtomButton(
                props: ButtonProps(disabled: model.readOnly, shortcut: addShortcut),
                common: AtomCommon(testID: "\(prefix)add-conversation-repository-button", label: "Add repository", help: "Add a repository"),
                action: actions.add
            ) {
                AtomPanel(props: PanelProps(fillOpacity: 0.07, capsule: true), common: AtomCommon(width: 28, height: 28, padding: 0)) {
                    AtomIcon(props: IconProps(name: PHIcon.plus.name, size: 12, weight: "semibold"))
                }
            }
            .popover(isPresented: isPickerPresented, arrowEdge: .bottom, content: picker)
        }
    }

    private func chip(_ chip: RepositoryChipsModel.Chip) -> some PHView {
        let name = chip.name
        return AtomOverlay(props: OverlayProps(align: "topTrailing", offsetX: 6, offsetY: -6)) {
            AtomButton(
                props: ButtonProps(disabled: model.readOnly),
                common: AtomCommon(testID: "\(prefix)conversation-repository-badge-\(name)", help: "Edit repository settings for \(name)"),
                action: { actions.edit(chip.id) }
            ) {
                AtomPanel(
                    props: PanelProps(fill: "primary", fillOpacity: 0.08, capsule: true, stroke: "primary", strokeOpacity: 0.14),
                    common: AtomCommon(padding: 7, paddingX: 5.5)
                ) {
                    AtomStack(props: StackProps(axis: "h", spacing: 6)) {
                        AtomIcon(props: IconProps(name: PHIcon.arrowTriangleBranch.name, size: 11, weight: "semibold", color: model.accent))
                        AtomText(props: TextProps(text: chip.branch == nil ? name : chip.title, size: 13, weight: "semibold", color: "primary", lineLimit: 1))
                        if let branch = chip.branch {
                            AtomText(props: TextProps(text: branch, size: 11, color: "secondary", lineLimit: 1, truncation: "middle"))
                        }
                    }
                }
            }
            .popover(isPresented: PHBinding(
                get: { editingPath.wrappedValue == chip.id },
                // Opening another chip's settings closes this one; only this chip's own dismissal clears it.
                set: { if !$0, editingPath.wrappedValue == chip.id { editingPath.wrappedValue = nil } }
            )) {
                settings(chip)
            }
        } overlay: {
            if !model.readOnly {
                AtomButton(
                    common: AtomCommon(testID: "\(prefix)remove-conversation-repository-\(name)", label: "Remove \(name)", help: "Remove \(name) from this task"),
                    action: { actions.remove(chip.id) }
                ) {
                    AtomPanel(
                        props: PanelProps(fill: "panel", fillOpacity: 1, capsule: true, stroke: "primary", strokeOpacity: 0.16),
                        common: AtomCommon(width: 20, height: 20, padding: 0)
                    ) {
                        AtomIcon(props: IconProps(name: PHIcon.xmark.name, size: 9, weight: "bold", color: "secondary"))
                    }
                }
            }
        }
    }

    package init(model: RepositoryChipsModel, actions: RepositoryChipsActions = RepositoryChipsActions(), isPickerPresented: PHBinding<Bool> = .constant(false), editingPath: PHBinding<String?> = .constant(nil), addShortcut: String? = nil, @PHViewBuilder picker: @escaping () -> PHPicker, @PHViewBuilder settings: @escaping (RepositoryChipsModel.Chip) -> Settings) {
        self.model = model
        self.actions = actions
        self.isPickerPresented = isPickerPresented
        self.editingPath = editingPath
        self.addShortcut = addShortcut
        self.picker = picker
        self.settings = settings
    }
}

extension RepositoryChipsView where PHPicker == PHEmptyView, Settings == PHEmptyView {
    /// Chips that present nothing (the catalog's native copy).
    package init(model: RepositoryChipsModel, actions: RepositoryChipsActions) {
        self.init(model: model, actions: actions, picker: { PHEmptyView() }, settings: { _ in PHEmptyView() })
    }
}

/// The Add repository picker, the hint the + button opens, composed only of
/// plugin atoms: where suggestions come from and its Change… button (or a
/// prompt to choose that folder), the search, then the recent repositories
/// before anything is typed, or the matching suggestions, one row each.
package struct RepositoryPickerView: PHView {
    package let model: RepositoryPickerModel
    package var actions = RepositoryPickerActions()

    private var prefix: String { model.prefix }

    package var body: some PHView {
        AtomStack(props: StackProps(axis: "v", spacing: 8, align: "leading", group: true), common:AtomCommon(testID: "\(prefix)conversation-repository-picker", width: 280, padding: 12)) {
            if let parent = model.parentFolder {
                AtomStack(props: StackProps(axis: "h", spacing: 5)) {
                    AtomText(
                        props: TextProps(text: "Suggestions from \(parent)", size: 10, color: "secondary", lineLimit: 1, truncation: "middle"),
                        common: AtomCommon(testID: "\(prefix)conversation-repository-suggestion-parent", help: parent)
                    )
                    AtomSpacer(props: SpacerProps(minLength: 0))
                    chooseParentButton("Change…", help: "Choose a different repository suggestion folder")
                }
            } else {
                AtomText(props: TextProps(text: "Choose a parent folder to find Git repositories.", size: 10, color: "secondary"))
                chooseParentButton("Choose suggestion folder…", help: "Choose a folder to find repository suggestions")
            }
            AtomTextField(
                props: TextFieldProps(text: model.search, placeholder: model.placeholder, autoFocus: model.focusesSearch),
                common: AtomCommon(testID: "\(prefix)conversation-repository-search"),
                onChange: actions.search,
                onSubmit: model.canSubmit ? actions.submit : nil,
                onArrow: model.repositories.isEmpty ? nil : actions.arrow
            )
            if model.listing == "recent" {
                AtomText(props: TextProps(text: "Recent", size: 10, weight: "semibold", color: "secondary"), common: AtomCommon(testID: "\(prefix)conversation-repository-recent-header"))
            }
            if model.showsList {
                if model.repositories.isEmpty {
                    AtomText(props: TextProps(text: "No matching repositories.", size: 10, color: "secondary"), common: AtomCommon(testID: "\(prefix)conversation-repository-empty"))
                } else {
                    AtomScroll(props: ScrollProps(spacing: 2, lazy: true), common: AtomCommon(testID: "\(prefix)conversation-repository-list", width: 280, height: model.listHeight)) {
                        PHForEach(Array(model.repositories.enumerated()), id: \.element.path) { index, repository in
                            row(repository, highlighted: index == model.highlighted)
                        }
                    }
                }
            }
        }
    }

    private func chooseParentButton(_ title: String, help: String) -> some PHView {
        AtomButton(
            props: ButtonProps(style: "automatic", disabled: model.isChoosingParent),
            common: AtomCommon(testID: "\(prefix)choose-repository-suggestion-parent-button", help: help),
            action: actions.chooseParent
        ) {
            AtomText(props: TextProps(text: title, size: 10, color: "secondary"))
        }
    }

    private func row(_ repository: RepositoryPickerModel.Repository, highlighted: Bool) -> some PHView {
        let id = "\(prefix)conversation-repository-\(model.listing)-\(repository.name)"
        // The inset keeps the buttons clear of the list's overlay scroller.
        return AtomOverlay(props: OverlayProps(align: "trailing", offsetX: -16, revealOnHover: true)) {
            AtomButton(
                common: AtomCommon(testID: id, help: "Add \(repository.name) alongside the selected repositories"),
                action: { actions.select(repository.path) }
            ) {
                AtomPanel(
                    props: PanelProps(fill: "accent", fillOpacity: highlighted ? 0.16 : 0, cornerRadius: 5),
                    common: AtomCommon(fillWidth: true, padding: 7)
                ) {
                    // The spacer keeps the text clear of the buttons the hover reveals.
                    AtomStack(props: StackProps(axis: "h", spacing: 0)) {
                        AtomStack(props: StackProps(axis: "v", spacing: 2, align: "leading")) {
                            AtomText(props: TextProps(text: repository.name, size: 11, weight: "medium"))
                            AtomText(props: TextProps(text: repository.path, size: 9, color: "secondary", lineLimit: 1))
                        }
                        AtomSpacer(props: SpacerProps(minLength: 64))
                    }
                }
            }
        } overlay: {
            AtomStack(props: StackProps(axis: "h", spacing: 2)) {
                if model.canReplace {
                    AtomButton(
                        props: ButtonProps(emphasis: 4),
                        common: AtomCommon(testID: "\(id)-replace", label: "Replace with \(repository.name)", help: "Replace the selected repositories with \(repository.name)"),
                        action: { actions.replace(repository.path) }
                    ) {
                        AtomIcon(props: IconProps(name: PHIcon.repeat.name, size: 11, weight: "semibold", color: "secondary"))
                    }
                }
                AtomButton(
                    props: ButtonProps(emphasis: 4),
                    common: AtomCommon(testID: "\(id)-add", label: "Add \(repository.name)", help: "Add \(repository.name) alongside the selected repositories"),
                    action: { actions.select(repository.path) }
                ) {
                    AtomIcon(props: IconProps(name: PHIcon.plus.name, size: 11, weight: "semibold", color: "secondary"))
                }
            }
        }
    }

    package init(model: RepositoryPickerModel, actions: RepositoryPickerActions = RepositoryPickerActions()) {
        self.model = model
        self.actions = actions
    }
}
