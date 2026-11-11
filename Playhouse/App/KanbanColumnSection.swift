import SwiftUI

/// What a board column shows around its cards, already derived from its
/// status and task count: plain values the native column and the catalog's
/// JavaScript copy (catalog/KanbanColumn.js, as `Playhouse.props.kanbanColumn`)
/// compose the same way. `idPrefix` is empty on the board; the catalog's
/// native copy sets one so the two sides never share accessibility identifiers.
struct KanbanColumnModel: Codable, Equatable {
    /// What a column with no cards shows instead of them.
    struct Empty: Codable, Equatable {
        var icon: String
        var title: String
        var hint: String
    }

    var idPrefix: String
    /// The status's accessibility key ("in-progress").
    var key: String
    /// The uppercased status name.
    var title: String
    /// The status color, as #RRGGBB.
    var accent: String
    var count: String
    /// The Add button's help; only the Backlog has one.
    var addHelp: String?
    /// The red line under the header (the Blocked column's).
    var notice: String?
    /// The color, as #RRGGBB, washing the whole column and its count so it
    /// stands out on the board (the Waiting Response column's accent).
    var tint: String?
    var empty: Empty?

    init(status: TaskStatus, taskCount: Int, idPrefix: String = "") {
        self.idPrefix = idPrefix
        key = status.accessibilityKey
        title = status.rawValue.uppercased()
        accent = AtomColor.hex(status.accent)
        count = "\(taskCount)"
        addHelp = status == .backlog ? "Add task to Backlog" : nil
        notice = status == .blocked ? "Waiting for user intervention" : nil
        tint = status == .waitingResponse ? accent : nil
        empty = taskCount > 0 ? nil : Empty(
            icon: status == .done ? "checkmark.circle" : "tray",
            title: "No tasks yet",
            hint: status == .backlog ? "Create a task to get started" : "Drop a task here"
        )
    }
}

/// A board column's frame, composed only of plugin atoms (Plugins/Atoms), so a
/// plugin building it from the same atoms looks identical: a Panel holding the
/// header (status dot, title, count, the Backlog's Add button), the Blocked
/// notice, then the cards or the empty state. A tinted column lays a second
/// Panel in its tint (a soft wash and hairline border) over the first. The
/// cards are native (`TaskCardView`) and arrive through `cards`.
struct KanbanColumnSection<Cards: View>: View {
    let model: KanbanColumnModel
    let minHeight: Double
    /// The panel's own accessibility identifier; the board's column view
    /// supplies the column's, so it passes none.
    var testID: String?
    var onAdd: () -> Void = {}
    @ViewBuilder var cards: () -> Cards

    private var prefix: String { model.idPrefix }

    var body: some View {
        if let tint = model.tint {
            AtomPanel(
                props: PanelProps(fill: "panel", fillOpacity: 0.78, cornerRadius: 16),
                common: AtomCommon(testID: testID, minHeight: minHeight, fillWidth: true)
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

    @ViewBuilder
    private var content: some View {
        header
        if let notice = model.notice {
            AtomLabel(
                props: LabelProps(text: notice, icon: "hand.raised.fill", size: 10, weight: "semibold", color: "red"),
                common: AtomCommon(testID: "\(prefix)blocked-waiting-indicator", paddingX: 3)
            )
        }
        if let empty = model.empty {
            emptyState(empty)
        } else {
            cards()
        }
    }

    private var header: some View {
        AtomStack(props: StackProps(axis: "h", spacing: 9), common: AtomCommon(paddingX: 3)) {
            AtomPanel(props: PanelProps(fill: model.accent, fillOpacity: 1, cornerRadius: 4), common: AtomCommon(width: 8, height: 8)) {}
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
            if let help = model.addHelp {
                AtomButton(
                    props: ButtonProps(style: "bordered", controlSize: "small"),
                    common: AtomCommon(testID: "\(prefix)add-backlog-task-button", label: help, help: help),
                    action: onAdd
                ) {
                    AtomIcon(props: IconProps(name: "plus", size: 11, weight: "semibold"))
                }
            }
        }
    }

    private func emptyState(_ empty: KanbanColumnModel.Empty) -> some View {
        AtomPanel(
            props: PanelProps(spacing: 9, fillOpacity: 0, cornerRadius: 12, stroke: "primary", strokeOpacity: 0.10, dash: [5, 4], align: "center", combine: true),
            common: AtomCommon(testID: "\(prefix)empty-state-\(model.key)", minHeight: 124, fillWidth: true)
        ) {
            AtomIcon(props: IconProps(name: empty.icon, size: 18, weight: "regular", color: model.accent))
            AtomText(props: TextProps(text: empty.title, size: 12, weight: "medium", color: "secondary"))
            AtomText(props: TextProps(text: empty.hint, size: 11, color: "tertiary"))
        }
    }
}
