import SwiftUI

enum CCRStatus: Equatable {
    case stopped
    case starting
    case stopping
    case running
    case partiallyRunning
    case error(String)

    var title: String {
        switch self {
        case .stopped:
            return String(localized: "Stopped")
        case .starting:
            return String(localized: "Starting…")
        case .stopping:
            return String(localized: "Stopping…")
        case .running:
            return String(localized: "Running")
        case .partiallyRunning:
            return String(localized: "Partially Running")
        case .error(let message):
            return String(localized: "Error: \(message)")
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
        case .stopping:
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
        case .stopping:
            return .orange
        case .partiallyRunning:
            return .yellow
        case .error:
            return .red
        }
    }
}
