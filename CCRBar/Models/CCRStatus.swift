import SwiftUI

enum CCRStatus: Equatable {
    case stopped
    case starting
    case running
    case partiallyRunning
    case error(String)

    var title: String {
        switch self {
        case .stopped:
            return "Stopped"
        case .starting:
            return "Starting…"
        case .running:
            return "Running"
        case .partiallyRunning:
            return "Partially Running"
        case .error(let message):
            return "Error: \(message)"
        }
    }

    var symbolName: String {
        switch self {
        case .running:
            return "circle.fill"
        case .stopped:
            return "circle"
        case .starting:
            return "circle.lefthalf.filled"
        case .partiallyRunning:
            return "circle.lefthalf.filled"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .running:
            return .green
        case .stopped:
            return .secondary
        case .starting:
            return .orange
        case .partiallyRunning:
            return .yellow
        case .error:
            return .red
        }
    }
}
