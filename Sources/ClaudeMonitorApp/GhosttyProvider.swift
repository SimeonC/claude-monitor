import Cocoa
import ClaudeMonitorCore

/// Ghostty terminal provider — uses AppleScript for all interaction.
class GhosttyProvider: TerminalProvider {
    let name = "ghostty"
    let bundleIdentifier = "com.mitchellh.ghostty"

    func focusedSurface() -> FocusedSurface? {
        let script = """
            tell application "Ghostty"
                set t to focused terminal of selected tab of front window
                return (id of t) & "|" & (name of selected tab of front window)
            end tell
            """
        guard let appleScript = NSAppleScript(source: script) else { return nil }
        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        guard error == nil, let raw = result.stringValue else { return nil }

        let id: String
        let tabName: String?
        if let sep = raw.firstIndex(of: "|") {
            id = String(raw[raw.startIndex..<sep])
            let after = raw.index(after: sep)
            tabName = after < raw.endIndex ? String(raw[after...]) : nil
        } else {
            id = raw
            tabName = nil
        }
        return FocusedSurface(id: id, tabName: tabName)
    }

    func liveSurfaceIds() -> Set<String> {
        let script = """
            tell application "Ghostty"
                set output to ""
                repeat with w in every window
                    repeat with t in every tab of w
                        set output to output & id of focused terminal of t & linefeed
                    end repeat
                end repeat
                return output
            end tell
            """
        guard let appleScript = NSAppleScript(source: script) else { return [] }
        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        guard error == nil, let output = result.stringValue else { return [] }
        return Set(output.split(separator: "\n").map(String.init).filter { !$0.isEmpty })
    }

    func focusSurface(session: SessionInfo, ttyMap: [String: String]) {
        let tty = session.terminal_session_id
        debugLog("GhosttyProvider.focus: tty=\(tty) ghostty_terminal_id=\(session.ghostty_terminal_id ?? "nil")")

        var uuid: String?
        if let gid = session.ghostty_terminal_id, !gid.isEmpty {
            uuid = gid
        } else if let mapped = ttyMap[tty] {
            uuid = mapped
        } else if tty.contains("-") {
            // Old session with UUID directly in terminal_session_id
            uuid = tty
        }

        if let uuid = uuid {
            let script = "tell application \"Ghostty\" to focus terminal id \"\(uuid)\""
            debugLog("GhosttyProvider.focus: running AppleScript: \(script)")
            if let appleScript = NSAppleScript(source: script) {
                var error: NSDictionary?
                appleScript.executeAndReturnError(&error)
                if let error = error {
                    debugLog("GhosttyProvider.focus: AppleScript error: \(error)")
                } else {
                    debugLog("GhosttyProvider.focus: success")
                    return
                }
            }
        }
        // Fallback: just activate the app
        debugLog("GhosttyProvider.focus: falling back to activate")
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first?.activate()
    }

    func matchSessions(_ sessions: [SessionInfo], toSurface surface: FocusedSurface, ttyMap: [String: String]) -> [SessionInfo] {
        let ghosttySessions = sessions.filter { $0.terminal == name }

        // 1. Direct ghostty_terminal_id match
        var candidates = ghosttySessions.filter { $0.ghostty_terminal_id == surface.id }

        if candidates.isEmpty {
            // 2. ttyMap reverse-lookup (old sessions without ghostty_terminal_id)
            let matchedTTYs = Set(ttyMap.filter { $0.value == surface.id }.map { $0.key })
            candidates = ghosttySessions.filter { matchedTTYs.contains($0.terminal_session_id) }

            // 3. Backward compat: direct UUID in terminal_session_id
            let candidateIds = Set(candidates.map { $0.session_id })
            candidates += ghosttySessions.filter {
                $0.terminal_session_id == surface.id && !candidateIds.contains($0.session_id)
            }
        }

        // 4. CWD fallback via tab name
        if candidates.isEmpty, let tabName = surface.tabName, !tabName.isEmpty {
            let home = NSHomeDirectory()
            var cwdCandidates: [String] = []
            if tabName.hasPrefix("~") {
                cwdCandidates.append(home + tabName.dropFirst())
            } else if tabName.hasPrefix("/") {
                cwdCandidates.append(tabName)
            }
            for token in tabName.split(separator: " ").map(String.init) {
                if token.hasPrefix("~") {
                    cwdCandidates.append(home + token.dropFirst())
                } else if token.hasPrefix("/") {
                    cwdCandidates.append(token)
                }
            }
            for tabCWD in cwdCandidates {
                candidates = ghosttySessions.filter {
                    $0.cwd == tabCWD || $0.cwd.hasPrefix(tabCWD + "/")
                }
                if !candidates.isEmpty { break }
            }
        }

        return candidates
    }

    func relinkSession(_ session: SessionInfo) -> String? {
        let script = "tell application \"Ghostty\" to return id of focused terminal of selected tab of front window"
        guard let appleScript = NSAppleScript(source: script) else { return nil }
        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        if error != nil { return nil }
        guard let uuid = result.stringValue, !uuid.isEmpty else { return nil }
        return uuid
    }
}
