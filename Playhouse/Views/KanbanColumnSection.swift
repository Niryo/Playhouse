import Foundation
import PlayhouseAtoms
import PlayhouseCore
import PlayhouseUI

/// What a board column shows around its cards, already derived from its
/// status and task count: plain values the native column and the catalog's
/// JavaScript copy (catalog/KanbanColumn.js, as `Playhouse.props.kanbanColumn`)
/// compose the same way. `idPrefix` is empty on the board; the catalog's
/// native copy sets one so the two sides never share accessibility identifiers.
package struct KanbanColumnModel: Codable, Equatable {
    /// What a column with no cards shows instead of them.
    package struct Empty: Codable, Equatable {
        package var icon: String
        package var title: String
        package var hint: String
        /// The title of the pulsing Add button it shows instead of the
        /// header's, so an empty Backlog points at creating a task.
        package var action: String?

        package init(icon: String, title: String, hint: String, action: String? = nil) {
            self.icon = icon
            self.title = title
            self.hint = hint
            self.action = action
        }
    }

    package var idPrefix: String
    /// The status's accessibility key ("in-progress").
    package var key: String
    /// The uppercased status name.
    package var title: String
    /// The status color, as #RRGGBB.
    package var accent: String
    package var count: String
    /// The Add button's help; only the Backlog has one, in its header while
    /// it has tasks and in its empty state (`Empty.action`) while it has none.
    package var addHelp: String?
    /// The red line under the header (the Blocked column's).
    package var notice: String?
    /// The color, as #RRGGBB, washing the whole column and its count so it
    /// stands out on the board (the Waiting Response column's accent).
    package var tint: String?
    package var empty: Empty?

    package init(status: TaskStatus, taskCount: Int, idPrefix: String = "") {
        self.idPrefix = idPrefix
        key = status.accessibilityKey
        title = status.rawValue.uppercased()
        accent = AtomColor.hex(status.accent)
        count = "\(taskCount)"
        addHelp = status == .backlog ? "Add task to Backlog" : nil
        notice = status == .blocked ? "Waiting for user intervention" : nil
        tint = status == .waitingResponse ? accent : nil
        empty = taskCount > 0 ? nil : Empty(
            icon: status == .done ? PHIcon.checkmarkCircle.name : "tray",
            title: "No tasks yet",
            hint: status == .backlog ? "Create a task to get started" : "Drop a task here",
            action: status == .backlog ? "New Task" : nil
        )
    }
}

