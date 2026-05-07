import Foundation

/// Derive a project label from a working-directory path.
///
/// T3 Code worktrees live at `<home>/.t3/worktrees/<title>/<sha-dir>[/...]`.
/// For those, return the `<title>` segment (the human-readable project name)
/// rather than the SHA-ish leaf directory. For everything else, fall back to
/// the basename of `cwd`.
public func deriveProject(cwd: String, home: String) -> String {
    let prefix = home.hasSuffix("/") ? "\(home).t3/worktrees/" : "\(home)/.t3/worktrees/"
    if cwd.hasPrefix(prefix) {
        let rest = String(cwd.dropFirst(prefix.count))
        if let slash = rest.firstIndex(of: "/") {
            return String(rest[..<slash])
        }
        if !rest.isEmpty { return rest }
    }
    return (cwd as NSString).lastPathComponent
}
