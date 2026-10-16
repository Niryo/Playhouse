import Foundation
import SwiftData
import SwiftUI

enum TaskStatus: String, CaseIterable, Identifiable {
    case backlog = "Backlog"
    case ready = "Ready"
    case inProgress = "In Progress"
    case done = "Done"

    var id: String {
        rawValue
    }

    var accessibilityKey: String {
        rawValue.lowercased().replacingOccurrences(of: " ", with: "-")
    }

    var accent: Color {
        switch self {
        case .backlog: Color(red: 0.52, green: 0.57, blue: 0.66)
        case .ready: Color(red: 0.36, green: 0.49, blue: 0.91)
        case .inProgress: Color(red: 0.75, green: 0.48, blue: 0.20)
        case .done: Color(red: 0.20, green: 0.62, blue: 0.45)
        }
    }
}

@Model
final class BoardTask {
    var id: UUID
    var title: String
    var statusRawValue: String
    var createdAt: Date
    var codexThreadID: String?
    var workspaceRootPathsData: Data?

    var workspaceRootPaths: [String] {
        get {
            guard let workspaceRootPathsData else { return [] }
            return (try? JSONDecoder().decode([String].self, from: workspaceRootPathsData)) ?? []
        }
        set {
            workspaceRootPathsData = try? JSONEncoder().encode(newValue)
        }
    }

    var status: TaskStatus {
        get { TaskStatus(rawValue: statusRawValue) ?? .backlog }
        set { statusRawValue = newValue.rawValue }
    }

    init(title: String, status: TaskStatus = .backlog, workspaceRootPaths: [String] = []) {
        id = UUID()
        self.title = title
        statusRawValue = status.rawValue
        createdAt = .now
        codexThreadID = nil
        workspaceRootPathsData = try? JSONEncoder().encode(workspaceRootPaths)
    }
}
