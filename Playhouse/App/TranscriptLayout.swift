import SwiftUI

/// Where every row of the conversation transcript sits, as `TranscriptLayout` last laid it out.
///
/// The layout writes it while SwiftUI lays the transcript out, before the scroll view's content
/// changes size, so `TranscriptScrollController` and `TranscriptVirtualizer` read positions that
/// belong to the same pass instead of measurements SwiftUI reports a pass later. It is a plain
/// reference outside SwiftUI state: writing it re-renders nothing.
final class TranscriptGeometry {
    struct Row {
        let id: String
        var top: CGFloat
        var height: CGFloat
    }

    private struct Measurement {
        var height: CGFloat
        var width: CGFloat
        /// What the row showed when measured. A message whose rows change while it is a box,
        /// such as by tool calls, a comment or a reload arriving, renders and measures again.
        var signature: Int
    }

    /// The message rows in transcript order, positioned from the top of the layout.
    private(set) var rows: [Row] = []
    /// Top of the row that starts the newest turn, when that row is rendered.
    private(set) var latestTurnTop: CGFloat?
    private(set) var width: CGFloat = 0
    private var indexByID: [String: Int] = [:]
    private var measurements: [String: Measurement] = [:]
    /// Called, outside the layout pass, after a row was measured for the first time or again
    /// with new content, which can change the rows worth rendering.
    var onMeasurementChange: (() -> Void)?

    func row(_ id: String) -> Row? {
        indexByID[id].map { rows[$0] }
    }

    /// The last row that starts at or above `y`, or the first row when `y` is above them all.
    func row(atOrAbove y: CGFloat) -> Row? {
        guard !rows.isEmpty else { return nil }
        var low = 0
        var high = rows.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if rows[middle].top <= y { low = middle } else { high = middle - 1 }
        }
        return rows[low]
    }

    func hasMeasurement(_ id: String, signature: Int) -> Bool {
        measurements[id]?.signature == signature
    }

    func isMeasured(_ id: String) -> Bool {
        measurements[id] != nil
    }

    /// The height a message takes while it is not rendered: the height it measured, scaled for a
    /// width change, since text grows taller roughly as its width shrinks.
    func boxHeight(_ id: String, width: CGFloat) -> CGFloat {
        guard let measurement = measurements[id] else { return 0 }
        guard width > 0, measurement.width > 0, abs(measurement.width - width) > 0.5 else { return measurement.height }
        return (measurement.height * measurement.width / width).rounded()
    }

    fileprivate func update(rows: [Row], latestTurnTop: CGFloat?, width: CGFloat) {
        self.rows = rows
        self.latestTurnTop = latestTurnTop
        self.width = width
        indexByID.removeAll(keepingCapacity: true)
        for (index, row) in rows.enumerated() { indexByID[row.id] = index }
        // Rows that left the transcript, as a reload's replaced messages do, keep no measurement.
        if measurements.count > rows.count { measurements = measurements.filter { indexByID[$0.key] != nil } }
    }

    fileprivate func record(_ id: String, height: CGFloat, width: CGFloat, signature: Int) {
        let previous = measurements[id]
        if let previous, abs(previous.height - height) < 0.5, abs(previous.width - width) < 0.5, previous.signature == signature { return }
        measurements[id] = Measurement(height: height, width: width, signature: signature)
        if previous == nil || previous?.signature != signature { onMeasurementChange?() }
    }
}

/// Identifies a message's rows to `TranscriptLayout`.
struct TranscriptRowValue: Equatable {
    var id: String
    /// A summary of what the rows show; see `TranscriptGeometry`.
    var signature: Int
    /// The message is not rendered: the layout gives it the height it last measured.
    var isBox: Bool
    /// The message starts the newest turn.
    var startsLatestTurn: Bool
}

struct TranscriptRowKey: LayoutValueKey {
    static let defaultValue: TranscriptRowValue? = nil
}

/// The transcript's one stack: a leading-aligned vertical stack of every row, from the oldest
/// rendered message to the rows that follow the newest one.
///
/// It records where each message sits in `geometry` as it lays out, sizes messages that are not
/// rendered from their last measurement, and keeps at least `minimumLatestTurnHeight` from the
/// top of the newest turn to the end of the transcript, adding the difference as blank space
/// below the last row. That filler lets a turn shorter than the viewport be scrolled to the top,
/// and makes that position exactly the bottom of the transcript, where following starts from.
struct TranscriptLayout: Layout {
    var spacing: CGFloat
    var minimumLatestTurnHeight: CGFloat
    let geometry: TranscriptGeometry

    private struct Measurement {
        var sizes: [CGSize] = []
        var tops: [CGFloat] = []
        var rows: [TranscriptGeometry.Row] = []
        var contentHeight: CGFloat = 0
        var latestTurnTop: CGFloat?
    }

