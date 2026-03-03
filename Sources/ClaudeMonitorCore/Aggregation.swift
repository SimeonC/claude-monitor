import Foundation

// MARK: - Session Aggregation

public let statusPriority: [String: Int] = [
    "attention": 0, "working": 1, "idle": 2, "shutting_down": 3, "starting": 4,
]

/// Aggregate a flat list of parent sessions into one representative per project/CWD group.
///
/// - Groups sessions by project name.
/// - Merges groups that share the same CWD (handles renamed projects / multiple sessions in one dir).
/// - Picks the representative session using status priority; stale "working" sessions
///   (updated 5+ min ago) are demoted below "idle" so a crashed session doesn't
///   keep a project appearing "working" alongside a live idle session.
/// - Merges terminal info, last_prompt, and earliest started_at from the group into the representative.
///
/// - Parameters:
///   - sessions: Parent sessions (children already filtered out).
///   - referenceDate: Injected "now" for deterministic testing.
public func aggregateSessions(
    _ sessions: [SessionInfo],
    referenceDate: Date = Date()
) -> [SessionInfo] {
    var grouped: [String: [SessionInfo]] = [:]
    for s in sessions { grouped[s.project, default: []].append(s) }

    // Merge groups that share the exact same CWD (different project names, same directory)
    var didMerge = true
    while didMerge {
        didMerge = false
        let keys = Array(grouped.keys)
        outer: for i in 0..<keys.count {
            for j in (i + 1)..<keys.count {
                let a = keys[i]
                let b = keys[j]
                let cwdsA = Set(grouped[a]!.map { $0.cwd })
                let cwdsB = Set(grouped[b]!.map { $0.cwd })
                if !cwdsA.isDisjoint(with: cwdsB) {
                    grouped[a]!.append(contentsOf: grouped[b]!)
                    grouped.removeValue(forKey: b)
                    didMerge = true
                    break outer
                }
            }
        }
    }

    let fiveMinAgo = referenceDate.addingTimeInterval(-300)
    let staleFmt = ISO8601DateFormatter()

    func effectivePriority(_ s: SessionInfo) -> Int {
        let p = statusPriority[s.status] ?? 9
        guard s.status == "working" else { return p }
        staleFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var d = staleFmt.date(from: s.updated_at)
        if d == nil {
            staleFmt.formatOptions = [.withInternetDateTime]
            d = staleFmt.date(from: s.updated_at)
        }
        return (d ?? .distantFuture) < fiveMinAgo ? 3 : p
    }

    var aggregated: [SessionInfo] = []
    for (_, group) in grouped {
        if group.count == 1 {
            aggregated.append(group[0])
            continue
        }

        // Pick representative: highest-priority status, then most recently updated.
        // Stale "working" sessions (5+ min no update) are demoted below "idle".
        let best = group.min { a, b in
            let pa = effectivePriority(a)
            let pb = effectivePriority(b)
            if pa != pb { return pa < pb }
            return a.updated_at > b.updated_at  // ISO8601 sorts lexicographically
        }!
        var merged = best

        // Use first non-empty terminal info
        if merged.terminal.isEmpty {
            if let withTerminal = group.first(where: { !$0.terminal.isEmpty }) {
                merged.terminal = withTerminal.terminal
                merged.terminal_session_id = withTerminal.terminal_session_id
            }
        }
        // Use first non-empty last_prompt
        if merged.last_prompt.isEmpty {
            merged.last_prompt =
                group.first(where: { !$0.last_prompt.isEmpty })?.last_prompt ?? ""
        }
        // Use earliest started_at for largest elapsed time
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var earliest = merged.started_at
        var earliestDate: Date? =
            formatter.date(from: earliest)
            ?? {
                formatter.formatOptions = [.withInternetDateTime]
                return formatter.date(from: earliest)
            }()
        for s in group {
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = formatter.date(from: s.started_at)
                ?? {
                    formatter.formatOptions = [.withInternetDateTime]
                    return formatter.date(from: s.started_at)
                }()
            {
                if earliestDate == nil || d < earliestDate! {
                    earliestDate = d
                    earliest = s.started_at
                }
            }
        }
        merged.started_at = earliest

        aggregated.append(merged)
    }

    return aggregated
}
