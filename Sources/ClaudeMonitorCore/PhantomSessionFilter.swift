import Foundation

/// Returns true when a session .json has no backing JSONL and the 60s grace period has expired.
/// 60s grace lets SessionStart hook write .json before Claude CLI creates the JSONL line.
public func isPhantomSession(jsonlExists: Bool, mtimeAge: TimeInterval) -> Bool {
    !jsonlExists && mtimeAge > 60
}

/// Returns true when a .tmp sidecar should be cleaned up:
/// no matching real .json and the file is older than 1 day.
/// If .json exists, the tmp may be mid-write — leave it alone.
public func isStaleTmpSidecar(hasMatchingJson: Bool, mtimeAge: TimeInterval) -> Bool {
    !hasMatchingJson && mtimeAge > 86400
}
