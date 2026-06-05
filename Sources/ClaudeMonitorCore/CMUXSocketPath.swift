import Foundation

/// Resolves the CMUX control-socket path.
///
/// cmux exposes a Unix-domain control socket. Its location moved from
/// `~/Library/Application Support/cmux/cmux.sock` to the XDG state dir
/// (`~/.local/state/cmux/cmux.sock`), and cmux sets `$CMUX_SOCKET_PATH` for the
/// shells it spawns. The monitor app, however, is launched from Finder/login and
/// does NOT inherit that env var, so it must discover the socket itself.
///
/// Pure and dependency-injected (`env`, `home`, `fileExists`) so it is fully
/// testable without touching the real filesystem.
public enum CMUXSocketPath {
    /// Candidate socket locations in priority order.
    public static func candidates(env: [String: String], home: String) -> [String] {
        var c: [String] = []
        if let p = env["CMUX_SOCKET_PATH"], !p.isEmpty { c.append(p) }
        if let xdg = env["XDG_STATE_HOME"], !xdg.isEmpty {
            c.append(xdg + "/cmux/cmux.sock")
        }
        c.append(home + "/.local/state/cmux/cmux.sock")
        c.append(home + "/Library/Application Support/cmux/cmux.sock")
        return c
    }

    /// Resolve to the first candidate that exists on disk. If none exist, return
    /// the highest-priority candidate anyway so `connect()` keeps a sane target
    /// and recovers automatically once cmux creates the socket there.
    public static func resolve(
        explicit: String?,
        env: [String: String],
        home: String,
        fileExists: (String) -> Bool
    ) -> String {
        if let explicit = explicit, !explicit.isEmpty { return explicit }
        let cands = candidates(env: env, home: home)
        return cands.first(where: fileExists)
            ?? cands.first
            ?? (home + "/.local/state/cmux/cmux.sock")
    }
}
