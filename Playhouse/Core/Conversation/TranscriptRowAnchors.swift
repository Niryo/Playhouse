import Foundation

/// Where the rows recorded after a message, such as provider dividers and goal achievements,
/// sit in the transcript. A row stays with the message it was recorded after, so it never
/// shows after a newer message and never moves as new messages arrive.
package enum TranscriptRowAnchors {
    /// The visible message a row recorded after `messageID` follows. A message folded out of
    /// view hands its rows to the nearest visible message at or before it, so they keep their
    /// place in time. A message not loaded yet has none: its rows appear with it as earlier
    /// history loads.
    ///
    /// - Parameters:
    ///   - loadedIDs: Every loaded message, folded ones included, in transcript order.
    ///   - visibleIDs: The loaded messages the transcript shows.
    package static func visibleAnchor(after messageID: String, loadedIDs: [String], visibleIDs: Set<String>) -> String? {
        if visibleIDs.contains(messageID) { return messageID }
        guard let index = loadedIDs.firstIndex(of: messageID) else { return nil }
        return loadedIDs[...index].last(where: visibleIDs.contains)
    }

    /// Rows follow their message only while it is rendered. The window starts at the newest
    /// turn and reveals older messages as the reader scrolls up, so a row whose message sits
    /// above it appears once that message does.
    package static func renderedAnchor(_ anchorID: String?, renderedIDs: Set<String>) -> String? {
        guard let anchorID, renderedIDs.contains(anchorID) else { return nil }
        return anchorID
    }

    /// Rows keyed by the rendered message they follow; rows sharing a message keep the order
    /// they were recorded in.
    package static func rowsByRenderedAnchor<Row>(
        _ rows: [Row], renderedIDs: Set<String>, anchor: (Row) -> String?
    ) -> [String: [Row]] {
        var result: [String: [Row]] = [:]
        for row in rows {
            if let id = renderedAnchor(anchor(row), renderedIDs: renderedIDs) { result[id, default: []].append(row) }
        }
        return result
    }
}
