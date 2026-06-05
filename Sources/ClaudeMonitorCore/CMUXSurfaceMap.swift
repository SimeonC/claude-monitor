import Foundation

/// Pure mapper from CMUX control-plane results to checkpoint-based lookup tables.
///
/// The tmux checkpoint name (e.g. "claude-36676") is the only stable identifier that
/// survives CMUX restarts — surface UUIDs and workspace UUIDs rotate on every restart.
/// This map lets the app resolve live surface/workspace IDs from a stored checkpoint.
public struct CMUXSurfaceMap {
    public struct Entry {
        public let surfaceId: String
        public let workspaceId: String
        public let checkpoint: String
    }

    /// Keyed by checkpoint name → Entry (focus path: checkpoint → live ids)
    public let byCheckpoint: [String: Entry]
    /// Keyed by surface_id → checkpoint name (match/relink path: live id → stable key)
    public let checkpointBySurfaceId: [String: String]

    /// Build from `workspace.list` result and per-workspace `surface.list` results.
    /// - Parameters:
    ///   - workspacesResult: The unwrapped result dict from `workspace.list`.
    ///   - surfacesByWorkspace: Pairs of (workspaceId, surface.list result dict).
    public init(workspacesResult: [String: Any], surfacesByWorkspace: [(String, [String: Any])]) {
        var byCheckpoint: [String: Entry] = [:]
        var checkpointBySurfaceId: [String: String] = [:]

        for (wsId, surfaceListResult) in surfacesByWorkspace {
            guard !wsId.isEmpty else { continue }
            guard let surfaces = surfaceListResult["surfaces"] as? [[String: Any]] else { continue }
            for surface in surfaces {
                guard let sid = surface["surface_id"] as? String, !sid.isEmpty else { continue }
                guard let binding = surface["resume_binding"] as? [String: Any],
                      let checkpoint = binding["checkpoint_id"] as? String,
                      !checkpoint.isEmpty else { continue }
                let entry = Entry(surfaceId: sid, workspaceId: wsId, checkpoint: checkpoint)
                byCheckpoint[checkpoint] = entry
                checkpointBySurfaceId[sid] = checkpoint
            }
        }

        self.byCheckpoint = byCheckpoint
        self.checkpointBySurfaceId = checkpointBySurfaceId
    }
}
