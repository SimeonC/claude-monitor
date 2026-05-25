import Foundation

// MARK: - Identity Hash

private let fnvPrime: UInt64 = 1099511628211
private let fnvOffset: UInt64 = 14695981039346656037

private func fnv1a(_ string: String, seed: UInt64 = fnvOffset) -> UInt64 {
    var h = seed
    for byte in string.utf8 {
        h ^= UInt64(byte)
        h &*= fnvPrime
    }
    return h
}

private let isoFmtFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private let isoFmtBasic: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

private func parseToSeconds(_ s: String) -> Int64 {
    let d = isoFmtFractional.date(from: s) ?? isoFmtBasic.date(from: s)
    return d.map { Int64($0.timeIntervalSince1970) } ?? 0
}

/// Stable hash over the fields the UI renders.
/// Non-rendered fields (ttyMap, mtime, terminal_session_id, etc.) are excluded so
/// internal cache mutations never trigger unnecessary snapshot emissions.
func computeIdentityHash(
    status: String,
    displayName: String,
    updatedAt: String,
    teamName: String?,
    isActive: Bool,
    permissionMode: String? = nil
) -> UInt64 {
    var h = fnv1a(status)
    h = fnv1a(displayName, seed: h)
    // updated_at bucketed to whole seconds — sub-second jitter won't flip the hash
    let secs = parseToSeconds(updatedAt)
    for i in 0..<8 {
        h ^= UInt64((secs >> (i * 8)) & 0xFF)
        h &*= fnvPrime
    }
    h = fnv1a(teamName ?? "\u{0}", seed: h)
    h = fnv1a(permissionMode ?? "\u{0}", seed: h)
    if isActive { h ^= 0xFFFF_FFFF_FFFF_FFFF }
    return h
}

// MARK: - Team lookup

/// Look up team info for a session, checking merged_session_ids for aggregated sessions.
private func lookupTeam(for session: SessionInfo, teams: [String: TeamInfo]) -> TeamInfo? {
    if let info = teams[session.session_id] { return info }
    guard let mergedIds = session.merged_session_ids else { return nil }
    for sid in mergedIds {
        if let info = teams[sid] { return info }
    }
    return nil
}

// MARK: - Snapshot Builder

/// Build a fully-prepared `MonitorSnapshot` from engine state.
///
/// Pure function — no I/O, no side effects.
///
/// - Parameters:
///   - sessions: Pre-sorted, aggregated, children-filtered sessions.
///   - teams: sessionId → `TeamInfo` for sessions that are team leads.
///   - activeId: Currently active session ID, or nil.
///   - generation: Monotonically increasing counter from the engine.
public func buildSnapshot(
    sessions: [SessionInfo],
    teams: [String: TeamInfo],
    activeId: String?,
    generation: UInt64
) -> MonitorSnapshot {
    let disambig = disambiguateNames(sessions)

    var rows: [SessionRow] = []
    rows.reserveCapacity(sessions.count)

    for session in sessions {
        let team = lookupTeam(for: session, teams: teams)
        let isActive = session.session_id == activeId
        let displayName = disambig[session.session_id] ?? session.project
        let statusBucket = StatusBucket.from(session.status)
        let hash = computeIdentityHash(
            status: session.status,
            displayName: displayName,
            updatedAt: session.updated_at,
            teamName: team?.name,
            isActive: isActive,
            permissionMode: session.permission_mode
        )
        rows.append(
            SessionRow(
                id: session.session_id,
                identityHash: hash,
                session: session,
                displayName: displayName,
                team: team,
                isTeamLead: team != nil,
                isActive: isActive,
                statusBucket: statusBucket
            )
        )
    }

    return MonitorSnapshot(
        generation: generation,
        rows: rows,
        activeSessionId: activeId,
        totalCount: rows.count
    )
}
