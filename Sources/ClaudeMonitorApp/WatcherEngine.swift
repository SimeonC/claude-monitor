import Combine
import Foundation
import ClaudeMonitorCore

/// Background engine that owns all state and emits `MonitorSnapshot` to `MonitorViewModel`.
///
/// Architecture:
///   FSEvents / timers / NSWorkspace shim → engine.queue (serial)
///       → rebuildAndEmit() → identityHash diff → MonitorViewModel.apply()
///
/// Class (not actor): FSEvents C callbacks can't `await`; serial queue provides ordering.
///
/// Migration status:
///   Step 3 (current): skeleton — subscribes to existing @Published streams via Combine,
///     builds snapshot on engine.queue (off-main), applies O(n) identityHash diff.
///   Steps 4–6 (future): absorb SessionReader, TeamReader, ActiveSessionTracker logic directly
///     onto engine.queue; replace Timer.scheduledTimer with DispatchSourceTimers.
final class WatcherEngine {
    let queue = DispatchQueue(label: "com.claudemonitor.engine", qos: .userInitiated)
    weak var viewModel: MonitorViewModel?

    private var generation: UInt64 = 0
    private var lastSnapshot: MonitorSnapshot = .empty
    private var lastAttentionPulse: UInt64 = 0
    private var cancellables: Set<AnyCancellable> = []
    private var started = false

    // MARK: - Start / Stop

    func start(
        sessionReader: SessionReader,
        teamReader: TeamReader,
        activeTracker: ActiveSessionTracker
    ) {
        guard !started else { return }
        started = true

        // Subscribe to all four published streams. Each update hops to engine.queue so
        // buildSnapshot (potentially expensive) never runs on the main thread.
        //
        // `attentionPulse` is a realtime force-emit signal: it increments whenever a
        // session transitions into "attention", so even if identityHash diff would
        // otherwise coalesce the change we still push it through to the UI.
        let combined = Publishers.CombineLatest4(
            sessionReader.$sessions,
            teamReader.$teamsBySession,
            activeTracker.$activeSessionId,
            sessionReader.$attentionPulse
        )
        combined
            .sink { [weak self] sessions, teams, activeId, pulse in
                guard let self = self else { return }
                // sessions/teams/activeId/pulse are value types — safe to capture
                self.queue.async {
                    self.rebuildAndEmit(
                        sessions: sessions, teams: teams,
                        activeId: activeId, attentionPulse: pulse
                    )
                }
            }
            .store(in: &cancellables)
    }

    func stop() {
        cancellables.removeAll()
        started = false
    }

    // MARK: - Entry points (dispatched to engine.queue by callers)

    /// Called by WorkspaceActivationShim when the frontmost app changes.
    /// Step 3: no-op — ActiveSessionTracker still handles detection independently.
    /// Steps 4–5: will absorb active-session poll logic here.
    func ingestActiveAppToken(_ token: ActiveAppToken) {
        // Future: engine.queue.async { self.handleActivation(token) }
    }

    // MARK: - Intent methods (safe to call from any thread — hop to engine.queue for state)

    func focusSession(_ sessionId: String) {
        // Stub: active-session state lives on engine in steps 4–6
    }

    // MARK: - Core pipeline

    /// Called on engine.queue. Builds a snapshot, diffs against the last emission using
    /// per-row identityHash, and emits to the view model only if something visible changed.
    ///
    /// Attention-transition force-emit: if `attentionPulse` changed since last emit, OR
    /// any new row has `statusBucket == .attention` whose ID was not `.attention` in
    /// `lastSnapshot`, bypass the identityHash guard. Defensive: identityHash already
    /// includes status, but the explicit check guarantees no attention transition is
    /// dropped even if hashing logic changes later.
    private func rebuildAndEmit(
        sessions: [SessionInfo], teams: [String: TeamInfo],
        activeId: String?, attentionPulse: UInt64
    ) {
        generation &+= 1
        let snap = buildSnapshot(
            sessions: sessions, teams: teams,
            activeId: activeId, generation: generation
        )

        let pulseChanged = attentionPulse != lastAttentionPulse
        lastAttentionPulse = attentionPulse

        let rows = snap.rows
        let old = lastSnapshot.rows

        let hashChanged = rows.count != old.count
            || zip(rows, old).contains(where: { $0.identityHash != $1.identityHash })

        let attentionTransition: Bool = {
            guard !rows.isEmpty else { return false }
            var oldAttention: Set<String> = []
            for r in old where r.statusBucket == .attention { oldAttention.insert(r.id) }
            for r in rows where r.statusBucket == .attention && !oldAttention.contains(r.id) {
                return true
            }
            return false
        }()

        guard hashChanged || pulseChanged || attentionTransition else { return }

        lastSnapshot = snap
        Task { @MainActor [weak self] in
            self?.viewModel?.apply(snap)
        }
    }
}
