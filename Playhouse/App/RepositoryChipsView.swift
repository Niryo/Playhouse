import SwiftUI

/// What the task header's repository chips show: plain values the native
/// chips and the catalog's JavaScript copy (catalog/RepositoryChips.js, as
/// `Playhouse.props.repositoryChips`) compose the same way. `prefix` starts
/// every accessibility identifier ("" in the header).
struct RepositoryChipsModel: Codable, Equatable {
    struct Chip: Codable, Equatable {
        /// The repository folder's name, which its identifiers end with.
        var name: String
        /// The source repository's path, which the chip's actions name.
        var path: String
    }

    var prefix: String
    var chips: [Chip]
    /// The branch icon's color, the workspace accent as #RRGGBB.
    var accent: String
    /// The task can't change its repositories: the chips and Add are
    /// disabled and the remove badges hidden.
    var readOnly: Bool
}

extension RepositoryChipsModel {
    init(repositoryPaths: [String], readOnly: Bool) {
        prefix = ""
        chips = repositoryPaths.map { Chip(name: URL(fileURLWithPath: $0).lastPathComponent, path: $0) }
        accent = AtomColor.hex(WorkspaceTheme.accent)
        self.readOnly = readOnly
    }
}

/// What the Add repository picker (the hint under the header's + button)
/// shows, already derived from the suggestion folder, the recent and
/// suggested repositories and the search.
struct RepositoryPickerModel: Codable, Equatable {
    struct Repository: Codable, Equatable {
        var name: String
        var path: String
    }

    var prefix: String
    /// The folder suggestions come from; nil until one is chosen.
    var parentFolder: String?
    /// Its open panel is showing, so its button is disabled.
    var isChoosingParent: Bool
    var placeholder: String
    var search: String
    /// recent (nothing typed yet) or suggestion: the list's header and its
    /// rows' identifiers.
    var listing: String
    /// The list, or its empty text, shows; a search without a suggestion
    /// folder has nothing to list.
    var showsList: Bool
    var repositories: [Repository]
    /// The list's height: a row is about 42 points, and the list scrolls past 180.
    var listHeight: Double
    /// The row Return adds, moved by the arrows.
    var highlighted: Int
    /// The search takes the keyboard focus when the picker opens (a new task).
    var focusesSearch: Bool
    /// Return adds something: the saved repositories or the highlighted row.
    var canSubmit: Bool
    /// The task already has repositories, so each row offers Replace.
    var canReplace: Bool
}

