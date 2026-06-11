import Foundation
import ClaudeMonitorCore

/// Single-subscription view model. Engine builds snapshots off-main and calls apply();
/// UI reads only this snapshot — no derivation in SwiftUI body.
@MainActor
final class MonitorViewModel: ObservableObject {
    @Published private(set) var snapshot: MonitorSnapshot = .empty
    @Published var focusError: String?

    private weak var sessionReader: SessionReader?
    private weak var activeTracker: ActiveSessionTracker?

    init(
        sessionReader: SessionReader,
        teamReader: TeamReader,
        activeTracker: ActiveSessionTracker
    ) {
        self.sessionReader = sessionReader
        self.activeTracker = activeTracker
    }

    // MARK: - Engine sink

    /// Called on @MainActor by WatcherEngine.rebuildAndEmit. Drops stale emissions.
    func apply(_ incoming: MonitorSnapshot) {
        guard incoming.generation > snapshot.generation else { return }
        snapshot = incoming
    }

    // MARK: - Intent methods

    func setActive(sessionId: String) {
        activeTracker?.activeSessionId = sessionId
    }

    func refresh() {
        sessionReader?.scanProjects()
        sessionReader?.readSessions()
    }

    func relink(_ session: SessionInfo) {
        sessionReader?.relinkSession(session)
    }

    func delete(sessionId: String) {
        sessionReader?.deleteSession(sessionId)
    }

    func focus(_ session: SessionInfo, ttyMap: [String: String]) {
        switchToSession(session, ttyMap: ttyMap) { [weak self] msg in
            guard let self, self.focusError != msg else { return }
            self.focusError = msg
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                if self?.focusError == msg { self?.focusError = nil }
            }
        }
        setActive(sessionId: session.session_id)
    }
}
