import Cocoa
import ClaudeMonitorCore

/// CMUX terminal provider — uses socket API for focus/liveness, checkpoint for session identity.
/// CMUX hierarchy: Window > Workspace > Pane > Surface (tab within pane).
/// Sessions store cmux_checkpoint (stable tmux session name) as their primary join key;
/// cmux_surface_id/cmux_workspace_id are live-resolved from the map at focus/match time.
/// Requires CMUX_SOCKET_MODE=allowAll for external process access.
class CMUXProvider: TerminalProvider {
    let name = "cmux"
    let bundleIdentifier = "com.cmuxterm.app"

    private let socket = CMUXSocketClient()

    // MARK: - Workspace helpers

    private func activate() {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first?.activate()
    }

    /// Build a surface map by querying workspace.list then surface.list per workspace.
    /// 1 + N socket round-trips (N = number of workspaces). Short-circuits on failure.
    private func buildSurfaceMap() -> CMUXSurfaceMap {
        let wsResult = socket.sendUnwrapped(method: "workspace.list") ?? [:]
        let workspaces = wsResult["workspaces"] as? [[String: Any]] ?? []
        var surfacesByWorkspace: [(String, [String: Any])] = []
        for ws in workspaces {
            guard let wsId = ws["id"] as? String, !wsId.isEmpty else { continue }
            let result = socket.sendUnwrapped(method: "surface.list", params: ["workspace_id": wsId]) ?? [:]
            surfacesByWorkspace.append((wsId, result))
        }
        return CMUXSurfaceMap(workspacesResult: wsResult, surfacesByWorkspace: surfacesByWorkspace)
    }

    // MARK: - TerminalProvider

    func focusedSurface() -> FocusedSurface? {
        guard let r = socket.sendUnwrapped(method: "surface.current") else { return nil }
        let sRef = r["surface_ref"] as? String ?? ""
        let sId = r["surface_id"] as? String ?? ""
        let wsRef = r["workspace_ref"] as? String ?? ""
        let wsId = r["workspace_id"] as? String ?? ""
        guard !sRef.isEmpty || !sId.isEmpty else { return nil }
        // Reverse-resolve surface_id → checkpoint via live map
        let checkpoint = sId.isEmpty ? nil : buildSurfaceMap().checkpointBySurfaceId[sId]
        return FocusedSurface(id: "\(sRef)|\(sId)", tabName: "\(wsRef)|\(wsId)", checkpoint: checkpoint)
    }

    func liveSurfaceIds() -> Set<String> {
        guard let result = socket.sendUnwrapped(method: "workspace.list") else { return [] }
        var ids: Set<String> = []
        for ws in result["workspaces"] as? [[String: Any]] ?? [] {
            if let ref = ws["ref"] as? String { ids.insert(ref) }
            if let id = ws["id"] as? String { ids.insert(id) }
        }
        return ids
    }

    func focusSurface(session: SessionInfo, ttyMap: [String: String]) {
        var resolvedSurfaceId = session.cmux_surface_id
        var resolvedWorkspaceId = session.cmux_workspace_id

        // Resolve live IDs from checkpoint (survives CMUX restarts)
        if let ckpt = session.cmux_checkpoint, !ckpt.isEmpty {
            let map = buildSurfaceMap()
            if let entry = map.byCheckpoint[ckpt] {
                resolvedSurfaceId = entry.surfaceId
                resolvedWorkspaceId = entry.workspaceId
                debugLog("CMUXProvider.focus: resolved checkpoint \(ckpt) → surfaceId=\(entry.surfaceId)")
            } else {
                debugLog("CMUXProvider.focus: checkpoint \(ckpt) not in map, using stored ids")
            }
        }

        if let wsId = resolvedWorkspaceId, !wsId.isEmpty {
            if socket.sendUnwrapped(method: "workspace.select", params: ["workspace_id": wsId]) != nil {
                debugLog("CMUXProvider.focus: workspace.select(\(wsId)) success")
            } else {
                debugLog("CMUXProvider.focus: workspace.select(\(wsId)) failed")
            }
        }
        if let sid = resolvedSurfaceId, !sid.isEmpty {
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
        // Checkpoint match (preferred — survives CMUX restarts)
        if let ckpt = surface.checkpoint, !ckpt.isEmpty {
            let byCheckpoint = cmux.filter { $0.cmux_checkpoint == ckpt }
            if !byCheckpoint.isEmpty { return byCheckpoint }
        }
        // Fallback: surface-id match (legacy sessions without checkpoint)
        let surfaceIds = Set(surface.id.split(separator: "|").map(String.init).filter { !$0.isEmpty })
        return cmux.filter {
            guard let s = $0.cmux_surface_id, !s.isEmpty else { return false }
            return surfaceIds.contains(s)
        }
    }

    func relinkSession(_ session: SessionInfo) -> String? {
        guard let r = socket.sendUnwrapped(method: "surface.current") else { return nil }
        return r["surface_ref"] as? String ?? r["surface_id"] as? String
    }

    /// Returns the focused surface's stable UUIDs and checkpoint for persisting into the session file.
    /// Checkpoint is resolved via surface map (surface_id → checkpoint).
    func relinkSurfaceIds() -> (surfaceId: String, workspaceId: String?, checkpoint: String?)? {
        guard let r = socket.sendUnwrapped(method: "surface.current"),
              let sid = r["surface_id"] as? String, !sid.isEmpty else { return nil }
        let wid = r["workspace_id"] as? String
        let checkpoint = buildSurfaceMap().checkpointBySurfaceId[sid]
        return (sid, (wid?.isEmpty == false) ? wid : nil, checkpoint)
    }
}
