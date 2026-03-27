import Cocoa
import ClaudeMonitorCore

/// iTerm2 terminal provider — uses AppleScript for session detection and switching.
class ITerm2Provider: TerminalProvider {
    let name = "iterm2"
    let bundleIdentifier = "com.googlecode.iterm2"

    func focusedSurface() -> FocusedSurface? {
        let script = """
            tell application "iTerm2"
                get unique id of current session of current tab of current window
            end tell
            """
        guard let appleScript = NSAppleScript(source: script) else { return nil }
        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        guard error == nil, let guid = result.stringValue else { return nil }
        return FocusedSurface(id: guid)
    }

    func focusSurface(session: SessionInfo, ttyMap: [String: String]) {
        // sessionId format from ITERM_SESSION_ID: "w0t0p0:GUID"
        let parts = session.terminal_session_id.split(separator: ":")
        guard parts.count >= 2 else {
            if let appleScript = NSAppleScript(source: "tell application \"iTerm2\" to activate") {
                var error: NSDictionary?
                appleScript.executeAndReturnError(&error)
            }
            return
        }
        let uniqueId = String(parts[1])
        let script = """
            tell application "iTerm2"
                activate
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if unique id of s is "\(uniqueId)" then
                                select t
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }

    func matchSessions(_ sessions: [SessionInfo], toSurface surface: FocusedSurface, ttyMap: [String: String]) -> [SessionInfo] {
        // surface.id is the GUID from iTerm2. terminal_session_id format: "w0t0p0:GUID"
        return sessions.filter { session in
            guard session.terminal == name else { return false }
            let parts = session.terminal_session_id.split(separator: ":")
            return parts.count >= 2 && String(parts[1]) == surface.id
        }
    }
}