extension RepositoryPickerModel {
    init(
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

/// What the chips do; each chip's actions name its repository's path.
struct RepositoryChipsActions {
    /// Opens the chip's settings.
    var edit: (String) -> Void = { _ in }
    var remove: (String) -> Void = { _ in }
    /// The + button: opens or closes the picker.
    var add: () -> Void = {}
}

/// What the picker's controls do. `select` names the row's path; `arrow`
/// is "up" or "down".
struct RepositoryPickerActions {
    var chooseParent: () -> Void = {}
    var search: (String) -> Void = { _ in }
    var arrow: (String) -> Void = { _ in }
    var submit: () -> Void = {}
    /// The row or its + button: adds the repository next to the others.
    var select: (String) -> Void = { _ in }
    /// Removes every selected repository and adds this one.
    var replace: (String) -> Void = { _ in }
}

/// The task header's repository chips and their + button, composed only of
/// plugin atoms. The header presents the picker from the + button
/// (`picker`) and a chip's settings from that chip (`settings`); both stay
/// native presentations, like the board's Token Stats sheet. Without them
/// (the catalog) nothing is presented.
struct RepositoryChipsView<Picker: View, Settings: View>: View {
    let model: RepositoryChipsModel
    var actions = RepositoryChipsActions()
    var isPickerPresented: Binding<Bool> = .constant(false)
    /// The path of the chip whose settings are open.
    var editingPath: Binding<String?> = .constant(nil)
    @ViewBuilder var picker: () -> Picker
    @ViewBuilder var settings: (RepositoryChipsModel.Chip) -> Settings

    private var prefix: String { model.prefix }

    var body: some View {
        AtomStack(props: StackProps(axis: "h", spacing: 10)) {
            ForEach(model.chips, id: \.path) { chip($0) }
            AtomButton(
                props: ButtonProps(disabled: model.readOnly),
                common: AtomCommon(testID: "\(prefix)add-conversation-repository-button", label: "Add repository", help: "Add a repository"),
                action: actions.add
            ) {
                AtomPanel(props: PanelProps(fillOpacity: 0.07, capsule: true), common: AtomCommon(width: 28, height: 28, padding: 0)) {
                    AtomIcon(props: IconProps(name: "plus", size: 12, weight: "semibold"))
                }
            }
            .popover(isPresented: isPickerPresented, arrowEdge: .bottom, content: picker)
        }
    }

    private func chip(_ chip: RepositoryChipsModel.Chip) -> some View {
        let name = chip.name
        return AtomOverlay(props: OverlayProps(align: "topTrailing", offsetX: 6, offsetY: -6)) {
            AtomButton(
                props: ButtonProps(disabled: model.readOnly),
                common: AtomCommon(testID: "\(prefix)conversation-repository-badge-\(name)", help: "Edit repository settings for \(name)"),
                action: { actions.edit(chip.path) }
            ) {
                AtomPanel(
                    props: PanelProps(fill: "primary", fillOpacity: 0.08, capsule: true, stroke: "primary", strokeOpacity: 0.14),
                    common: AtomCommon(padding: 7, paddingX: 5.5)
                ) {
                    AtomStack(props: StackProps(axis: "h", spacing: 6)) {
                        AtomIcon(props: IconProps(name: "arrow.triangle.branch", size: 11, weight: "semibold", color: model.accent))
                        AtomText(props: TextProps(text: name, size: 13, weight: "semibold", color: "primary", lineLimit: 1))
                    }
                }
            }
            .popover(isPresented: Binding(
                get: { editingPath.wrappedValue == chip.path },
                // Opening another chip's settings closes this one; only this chip's own dismissal clears it.
                set: { if !$0, editingPath.wrappedValue == chip.path { editingPath.wrappedValue = nil } }
            )) {
                settings(chip)
            }
        } overlay: {
            if !model.readOnly {
                AtomButton(
                    common: AtomCommon(testID: "\(prefix)remove-conversation-repository-\(name)", label: "Remove \(name)", help: "Remove \(name) from this task"),
                    action: { actions.remove(chip.path) }
                ) {
                    AtomPanel(
                        props: PanelProps(fill: "panel", fillOpacity: 1, capsule: true, stroke: "primary", strokeOpacity: 0.16),
                        common: AtomCommon(width: 20, height: 20, padding: 0)
                    ) {
                        AtomIcon(props: IconProps(name: "xmark", size: 9, weight: "bold", color: "secondary"))
                    }
                }
            }
        }
    }
}

extension RepositoryChipsView where Picker == EmptyView, Settings == EmptyView {
    /// Chips that present nothing (the catalog's native copy).
    init(model: RepositoryChipsModel, actions: RepositoryChipsActions) {
        self.init(model: model, actions: actions, picker: { EmptyView() }, settings: { _ in EmptyView() })
    }
}

/// The Add repository picker, the hint the + button opens, composed only of
/// plugin atoms: where suggestions come from and its Change… button (or a
/// prompt to choose that folder), the search, then the recent repositories
/// before anything is typed, or the matching suggestions, one row each.
struct RepositoryPickerView: View {
    let model: RepositoryPickerModel
    var actions = RepositoryPickerActions()

    private var prefix: String { model.prefix }

    var body: some View {
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
                        ForEach(Array(model.repositories.enumerated()), id: \.element.path) { index, repository in
                            row(repository, highlighted: index == model.highlighted)
                        }
                    }
                }
            }
        }
    }

    private func chooseParentButton(_ title: String, help: String) -> some View {
        AtomButton(
            props: ButtonProps(style: "automatic", disabled: model.isChoosingParent),
            common: AtomCommon(testID: "\(prefix)choose-repository-suggestion-parent-button", help: help),
            action: actions.chooseParent
        ) {
            AtomText(props: TextProps(text: title, size: 10, color: "secondary"))
        }
    }

    private func row(_ repository: RepositoryPickerModel.Repository, highlighted: Bool) -> some View {
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
                        AtomIcon(props: IconProps(name: "repeat", size: 11, weight: "semibold", color: "secondary"))
                    }
                }
                AtomButton(
                    props: ButtonProps(emphasis: 4),
                    common: AtomCommon(testID: "\(id)-add", label: "Add \(repository.name)", help: "Add \(repository.name) alongside the selected repositories"),
                    action: { actions.select(repository.path) }
                ) {
                    AtomIcon(props: IconProps(name: "plus", size: 11, weight: "semibold", color: "secondary"))
                }
            }
        }
    }
}
