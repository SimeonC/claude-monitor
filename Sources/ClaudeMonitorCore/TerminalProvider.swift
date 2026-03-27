import Foundation

// MARK: - Terminal Provider Protocol

/// Result of querying the focused terminal surface.
public struct FocusedSurface {
    public let id: String        // terminal-native surface identifier (UUID, GUID, TTY)
    public let tabName: String?  // tab/window title (used for CWD fallback matching)

    public init(id: String, tabName: String? = nil) {
        self.id = id
        self.tabName = tabName
    }
}

/// Abstraction over terminal emulators (Ghostty, CMUX, iTerm2, Terminal.app).
/// Concrete implementations live in the App target (they require Cocoa/sockets).
/// Matching logic is pure and unit-testable.
public protocol TerminalProvider {
    /// Terminal name written to session files: "ghostty", "cmux", "iterm2", "terminal"
    var name: String { get }

    /// macOS bundle identifier for detecting frontmost app
    var bundleIdentifier: String { get }

    /// Query which surface is currently focused. Blocking — call off main thread.
    func focusedSurface() -> FocusedSurface?

    /// All live surface identifiers (for liveness/staleness checks). Blocking.
    func liveSurfaceIds() -> Set<String>

    /// Focus a session's terminal surface. Blocking.
    func focusSurface(session: SessionInfo, ttyMap: [String: String])

    /// Match sessions to the focused surface, returning candidates (unsorted).
    /// Pure logic — no I/O. Implementations filter `sessions` by terminal-specific criteria.
    func matchSessions(_ sessions: [SessionInfo], toSurface surface: FocusedSurface, ttyMap: [String: String]) -> [SessionInfo]

    /// Relink a session to the currently focused surface. Returns new surface ID, or nil. Blocking.
    func relinkSession(_ session: SessionInfo) -> String?
}

// MARK: - Default implementations

public extension TerminalProvider {
    func relinkSession(_ session: SessionInfo) -> String? { nil }
    func liveSurfaceIds() -> Set<String> { [] }
}

// MARK: - Shared candidate selection

/// Pick the best session from candidates by status priority (attention > working > idle),
/// with stale "working" sessions (>5 min since update) demoted below idle.
/// Uses the shared `statusPriority` from Aggregation (lower = better).
public func bestCandidate(_ candidates: [SessionInfo], referenceDate: Date = Date()) -> SessionInfo? {
    guard !candidates.isEmpty else { return nil }

    let fiveMinAgo = referenceDate.addingTimeInterval(-300)
    let staleFmt = ISO8601DateFormatter()

    func effectivePriority(_ s: SessionInfo) -> Int {
        let p = statusPriority[s.status] ?? 9
        guard s.status == "working" else { return p }
        // Demote stale "working" below idle (priority 3 > idle's 2, so worse)
        staleFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var d = staleFmt.date(from: s.updated_at)
        if d == nil {
            staleFmt.formatOptions = [.withInternetDateTime]
            d = staleFmt.date(from: s.updated_at)
        }
        return (d ?? .distantFuture) < fiveMinAgo ? 3 : p
    }

    // Lower priority value = better (attention=0, working=1, idle=2)
    return candidates.min { a, b in
        let pa = effectivePriority(a)
        let pb = effectivePriority(b)
        if pa != pb { return pa < pb }
        // On tie: prefer more recently updated
        return a.updated_at > b.updated_at
    }
}
