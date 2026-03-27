import Cocoa
import ClaudeMonitorCore

/// macOS Terminal.app provider — uses AppleScript for TTY-based detection and switching.
class TerminalAppProvider: TerminalProvider {
    let name = "terminal"
    let bundleIdentifier = "com.apple.Terminal"

    func focusedSurface() -> FocusedSurface? {
        let script = """
            tell application "Terminal"
                get tty of selected tab of front window
            end tell
            """
        guard let appleScript = NSAppleScript(source: script) else { return nil }
        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        guard error == nil, let tty = result.stringValue else { return nil }
        return FocusedSurface(id: tty)
    }

    func focusSurface(session: SessionInfo, ttyMap: [String: String]) {
        let ttyPath = session.terminal_session_id
        let script = """
            tell application "Terminal"
                activate
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(ttyPath)" then
                            set selected tab of w to t
                            set index of w to 1
                            return
                        end if
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
        // surface.id is the TTY path. Direct match against terminal_session_id.
        return sessions.filter { $0.terminal == name && $0.terminal_session_id == surface.id }
    }
}
