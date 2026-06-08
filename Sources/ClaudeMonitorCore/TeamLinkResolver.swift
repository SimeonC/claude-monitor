import Foundation

/// Resolve each teammate's parent (lead) session id.
///
/// Normal path: teamName → leadSessionByTeamName, if that lead is loaded and shares the
/// teammate's cwd.
///
/// Collision fallback: when the mapped lead is absent or its cwd differs from the teammate's
/// cwd (indicates two concurrent runs sharing the same team name), find the *unique*
/// non-teammate loaded session whose cwd matches. The "exactly one" guard prevents
/// mis-grouping when unrelated sessions coincidentally share a cwd.
///
/// Falls back to the mapped lead (if loaded) when the cwd is ambiguous, preserving
/// today's behavior on the non-collided path.
public func resolveTeamParents(
    sessions: [SessionInfo],
    teamNameBySession: [String: String],
    leadSessionByTeamName: [String: String]
) -> [String: String] {
    let loadedIds = Set(sessions.map { $0.session_id })
    let cwdBySession = Dictionary(uniqueKeysWithValues: sessions.map { ($0.session_id, $0.cwd) })

    var nonTeammatesByCwd: [String: [String]] = [:]
    for s in sessions where teamNameBySession[s.session_id] == nil {
        nonTeammatesByCwd[s.cwd, default: []].append(s.session_id)
    }

    var result: [String: String] = [:]
    for s in sessions {
        guard let teamName = teamNameBySession[s.session_id] else { continue }
        let mapped = leadSessionByTeamName[teamName]

        // Normal path: mapped lead is loaded and cwd matches
        if let r = mapped, loadedIds.contains(r), cwdBySession[r] == s.cwd {
            result[s.session_id] = r
            continue
        }

        // Collision fallback: unique non-teammate sharing cwd
        let candidates = nonTeammatesByCwd[s.cwd] ?? []
        if candidates.count == 1 {
            result[s.session_id] = candidates[0]
            continue
        }

        // Ambiguous cwd: preserve existing behavior — use map result if loaded
        if let r = mapped, loadedIds.contains(r) {
            result[s.session_id] = r
        }
    }
    return result
}
