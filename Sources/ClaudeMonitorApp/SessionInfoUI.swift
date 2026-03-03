import SwiftUI
import ClaudeMonitorCore

// MARK: - Color Constants

extension Color {
    static let workingBlue = Color(red: 0.149, green: 0.694, blue: 0.941)  // #26B1F0
    static let doneGreen = Color(red: 0.494, green: 0.980, blue: 0.392)  // #7EFA64
}

// MARK: - SessionInfo SwiftUI Extensions

extension SessionInfo {
    var statusColor: Color {
        switch status {
        case "starting": return .gray
        case "working": return .workingBlue
        case "idle": return .doneGreen
        case "attention": return .orange
        case "shutting_down": return .gray
        default: return .gray
        }
    }

    var contextPctColor: Color {
        guard let pct = context_pct else { return .gray }
        if pct >= 80 { return .orange }
        if pct >= 50 { return .yellow }
        return .doneGreen
    }
}
