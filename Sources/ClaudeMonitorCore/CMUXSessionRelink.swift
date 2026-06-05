import Foundation

/// Pure JSON transform for relinking a CMUX session to a focused surface.
///
/// CMUX matching/focus reads `cmux_surface_id` (and `cmux_workspace_id`) from the
/// session JSON file — NOT from `tty_map.json`. Relink must therefore rewrite
/// those keys in the session file itself. Other keys are preserved so we never
/// drop fields the hook owns (agent_count, skip_permissions, parent_session_id…).
public enum CMUXSessionRelink {
    /// Return the session JSON with `cmux_surface_id` set to `surfaceId`,
    /// `cmux_workspace_id` set to `workspaceId` when non-empty, and
    /// `cmux_checkpoint` set to `checkpoint` when non-empty. All other keys are left
    /// untouched. Returns nil if the input is not a JSON object.
    public static func apply(
        jsonData: Data, surfaceId: String, workspaceId: String?, checkpoint: String?
    ) -> Data? {
        guard var obj = (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any] else {
            return nil
        }
        obj["cmux_surface_id"] = surfaceId
        if let w = workspaceId, !w.isEmpty {
            obj["cmux_workspace_id"] = w
        }
        if let ckpt = checkpoint, !ckpt.isEmpty {
            obj["cmux_checkpoint"] = ckpt
        }
        return try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    }
}