    // Measured on every call rather than cached: a row that grows on its own, like an AppKit
    // text view, would otherwise leave a stale filler behind.
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let measurement = measure(width: proposal.width, subviews: subviews)
        // As wide as its widest row, as a leading-aligned VStack is.
        let width = measurement.sizes.map(\.width).max() ?? 0
        return CGSize(width: width, height: measurement.contentHeight + filler(for: measurement))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let measurement = measure(width: bounds.width, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: bounds.minX, y: bounds.minY + measurement.tops[index]),
                proposal: ProposedViewSize(width: bounds.width, height: measurement.sizes[index].height)
            )
            if let row = subview[TranscriptRowKey.self], !row.isBox {
                geometry.record(row.id, height: measurement.sizes[index].height, width: bounds.width, signature: row.signature)
            }
        }
    }

    private func filler(for measurement: Measurement) -> CGFloat {
        guard let top = measurement.latestTurnTop else { return 0 }
        return max(0, minimumLatestTurnHeight - (measurement.contentHeight - top))
    }

    private func measure(width: CGFloat?, subviews: Subviews) -> Measurement {
        var measurement = Measurement()
        measurement.sizes.reserveCapacity(subviews.count)
        measurement.tops.reserveCapacity(subviews.count)
        var y: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            if index > 0 { y += spacing }
            let row = subview[TranscriptRowKey.self]
            let size: CGSize
            if let row, row.isBox {
                size = CGSize(width: width ?? 0, height: geometry.boxHeight(row.id, width: width ?? 0))
            } else {
                size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            }
            if let row {
                if measurement.latestTurnTop == nil, row.startsLatestTurn { measurement.latestTurnTop = y }
                measurement.rows.append(TranscriptGeometry.Row(id: row.id, top: y, height: size.height))
            }
            measurement.sizes.append(size)
            measurement.tops.append(y)
            y += size.height
        }
        measurement.contentHeight = y
        // A proposal without a width only probes for an ideal size; it is not a layout.
        if let width, width > 0, width.isFinite {
            geometry.update(rows: measurement.rows, latestTurnTop: measurement.latestTurnTop, width: width)
        }
        return measurement
    }
}

/// Decides which messages of the transcript render as views. A message well away from the
/// viewport is a box of its measured height, so scrolling, hit testing and layout cost what is
/// near the screen rather than everything revealed so far.
@MainActor
@Observable
final class TranscriptVirtualizer {
    /// Measured messages that render as real views. Only the message rows read it, so changing
    /// it re-renders them alone.
    private(set) var realizedIDs: Set<String> = []
    @ObservationIgnored let geometry: TranscriptGeometry
    /// The viewport's top, measured from the top of the transcript layout.
    @ObservationIgnored private var offsetY: CGFloat?
    @ObservationIgnored private var viewportHeight: CGFloat = 0
    /// The span the realized rows were chosen for.
    @ObservationIgnored private var realizedSpan: ClosedRange<CGFloat>?
    @ObservationIgnored private var isRecomputeScheduled = false

    init(geometry: TranscriptGeometry) {
        self.geometry = geometry
        geometry.onMeasurementChange = { [weak self] in
            // Measurements arrive during layout, which must not change state.
            DispatchQueue.main.async { self?.invalidate() }
        }
    }

    /// Whether a message renders as a real view, given the `realized` set the caller read in its
    /// body. The caller reads `realizedIDs` up front so it depends on it even while no row has
    /// been measured yet; otherwise the rows would never turn into boxes once measured.
    func isRealized(_ id: String, signature: Int, in realized: Set<String>) -> Bool {
        guard geometry.hasMeasurement(id, signature: signature) else { return true }
        return realized.contains(id)
    }

    func updateViewport(offsetY: CGFloat, height: CGFloat) {
        self.offsetY = offsetY
        viewportHeight = height
        guard height > 0 else { return }
        // Rows are chosen for a span well beyond the viewport, and chosen again only once the
        // viewport nears that span's edge, so scrolling re-renders the rows now and then rather
        // than on every frame.
        let needed = (offsetY - height * 0.5)...(offsetY + height * 1.5)
        if let span = realizedSpan, span.lowerBound <= needed.lowerBound, span.upperBound >= needed.upperBound { return }
        scheduleRecompute()
    }

    func invalidate() {
        realizedSpan = nil
        scheduleRecompute()
    }

    private func scheduleRecompute() {
        guard !isRecomputeScheduled else { return }
        isRecomputeScheduled = true
        // Scroll positions can arrive during layout, which must not change state.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            isRecomputeScheduled = false
            recompute()
        }
    }

    private func recompute() {
        guard let offsetY, viewportHeight > 0 else { return }
        let span = (offsetY - viewportHeight * 1.5)...(offsetY + viewportHeight * 2.5)
        var realized = Set<String>()
        for row in geometry.rows where geometry.isMeasured(row.id) {
            if row.top + row.height >= span.lowerBound, row.top <= span.upperBound { realized.insert(row.id) }
        }
        realizedSpan = span
        if realized != realizedIDs { realizedIDs = realized }
    }
}

/// The transcript's messages, each either rendered or a box `TranscriptLayout` sizes from the
/// message's last measurement.
struct TranscriptMessageRows: View {
    let ids: [String]
    /// Per message, a summary of what its rows show (see `TranscriptGeometry`).
    let signatures: [Int]
    let latestTurnStartID: String?
    let virtualizer: TranscriptVirtualizer
    /// Messages that render however far they are from the viewport: the newest one, whose rows
    /// still change, and one holding the reader's text selection or an open side chat bubble,
    /// which is anchored inside the message's text and would close, losing its chat, if the
    /// message became a box.
    let pinnedIDs: Set<String>
    /// Rows shown above the message that starts the newest turn. They are rows of their own, so
    /// the turn starts at the message itself.
    let latestTurnLeadingRows: (Int) -> AnyView
    /// A message's rows, as one view.
    let row: (Int) -> AnyView

    var body: some View {
        let realized = virtualizer.realizedIDs
        ForEach(Array(ids.enumerated()), id: \.element) { index, id in
            let signature = signatures[index]
            let isBox = !pinnedIDs.contains(id) && !virtualizer.isRealized(id, signature: signature, in: realized)
            if id == latestTurnStartID { latestTurnLeadingRows(index) }
            Group {
                if isBox {
                    Color.clear.accessibilityHidden(true)
                } else {
                    row(index)
                }
            }
            .layoutValue(
                key: TranscriptRowKey.self,
                value: TranscriptRowValue(id: id, signature: signature, isBox: isBox, startsLatestTurn: id == latestTurnStartID)
            )
        }
    }
}
