import Foundation

// MARK: - Ghostty Window Scoring

/// Score a Ghostty window/tab title + AXDocument against a target session.
///
/// Returns one of:
/// - 40: Explicit monitor ID match — title contains `[N]` and N equals `sessionId`
/// - 30: AXDocument CWD match
/// - 25: Title contains the CWD basename
/// - 0:  No match (or title belongs to a *different* monitored session)
///
/// Only windows whose title starts with "tmux " are considered (score 0 otherwise).
/// If the title contains `[N]` but `sessionId` doesn't match, returns 0 so that a
/// different-monitored-session window is never accidentally claimed.
public func scoreGhosttyWindow(
    title: String, doc: String, cwd: String, sessionId: String = ""
) -> Int {
    let lower = title.lowercased()
    guard lower.hasPrefix("tmux ") else { return 0 }

    // Highest priority: explicit numeric session ID match from claude.fish wrapper
    let hasBracketId = title.range(of: #"\[\d+\]"#, options: .regularExpression) != nil
    if !sessionId.isEmpty,
       let match = title.range(of: #"\[(\d+)\]"#, options: .regularExpression)
    {
        let bracket = title[match]
        let number = bracket.dropFirst().dropLast()  // strip [ and ]
        if String(number) == sessionId {
            return 40
        }
    }
    // Title has [N] but doesn't match our sessionId — it's a different monitored session
    if hasBracketId { return 0 }

    let cwdNormalized = (cwd.hasSuffix("/") ? cwd : cwd + "/").lowercased()

    // Prefer AXDocument CWD match
    if !doc.isEmpty, let url = URL(string: doc), url.scheme == "file" {
        let docPath = url.path.lowercased()
        let docNormalized = docPath.hasSuffix("/") ? docPath : docPath + "/"
        if docNormalized == cwdNormalized {
            return 30
        }
    }

    // Fall back to title containing basename
    let basename = (cwd as NSString).lastPathComponent.lowercased()
    if lower.contains(basename) {
        return 25
    }
    return 0
}
