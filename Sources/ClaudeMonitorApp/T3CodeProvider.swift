import Cocoa
import ClaudeMonitorCore

/// T3 Code (Alpha) provider — Electron-based Claude Code host.
/// No per-window IPC available (T3's /ws endpoint requires unknown auth), so focus = app activation only.
/// matchSessions returns all t3code sessions when T3 is frontmost; bestCandidate picks by status/recency.
class T3CodeProvider: TerminalProvider {
    let name = "t3code"
    let bundleIdentifier = "com.t3tools.t3code"

    func focusedSurface() -> FocusedSurface? {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return front == bundleIdentifier ? FocusedSurface(id: bundleIdentifier) : nil
    }

    func focusSurface(session: SessionInfo, ttyMap: [String: String]) {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first?.activate()
    }

    func matchSessions(_ sessions: [SessionInfo], toSurface surface: FocusedSurface, ttyMap: [String: String]) -> [SessionInfo] {
        sessions.filter { $0.terminal == name }
    }
}
