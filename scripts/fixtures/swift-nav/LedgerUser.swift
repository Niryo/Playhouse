import Foundation

enum SwiftNavFixtureReport {
    static func make() -> String {
        var ledger = SwiftNavFixtureLedger()
        ledger.record(5)
        // A comment that mentions SwiftNavFixtureLedger.
        return ledger.summary(prefix: "Balance:")
    }
}
