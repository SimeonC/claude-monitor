import Cocoa
import ClaudeMonitorCore

/// CMUX terminal provider — uses socket API for focus/liveness, env var UUIDs for session identity.
/// CMUX hierarchy: Window > Workspace > Pane > Surface (tab within pane).
/// Sessions store CMUX_SURFACE_ID (UUID) as their identifier.
/// Requires CMUX_SOCKET_MODE=allowAll for external process access.
class CMUXProvider: TerminalProvider {
    let name = "cmux"
    let bundleIdentifier = "com.cmuxterm.app"

    private let socket = CMUXSocketClient()

    // MARK: - Workspace helpers

    /// Fetch all workspaces across all windows.
    private func allWorkspaces() -> [[String: Any]] {
        guard let result = socket.sendUnwrapped(method: "workspace.list") else { return [] }
        return result["workspaces"] as? [[String: Any]] ?? []
    }

    private func activate() {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first?.activate()
    }

    // MARK: - TerminalProvider

    func focusedSurface() -> FocusedSurface? {
        guard let r = socket.sendUnwrapped(method: "surface.current") else { return nil }
        let sRef = r["surface_ref"] as? String ?? ""
        let sId = r["surface_id"] as? String ?? ""
        let wsRef = r["workspace_ref"] as? String ?? ""
        let wsId = r["workspace_id"] as? String ?? ""
        guard !sRef.isEmpty || !sId.isEmpty else { return nil }
        // Pipe-delimited ref|UUID so matching works with either format
        return FocusedSurface(id: "\(sRef)|\(sId)", tabName: "\(wsRef)|\(wsId)")
    }

    func liveSurfaceIds() -> Set<String> {
        // Return both refs and UUIDs for workspace liveness checks
        var ids: Set<String> = []
        for ws in allWorkspaces() {
            if let ref = ws["ref"] as? String { ids.insert(ref) }
            if let id = ws["id"] as? String { ids.insert(id) }
        }
        return ids
    }

    func focusSurface(session: SessionInfo, ttyMap: [String: String]) {
        // 1. Select the workspace first (brings the right sidebar entry into view)
        if let wsId = session.cmux_workspace_id, !wsId.isEmpty {
            if socket.sendUnwrapped(method: "workspace.select", params: ["workspace_id": wsId]) != nil {
                debugLog("CMUXProvider.focus: workspace.select(\(wsId)) success")
            } else {
                debugLog("CMUXProvider.focus: workspace.select(\(wsId)) failed")
            }
        }
        // 2. Focus the exact surface/tab within the workspace
        if let sid = session.cmux_surface_id, !sid.isEmpty {
            if socket.sendUnwrapped(method: "surface.focus", params: ["surface_id": sid]) != nil {
                debugLog("CMUXProvider.focus: surface.focus(\(sid)) success")
            } else {
                debugLog("CMUXProvider.focus: surface.focus(\(sid)) failed")
            }
        }
        activate()
    }

    func matchSessions(_ sessions: [SessionInfo], toSurface surface: FocusedSurface, ttyMap: [String: String]) -> [SessionInfo] {
        let cmux = sessions.filter { $0.terminal == name }
        let surfaceIds = Set(surface.id.split(separator: "|").map(String.init).filter { !$0.isEmpty })
        // Surface-only match: being on a different tab in the same workspace is NOT focused
        return cmux.filter {
            guard let s = $0.cmux_surface_id, !s.isEmpty else { return false }
            return surfaceIds.contains(s)
        }
    }

    func relinkSession(_ session: SessionInfo) -> String? {
        guard let r = socket.sendUnwrapped(method: "surface.current") else { return nil }
        return r["surface_ref"] as? String ?? r["surface_id"] as? String
    }
}
