import Foundation

/// A fixture for scripts/test-swift-nav.py. The tests assert exact line
/// numbers in this file, so update them together.
struct SwiftNavFixtureLedger {
    enum Entry {
        case credit(Int)
        case debit(Int)
    }

    var entries: [Entry] = []

    /// Adds one entry.
    mutating func record(_ entry: Entry) {
        entries.append(entry)
    }

    mutating func record(_ amount: Int) {
        record(amount >= 0 ? .credit(amount) : .debit(-amount))
    }
}

extension SwiftNavFixtureLedger {
    var balance: Int {
        entries.reduce(0) { total, entry in
            switch entry {
            case .credit(let amount): return total + amount
            case .debit(let amount): return total - amount
            }
        }
    }

    func summary(prefix: String) -> String {
        "\(prefix) \(balance)"
    }
}
