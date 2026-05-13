import Combine
import Foundation
import ClaudeMonitorCore

/// Single-subscription view model. Merges SessionReader, TeamReader, and ActiveSessionTracker
/// into one @Published snapshot. The UI reads only this snapshot — no derivation in SwiftUI body.
///
/// Step 2 bridge: builds snapshot on main (perf-neutral vs. old approach).
/// Step 3+ replaces this with WatcherEngine driving the snapshot off-main.
@MainActor
final class MonitorViewModel: ObservableObject {
    @Published private(set) var snapshot: MonitorSnapshot = .empty

    private var generation: UInt64 = 0
    private var cancellables: Set<AnyCancellable> = []

    // Held for intent method delegation (replaced by engine in step 3+)
    private weak var sessionReader: SessionReader?
    private weak var activeTracker: ActiveSessionTracker?

    init(
        sessionReader: SessionReader,
        teamReader: TeamReader,
        activeTracker: ActiveSessionTracker
    ) {
        self.sessionReader = sessionReader
        self.activeTracker = activeTracker

        Publishers.CombineLatest3(
            sessionReader.$sessions,
            teamReader.$teamsBySession,
            activeTracker.$activeSessionId
        )
        .sink { [weak self] sessions, teams, activeId in
            guard let self = self else { return }
            self.generation &+= 1
            let snap = buildSnapshot(
                sessions: sessions, teams: teams,
                activeId: activeId, generation: self.generation
            )
            self.snapshot = snap
        }
        .store(in: &cancellables)
    }

    // MARK: - Engine path

    /// Called on @MainActor by WatcherEngine.rebuildAndEmit. Drops stale emissions.
    func apply(_ incoming: MonitorSnapshot) {
        guard incoming.generation > snapshot.generation else { return }
        snapshot = incoming
    }

    // MARK: - Intent methods (step 2: delegate to underlying objects)

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
}