/// A board column's frame, composed only of plugin atoms (Plugins/Atoms), so a
/// plugin building it from the same atoms looks identical: a Panel holding the
/// header (status dot, title, count, the Backlog's Add button), the Blocked
/// notice, then the cards or the empty state; an empty Backlog moves its Add
/// button, pulsing, into the empty state. A tinted column lays a second
/// Panel in its tint (a soft wash and hairline border) over the first. The
/// cards are native (`TaskCardView`) and arrive through `cards`.
package struct KanbanColumnSection<Cards: PHView>: PHView {
    package let model: KanbanColumnModel
    package let minHeight: Double
    /// The panel's own accessibility identifier; the board's column view
    /// supplies the column's, so it passes none.
    package var testID: String?
    package var onAdd: () -> Void = {}
    @PHViewBuilder package var cards: () -> Cards

    private var prefix: String { model.idPrefix }

    package var body: some PHView {
        if let tint = model.tint {
            AtomPanel(
                props: PanelProps(fill: "panel", fillOpacity: 0.78, cornerRadius: 16),
                common: AtomCommon(testID: testID, minHeight: minHeight, fillWidth: true, padding: 0)
            ) {
                AtomPanel(
                    props: PanelProps(spacing: 13, fill: tint, fillOpacity: 0.12, cornerRadius: 16, stroke: tint, strokeOpacity: 0.34),
                    common: AtomCommon(minHeight: minHeight, fillWidth: true, padding: 14)
                ) {
                    content
                }
            }
        } else {
            AtomPanel(
                props: PanelProps(spacing: 13, fill: "panel", fillOpacity: 0.78, cornerRadius: 16, stroke: "primary", strokeOpacity: 0.075),
                common: AtomCommon(testID: testID, minHeight: minHeight, fillWidth: true, padding: 14)
            ) {
                content
            }
        }
    }

    @PHViewBuilder
    private var content: some PHView {
        header
        if let notice = model.notice {
            AtomLabel(
                props: LabelProps(text: notice, icon: PHIcon.handRaisedFill.name, size: 10, weight: "semibold", color: "red"),
                common: AtomCommon(testID: "\(prefix)blocked-waiting-indicator", paddingX: 3)
            )
        }
        if let empty = model.empty {
            emptyState(empty)
        } else {
            cards()
        }
    }

    private var header: some PHView {
        AtomStack(props: StackProps(axis: "h", spacing: 9), common: AtomCommon(paddingX: 3)) {
            AtomPanel(props: PanelProps(fill: model.accent, fillOpacity: 1, cornerRadius: 4), common: AtomCommon(width: 8, height: 8, padding: 0)) {}
            AtomText(
                props: TextProps(text: model.title, size: 11, weight: "bold", design: "rounded", color: "primary", tracking: 0.65),
                common: AtomCommon(testID: "\(prefix)column-heading-\(model.key)")
            )
            AtomSpacer(props: SpacerProps(minLength: 4))
            AtomPanel(props: PanelProps(fill: model.tint, fillOpacity: model.tint == nil ? 0.055 : 0.16, cornerRadius: 100), common: AtomCommon(padding: 3, paddingX: 4)) {
                AtomText(
                    props: TextProps(text: model.count, size: 11, weight: "semibold", design: "rounded", color: model.tint ?? "secondary"),
                    common: AtomCommon(testID: "\(prefix)column-count-\(model.key)")
                )
            }
            if let help = model.addHelp, model.empty?.action == nil {
                AtomButton(
                    props: ButtonProps(style: "bordered", controlSize: "small"),
                    common: AtomCommon(testID: "\(prefix)add-backlog-task-button", label: help, help: help),
                    action: onAdd
                ) {
                    AtomIcon(props: IconProps(name: PHIcon.plus.name, size: 11, weight: "semibold"))
                }
            }
        }
    }

    @PHViewBuilder
    private func emptyState(_ empty: KanbanColumnModel.Empty) -> some PHView {
        if let action = empty.action, let help = model.addHelp {
            // One container, so the button stays its own element beside the
            // message, which reads as the panel's label.
            AtomPanel(
                props: PanelProps(spacing: 12, fillOpacity: 0, cornerRadius: 12, stroke: "primary", strokeOpacity: 0.10, dash: [5, 4], align: "center"),
                common: AtomCommon(testID: "\(prefix)empty-state-\(model.key)", label: "\(empty.title), \(empty.hint)", minHeight: 124, fillWidth: true, padding: 0)
            ) {
                AtomStack(props: StackProps(axis: "v", spacing: 9, align: "center")) {
                    emptyMessage(empty)
                }
                AtomButton(
                    props: ButtonProps(style: "prominent", controlSize: "small"),
                    common: AtomCommon(testID: "\(prefix)add-backlog-task-button", label: help, help: help),
                    action: onAdd
                ) {
                    AtomLabel(props: LabelProps(text: action, icon: PHIcon.plus.name, size: 11, weight: "semibold"))
                }
            }
        } else {
            AtomPanel(
                props: PanelProps(spacing: 9, fillOpacity: 0, cornerRadius: 12, stroke: "primary", strokeOpacity: 0.10, dash: [5, 4], align: "center", combine: true),
                common: AtomCommon(testID: "\(prefix)empty-state-\(model.key)", minHeight: 124, fillWidth: true, padding: 0)
            ) {
                emptyMessage(empty)
            }
        }
    }

    @PHViewBuilder
    private func emptyMessage(_ empty: KanbanColumnModel.Empty) -> some PHView {
        AtomIcon(props: IconProps(name: empty.icon, size: 18, weight: "regular", color: model.accent))
        AtomText(props: TextProps(text: empty.title, size: 12, weight: "medium", color: "secondary"))
        AtomText(props: TextProps(text: empty.hint, size: 11, color: "tertiary"))
    }

    package init(model: KanbanColumnModel, minHeight: Double, testID: String? = nil, onAdd: @escaping () -> Void = {}, @PHViewBuilder cards: @escaping () -> Cards) {
        self.model = model
        self.minHeight = minHeight
        self.testID = testID
        self.cards = cards
        self.onAdd = onAdd
    }
}
