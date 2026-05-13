import Foundation

/// Build a disambiguation suffix map: session_id → display suffix for sessions sharing a project name.
///
/// When multiple sessions share the same project name, this returns a short suffix for each
/// (e.g. "clientA/myproj") so the UI can distinguish them. Sessions with unique project names
/// get no entry — callers should fall back to `session.project` in that case.
public func disambiguateNames(_ sessions: [SessionInfo]) -> [String: String] {
    var byProject: [String: [SessionInfo]] = [:]
    for s in sessions { byProject[s.project, default: []].append(s) }

    var result: [String: String] = [:]
    for (_, group) in byProject {
        guard group.count > 1 else { continue }

        let paths: [(SessionInfo, [String])] = group.map { s in
            var comps = s.cwd.split(separator: "/").map(String.init)
            if !comps.isEmpty { comps.removeLast() }
            return (s, comps)
        }

        let minLen = paths.map(\.1.count).min() ?? 0
        var diffIdx: Int? = nil
        for i in stride(from: minLen - 1, through: 0, by: -1) {
            if Set(paths.map { $0.1[i] }).count > 1 { diffIdx = i; break }
        }

        if let idx = diffIdx {
            for (session, comps) in paths {
                result[session.session_id] = "\(comps[idx])/\(session.project)"
            }
        } else {
            for (session, _) in paths {
                result[session.session_id] = session.cwd
            }
        }
    }
    return result
}
