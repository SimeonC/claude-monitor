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
    ///
    /// `readFile` is injected so tests can override filesystem reads.
    /// In production it should read file contents as a UTF-8 string.
    /// The function is used to read `last-socket-path` hint files that CMUX
    /// writes on startup — they contain the path of the live numbered socket
    /// (e.g. `cmux-502.sock`) and must be preferred over the generic `cmux.sock`
    /// which can be left as a stale dead file on disk from a previous run.
    public static func candidates(
        env: [String: String],
        home: String,
        readFile: ((String) -> String?)? = nil,
        listDir: ((String) -> [String])? = nil
    ) -> [String] {
        var c: [String] = []
        if let p = env["CMUX_SOCKET_PATH"], !p.isEmpty { c.append(p) }

        if let xdg = env["XDG_STATE_HOME"], !xdg.isEmpty {
            let dir = xdg + "/cmux"
            if let lsp = readFile?(dir + "/last-socket-path")?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !lsp.isEmpty {
                c.append(lsp)
            }
            if let entries = listDir?(dir) {
                for name in entries where name.hasPrefix("cmux-") && name.hasSuffix(".sock") {
                    c.append(dir + "/" + name)
                }
            }
            c.append(dir + "/cmux.sock")
        }

        let defaultDir = home + "/.local/state/cmux"
        if let lsp = readFile?(defaultDir + "/last-socket-path")?
                .trimmingCharacters(in: .whitespacesAndNewlines), !lsp.isEmpty {
            c.append(lsp)
        }
        if let entries = listDir?(defaultDir) {
            for name in entries where name.hasPrefix("cmux-") && name.hasSuffix(".sock") {
                c.append(defaultDir + "/" + name)
            }
        }
        c.append(defaultDir + "/cmux.sock")
        c.append(home + "/Library/Application Support/cmux/cmux.sock")

        // De-dupe preserving order (hint may equal a globbed entry)
        var seen = Set<String>()
        return c.filter { seen.insert($0).inserted }
    }

    /// Resolve the socket path. Selection priority:
    /// 1. first candidate that probes live (when `probe` is injected)
    /// 2. first candidate that exists on disk (back-compat when `probe` is nil)
    /// 3. first candidate (sane target so a later cmux launch recovers)
    /// 4. default XDG state path
    public static func resolve(
        explicit: String?,
        env: [String: String],
        home: String,
        fileExists: (String) -> Bool,
        readFile: ((String) -> String?)? = nil,
        probe: ((String) -> Bool)? = nil,
        listDir: ((String) -> [String])? = nil
    ) -> String {
        if let explicit = explicit, !explicit.isEmpty { return explicit }
        let cands = candidates(env: env, home: home, readFile: readFile, listDir: listDir)
        if let probe = probe, let live = cands.first(where: probe) { return live }
        return cands.first(where: fileExists)
            ?? cands.first
            ?? (home + "/.local/state/cmux/cmux.sock")
    }
}
