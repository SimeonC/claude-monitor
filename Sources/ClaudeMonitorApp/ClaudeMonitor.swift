import Cocoa
import Combine
import SwiftUI
import ClaudeMonitorCore

// MARK: - Team Reader

class TeamReader: ObservableObject {
    @Published var teamsBySession: [String: TeamInfo] = [:]
    private var watcher: DirectoryWatcher?

    private let teamsDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude/teams"
    }()

    private let tasksDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude/tasks"
    }()

    init() {
        readTeams()
        watcher = DirectoryWatcher(paths: [teamsDir, tasksDir], latency: 0.5) { [weak self] in
            DispatchQueue.main.async { self?.readTeams() }
        }
    }

    func readTeams() {
        let fm = FileManager.default
        guard let teamDirs = try? fm.contentsOfDirectory(atPath: teamsDir) else {
            DispatchQueue.main.async { self.teamsBySession = [:] }
            return
        }

        var result: [String: TeamInfo] = [:]

        for teamDir in teamDirs {
            let configPath = "\(teamsDir)/\(teamDir)/config.json"
            guard let data = fm.contents(atPath: configPath),
                let config = try? JSONDecoder().decode(TeamConfig.self, from: data),
                let leadSessionId = config.leadSessionId, !leadSessionId.isEmpty
            else { continue }

            let members = config.members ?? []
            let activeCount = members.filter { ($0.isActive ?? false) }.count

            // Read tasks for this team
            var tasks: [TaskInfo] = []
            let teamTasksDir = "\(tasksDir)/\(teamDir)"
            if let taskFiles = try? fm.contentsOfDirectory(atPath: teamTasksDir) {
                for taskFile in taskFiles where taskFile.hasSuffix(".json") {
                    let taskPath = "\(teamTasksDir)/\(taskFile)"
                    if let taskData = fm.contents(atPath: taskPath),
                        let task = try? JSONDecoder().decode(TaskInfo.self, from: taskData)
                    {
                        tasks.append(task)
                    }
                }
            }

            result[leadSessionId] = TeamInfo(
                name: config.name,
                activeAgentCount: activeCount,
                members: members,
                tasks: tasks
            )
        }

        DispatchQueue.main.async {
            self.teamsBySession = result
        }
    }

    /// Look up team info for a session, checking merged_session_ids for aggregated sessions.
    func teamInfo(for session: SessionInfo) -> TeamInfo? {
        if let info = teamsBySession[session.session_id] { return info }
        guard let mergedIds = session.merged_session_ids else { return nil }
        for sid in mergedIds {
            if let info = teamsBySession[sid] { return info }
        }
        return nil
    }
}

// MARK: - Directory Watcher (FSEvents)

class DirectoryWatcher {
    private var stream: FSEventStreamRef?

    init(paths: [String], latency: CFTimeInterval, callback: @escaping () -> Void) {
        let ctx = UnsafeMutablePointer<() -> Void>.allocate(capacity: 1)
        ctx.initialize(to: callback)

        var context = FSEventStreamContext(
            version: 0,
            info: ctx,
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let cfPaths = paths as CFArray
        stream = FSEventStreamCreate(
            nil,
            { _, info, _, _, _, _ in
                guard let info = info else { return }
                let cb = info.assumingMemoryBound(to: (() -> Void).self).pointee
                cb()
            },
            &context,
            cfPaths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        )

        if let stream = stream {
            FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            FSEventStreamStart(stream)
        }
    }

    func stop() {
        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    deinit { stop() }
}

// MARK: - Derived Session Data (in-memory, from JSONL scanning)

struct DerivedSessionData {
    var project: String
    var cwd: String
    var lastPrompt: String
    var agentCount: Int
    var jsonlMtime: Date?
    var jsonlBirthDate: Date?
    var jsonlPath: String?
}

// MARK: - Session Reader (polls directory)

class SessionReader: ObservableObject {
    @Published var sessions: [SessionInfo] = []
    private var livenessTimer: Timer?
    private var refreshTimer: Timer?
    private var dirSource: DirectoryWatcher?
    private var projectsWatcher: DirectoryWatcher?
    /// JSONL-derived data held in memory (never written to session files)
    private var derivedData: [String: DerivedSessionData] = [:]
    /// Session IDs whose session files have disappeared (deleted by SessionEnd hook).
    /// Prevents the recovery path from resurrecting intentionally ended sessions.
    private var endedSessionIds: Set<String> = []
    /// Tracks when each session first entered "ended" status (for grace period before cleanup).
    private var endedTimestamps: [String: Date] = [:]
    /// Session IDs that had files on the previous read cycle (used to detect disappearances).
    private var previousSessionFileIds: Set<String> = []
    /// Serial queue for all disk I/O and state mutations (keeps main thread free for UI)
    private let ioQueue = DispatchQueue(label: "com.claudemonitor.sessionio", qos: .userInitiated)

    private let sessionsDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude/monitor/sessions"
    }()

    private let projectsDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude/projects"
    }()

    init() {
        prunePreBootSessions()
        cleanupLegacyDiscoveredSessions()
        scanProjects()
        readSessions()

        // FSEvents: reload when session files change (1s coalescing to avoid flicker)
        dirSource = DirectoryWatcher(paths: [sessionsDir], latency: 1.0) { [weak self] in
            self?.readSessions()
        }

        // FSEvents on projects dir: detect new/changed JSONL files
        projectsWatcher = DirectoryWatcher(paths: [projectsDir], latency: 1.0) { [weak self] in
            self?.scanProjects()
            self?.readSessions()
        }

        // Liveness timer: prune dead sessions (absence of writes can't trigger FSEvents)
        livenessTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) {
            [weak self] _ in
            self?.pruneDeadSessions()
        }

        // Periodic refresh: pick up changes even if FSEvents misses them
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) {
            [weak self] _ in
            self?.scanProjects()
            self?.readSessions()
        }
    }

    /// Delete session files last updated before the most recent boot.
    private func prunePreBootSessions() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
        task.arguments = ["-n", "kern.boottime"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
        } catch { return }

        let output =
            String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let secRange = output.range(of: "sec = "),
            let secEnd = output[secRange.upperBound...].firstIndex(of: ","),
            let bootEpoch = TimeInterval(
                output[secRange.upperBound..<secEnd].trimmingCharacters(in: .whitespaces))
        else { return }
        let bootTime = Date(timeIntervalSince1970: bootEpoch)

        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: sessionsDir) else { return }
        let isoFormatter = ISO8601DateFormatter()

        for file in files where file.hasSuffix(".json") {
            let path = "\(sessionsDir)/\(file)"
            guard let data = fm.contents(atPath: path),
                let session = try? JSONDecoder().decode(SessionInfo.self, from: data)
            else { continue }

            isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var updated = isoFormatter.date(from: session.updated_at)
            if updated == nil {
                isoFormatter.formatOptions = [.withInternetDateTime]
                updated = isoFormatter.date(from: session.updated_at)
            }
            if let updated = updated, updated < bootTime {
                try? fm.removeItem(atPath: path)
                try? fm.removeItem(atPath: "\(sessionsDir)/\(session.session_id).context")
                try? fm.removeItem(atPath: "\(sessionsDir)/\(session.session_id).model")
                NSLog(
                    "[ClaudeMonitor] Pre-boot session %@ (updated %@) — deleted",
                    session.session_id, session.updated_at)
            }
        }
    }

    /// Delete legacy `discovered-*` session files.
    private func cleanupLegacyDiscoveredSessions() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: sessionsDir) else { return }
        for file in files where file.hasPrefix("discovered-") && file.hasSuffix(".json") {
            let path = "\(sessionsDir)/\(file)"
            try? fm.removeItem(atPath: path)
            NSLog("[ClaudeMonitor] Legacy discovered session %@ — deleted", file)
        }
    }

    /// Read the tail of a JSONL file to extract cwd, latest user prompt, timestamp, and whether it's a subagent.
    /// Reads up to 64KB to ensure large assistant responses don't push user messages out of the window.
    private func readJSONLTail(path: String) -> (
        cwd: String, prompt: String, timestamp: String?, isSubagent: Bool
    ) {
        guard let fileHandle = FileHandle(forReadingAtPath: path) else {
            return ("", "", nil, false)
        }
        defer { fileHandle.closeFile() }

        let fileSize = fileHandle.seekToEndOfFile()
        guard fileSize > 0 else { return ("", "", nil, false) }
        let readSize: UInt64 = min(fileSize, 65536)
        fileHandle.seek(toFileOffset: fileSize - readSize)
        let data = fileHandle.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return ("", "", nil, false) }

        let lines = text.components(separatedBy: "\n")
        var cwd = ""
        var timestamp: String? = nil
        var isSubagent = false

        for line in lines {
            guard !line.isEmpty,
                let lineData = line.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            if let ts = json["timestamp"] as? String {
                timestamp = ts
            }
            if let c = json["cwd"] as? String, !c.isEmpty {
                cwd = c
            }
            if json["agentName"] != nil {
                isSubagent = true
            }
        }

        // Search backwards for the last non-blank, non-skipped user message
        var prompt = ""
        for line in lines.reversed() {
            guard !line.isEmpty,
                let lineData = line.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            if let type = json["type"] as? String, type == "user",
                !isSubagent,
                let message = json["message"] as? [String: Any],
                let content = message["content"] as? String,
                !content.hasPrefix("<teammate-message"),
                !content.hasPrefix("<local-command"),
                !content.hasPrefix("<command-name>"),
                !content.hasPrefix("<task-notification>"),
                !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                prompt = String(content.prefix(200))
                break
            }
        }

        return (cwd, prompt, timestamp, isSubagent)
    }

    /// Find the JSONL file path for a session ID by scanning project directories.
    private func findJSONLPath(sessionId: String) -> String? {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: projectsDir) else { return nil }
        for projectDir in projectDirs {
            let candidatePath = "\(projectsDir)/\(projectDir)/\(sessionId).jsonl"
            if fm.fileExists(atPath: candidatePath) {
                return candidatePath
            }
        }
        return nil
    }

    /// Scan `~/.claude/projects/` JSONL files to populate in-memory derivedData.
    /// No session files are written — readSessions() merges this data at display time.
    func scanProjects() {
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            let fm = FileManager.default
            guard let projectDirs = try? fm.contentsOfDirectory(atPath: self.projectsDir) else { return }
            let now = Date()
            let twoMinAgo = now.addingTimeInterval(-120)

            var newDerived: [String: DerivedSessionData] = [:]

            for projectDir in projectDirs {
                let projectPath = "\(self.projectsDir)/\(projectDir)"

                // Only look at top-level .jsonl files (skip subdirectories like session dirs and subagents/)
                guard let files = try? fm.contentsOfDirectory(atPath: projectPath) else { continue }

                for file in files where file.hasSuffix(".jsonl") {
                    let jsonlPath = "\(projectPath)/\(file)"

                    // Check mtime — only active sessions (modified within 2 min)
                    guard let attrs = try? fm.attributesOfItem(atPath: jsonlPath),
                        let mtime = attrs[.modificationDate] as? Date
                    else { continue }
                    guard mtime > twoMinAgo else { continue }

                    let sessionId = String(file.dropLast(6))  // remove ".jsonl"

                    // Read last ~4KB to extract info
                    let (cwd, lastPrompt, _, isSubagent) = self.readJSONLTail(path: jsonlPath)

                    // Skip subagent sessions (team members, Task tool agents)
                    if isSubagent { continue }

                    // No cwd in tail → can't determine project, skip
                    if cwd.isEmpty { continue }

                    let project = (cwd as NSString).lastPathComponent

                    // Count active subagents
                    let subagentsDir = "\(projectPath)/\(sessionId)/subagents"
                    var agentCount = 0
                    if let subFiles = try? fm.contentsOfDirectory(atPath: subagentsDir) {
                        for subFile in subFiles where subFile.hasSuffix(".jsonl") {
                            let subPath = "\(subagentsDir)/\(subFile)"
                            if let subAttrs = try? fm.attributesOfItem(atPath: subPath),
                                let subMtime = subAttrs[.modificationDate] as? Date,
                                subMtime > twoMinAgo
                            {
                                agentCount += 1
                            }
                        }
                    }

                    // Preserve previously cached prompt when JSONL tail doesn't contain one
                    let effectivePrompt = lastPrompt.isEmpty
                        ? (self.derivedData[sessionId]?.lastPrompt ?? "")
                        : lastPrompt

                    let birthDate = attrs[.creationDate] as? Date
                    newDerived[sessionId] = DerivedSessionData(
                        project: project,
                        cwd: cwd,
                        lastPrompt: effectivePrompt,
                        agentCount: agentCount,
                        jsonlMtime: mtime,
                        jsonlBirthDate: birthDate,
                        jsonlPath: jsonlPath
                    )
                }
            }

            self.derivedData = newDerived
        }
    }

    /// Detect dead sessions and delete their files from disk.
    func pruneDeadSessions() {
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(atPath: self.sessionsDir) else { return }
            var currentSessions: [(session: SessionInfo, path: String)] = []
            for file in files where file.hasSuffix(".json") {
                let path = "\(self.sessionsDir)/\(file)"
                guard let data = fm.contents(atPath: path),
                    let session = try? JSONDecoder().decode(SessionInfo.self, from: data)
                else { continue }
                currentSessions.append((session, path))
            }
            guard !currentSessions.isEmpty else { return }

            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self = self else { return }
                var deadSessionIds: Set<String> = []

                var ttyMap: [String: [String]] = [:]
                var ghosttyTerminalIds: [String: [String]] = [:]
                var itermSessions: [(id: String, termSid: String)] = []

                for (session, _) in currentSessions {
                    if session.status == "dead" { continue }
                    if session.status == "idle" || session.status == "starting" || session.status == "ended" { continue }

                    if let jsonlPath = self.findJSONLPath(sessionId: session.session_id),
                        let attrs = try? FileManager.default.attributesOfItem(atPath: jsonlPath),
                        let mtime = attrs[.modificationDate] as? Date
                    {
                        if Date().timeIntervalSince(mtime) > 43200 {
                            deadSessionIds.insert(session.session_id)
                            continue
                        }
                        // Ghostty UUID sessions (contain "-") need AppleScript liveness check
                        if !session.terminal_session_id.contains("-") {
                            continue
                        }
                    }

                    if session.terminal_session_id.isEmpty {
                        continue
                    } else if session.terminal == "iterm2" {
                        itermSessions.append((session.session_id, session.terminal_session_id))
                    } else if session.terminal == "ghostty" && session.terminal_session_id.contains("-") {
                        ghosttyTerminalIds[session.terminal_session_id, default: []].append(session.session_id)
                    } else {
                        let ttyName = session.terminal_session_id.replacingOccurrences(
                            of: "/dev/", with: "")
                        ttyMap[ttyName, default: []].append(session.session_id)
                    }
                }

                // --- Fallback: Terminal/Ghostty TTY check ---
                if !ttyMap.isEmpty {
                    let ttys = ttyMap.keys.joined(separator: " ")
                    let script =
                        "for tty in \(ttys); do ps -t \"$tty\" -o comm= 2>/dev/null | grep -q claude || echo \"$tty\"; done"
                    if let output = self.runShell(script) {
                        for tty in output.split(separator: "\n").map(String.init) {
                            if let sids = ttyMap[tty] { deadSessionIds.formUnion(sids) }
                        }
                    }
                }

                // --- Ghostty terminal UUID liveness check ---
                if !ghosttyTerminalIds.isEmpty {
                    let liveIds = self.liveGhosttyTerminalIds()
                    NSLog("[ClaudeMonitor] Ghostty liveness: live=%@ checking=%@",
                          liveIds.sorted().joined(separator: ","),
                          ghosttyTerminalIds.keys.sorted().joined(separator: ","))
                    if !liveIds.isEmpty {
                        for (termId, sids) in ghosttyTerminalIds where !liveIds.contains(termId) {
                            deadSessionIds.formUnion(sids)
                        }
                    }
                }

                // --- Fallback: iTerm2 check ---
                if !itermSessions.isEmpty {
                    let itermRunning = NSWorkspace.shared.runningApplications.contains {
                        $0.bundleIdentifier == "com.googlecode.iterm2"
                    }
                    if !itermRunning {
                        deadSessionIds.formUnion(itermSessions.map(\.id))
                    } else {
                        var guidToSessionId: [String: String] = [:]
                        for s in itermSessions {
                            let parts = s.termSid.split(separator: ":")
                            if parts.count >= 2 {
                                guidToSessionId[String(parts[1])] = s.id
                            }
                        }

                        if !guidToSessionId.isEmpty {
                            let script = """
                                tell application "iTerm2"
                                    set results to ""
                                    repeat with w in windows
                                        repeat with t in tabs of w
                                            repeat with s in sessions of t
                                                try
                                                    set results to results & (unique ID of s) & "\t" & (tty of s) & "\n"
                                                end try
                                            end repeat
                                        end repeat
                                    end repeat
                                    return results
                                end tell
                                """
                            let task = Process()
                            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                            task.arguments = ["-e", script]
                            let pipe = Pipe()
                            task.standardOutput = pipe
                            task.standardError = FileHandle.nullDevice
                            if (try? task.run()) != nil {
                                task.waitUntilExit()
                                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                                let output = String(data: data, encoding: .utf8) ?? ""

                                var liveGuids: Set<String> = []
                                for line in output.split(separator: "\n") {
                                    let cols = line.split(separator: "\t", maxSplits: 1)
                                    guard cols.count == 2 else { continue }
                                    let guid = String(cols[0])
                                    guard guidToSessionId[guid] != nil else { continue }
                                    let ttyName = cols[1].replacingOccurrences(of: "/dev/", with: "")
                                        .trimmingCharacters(in: .whitespacesAndNewlines)
                                    let check =
                                        "ps -t \"\(ttyName)\" -o comm= 2>/dev/null | grep -q claude && echo LIVE"
                                    if let result = self.runShell(check),
                                        result.trimmingCharacters(in: .whitespacesAndNewlines) == "LIVE"
                                    {
                                        liveGuids.insert(guid)
                                    }
                                }

                                for (guid, sid) in guidToSessionId where !liveGuids.contains(guid) {
                                    deadSessionIds.insert(sid)
                                }
                            }
                        }
                    }
                }

                // --- Safety net: sessions stuck in "working" for 10+ min ---
                // Catches the SubagentStop race: SubagentStop fires after Stop and re-sets
                // the parent to "working", leaving it stuck indefinitely.
                for (session, _) in currentSessions
                where session.status == "working"
                    && !deadSessionIds.contains(session.session_id)
                    && session.isStale
                {
                    NSLog("[ClaudeMonitor] Pruning stuck-working session %@ (%@): no update for 10+ min",
                          session.session_id, session.project)
                    deadSessionIds.insert(session.session_id)
                }

                // Skip team leads with active agents
                for sid in Array(deadSessionIds) {
                    if self.sessionHasActiveTeam(sid) {
                        NSLog("[ClaudeMonitor] Skipping prune of team lead %@ (has active agents)", sid)
                        deadSessionIds.remove(sid)
                    }
                }

                // Cascade: delete child sessions when parent is dead
                for (session, _) in currentSessions {
                    guard let parentSid = session.parent_session_id,
                          session.status != "dead",
                          deadSessionIds.contains(parentSid) else { continue }
                    deadSessionIds.insert(session.session_id)
                    NSLog("[ClaudeMonitor] Child session %@ dead (parent %@ is dead)",
                          session.session_id, parentSid)
                }

                // Delete dead session files from disk
                let sessionsDir = self.sessionsDir
                self.ioQueue.async {
                    let fm = FileManager.default
                    for sid in deadSessionIds {
                        let path = "\(sessionsDir)/\(sid).json"
                        try? fm.removeItem(atPath: path)
                        try? fm.removeItem(atPath: "\(sessionsDir)/\(sid).context")
                        try? fm.removeItem(atPath: "\(sessionsDir)/\(sid).model")
                        NSLog("[ClaudeMonitor] Deleted dead session %@", sid)
                    }
                }
                self.readSessions()
            }
        }
    }

    /// Check if a session is a team lead with active agents (reads team files directly)
    private func sessionHasActiveTeam(_ sessionId: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let teamsDir = "\(home)/.claude/teams"
        let fm = FileManager.default
        guard let teamDirs = try? fm.contentsOfDirectory(atPath: teamsDir) else { return false }
        for teamDir in teamDirs {
            let configPath = "\(teamsDir)/\(teamDir)/config.json"
            guard let data = fm.contents(atPath: configPath),
                let config = try? JSONDecoder().decode(TeamConfig.self, from: data),
                config.leadSessionId == sessionId
            else { continue }
            let activeCount = (config.members ?? []).filter { $0.isActive ?? false }.count
            return activeCount > 0
        }
        return false
    }

    /// Return set of live Ghostty terminal UUIDs by enumerating all windows/tabs via AppleScript.
    private func liveGhosttyTerminalIds() -> Set<String> {
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

    /// Run a shell command and return stdout, or nil on failure
    private func runShell(_ script: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch { return nil }
    }

    /// Delete a session's files from disk.
    func deleteSession(_ id: String) {
        // Immediately remove from published list on main thread
        sessions.removeAll { $0.session_id == id }
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            let fm = FileManager.default
            try? fm.removeItem(atPath: "\(self.sessionsDir)/\(id).json")
            try? fm.removeItem(atPath: "\(self.sessionsDir)/\(id).context")
            try? fm.removeItem(atPath: "\(self.sessionsDir)/\(id).model")
            self.endedSessionIds.insert(id)
        }
    }

    /// Relink a Ghostty session to the currently focused terminal tab.
    func relinkGhosttySession(_ session: SessionInfo) {
        let script = "tell application \"Ghostty\" to return id of focused terminal of selected tab of front window"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            guard let appleScript = NSAppleScript(source: script) else { return }
            var error: NSDictionary?
            let result = appleScript.executeAndReturnError(&error)
            guard error == nil, let termId = result.stringValue, !termId.isEmpty else { return }
            let sessionId = session.session_id

            // Persist to disk first (on ioQueue), then update in-memory model on main.
            // This prevents a concurrent readSessions() from overwriting the change.
            self.ioQueue.async {
                let path = "\(self.sessionsDir)/\(sessionId).json"
                guard let data = FileManager.default.contents(atPath: path),
                      var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return }
                json["terminal_session_id"] = termId
                if let updated = try? JSONSerialization.data(withJSONObject: json),
                   let str = String(data: updated, encoding: .utf8) {
                    let tmp = path + ".tmp"
                    try? str.write(toFile: tmp, atomically: true, encoding: .utf8)
                    try? FileManager.default.moveItem(atPath: tmp, toPath: path)
                }
                DispatchQueue.main.async {
                    if let idx = self.sessions.firstIndex(where: { $0.session_id == sessionId }) {
                        self.sessions[idx].terminal_session_id = termId
                    }
                }
            }
        }
    }

    func readSessions() {
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            self._readSessionsOnIOQueue()
        }
    }

    /// Actual readSessions implementation — must be called on ioQueue.
    private func _readSessionsOnIOQueue() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: sessionsDir) else {
            DispatchQueue.main.async { self.sessions = [] }
            return
        }

        let isoFmt = ISO8601DateFormatter()
        let now = Date()
        var loaded: [SessionInfo] = []
        var loadedIds: Set<String> = []
        var currentFileIds: Set<String> = []

        for file in files where file.hasSuffix(".json") {
            let path = "\(sessionsDir)/\(file)"
            guard let data = fm.contents(atPath: path) else { continue }
            // Delete empty/corrupt session files so the hook can recreate them
            if data.isEmpty {
                try? fm.removeItem(atPath: path)
                continue
            }
            do {
                var session = try JSONDecoder().decode(SessionInfo.self, from: data)
                currentFileIds.insert(session.session_id)
                // Dead sessions: delete from disk and skip
                if session.status == "dead" {
                    try? fm.removeItem(atPath: path)
                    try? fm.removeItem(atPath: "\(sessionsDir)/\(session.session_id).context")
                    try? fm.removeItem(atPath: "\(sessionsDir)/\(session.session_id).model")
                    continue
                }
                // Ended sessions: don't show in UI; give 5s grace for SessionStart to reactivate
                if session.status == "ended" {
                    if endedTimestamps[session.session_id] == nil {
                        endedTimestamps[session.session_id] = now
                    }
                    if now.timeIntervalSince(endedTimestamps[session.session_id]!) >= 5 {
                        // Grace period expired — clean up
                        try? fm.removeItem(atPath: path)
                        try? fm.removeItem(atPath: "\(sessionsDir)/\(session.session_id).context")
                        try? fm.removeItem(atPath: "\(sessionsDir)/\(session.session_id).model")
                        endedTimestamps.removeValue(forKey: session.session_id)
                        endedSessionIds.insert(session.session_id)
                    }
                    continue
                }
                // Session reactivated from "ended" — clear its timestamp
                endedTimestamps.removeValue(forKey: session.session_id)
                // Read context_pct from sidecar file
                let contextPath = "\(sessionsDir)/\(session.session_id).context"
                if let contextData = fm.contents(atPath: contextPath),
                   let contextStr = String(data: contextData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   let pct = Int(contextStr) {
                    session.context_pct = pct
                }
                // Read model from sidecar file
                let modelPath = "\(sessionsDir)/\(session.session_id).model"
                if let modelData = fm.contents(atPath: modelPath),
                   let modelStr = String(data: modelData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !modelStr.isEmpty {
                    session.model = modelStr
                }
                // Enrich with JSONL-derived data (project, cwd, last_prompt, agent_count)
                if let derived = derivedData[session.session_id] {
                    if session.project == "unknown" || session.cwd.isEmpty {
                        session.project = derived.project
                        session.cwd = derived.cwd
                    }
                    if !derived.lastPrompt.isEmpty {
                        session.last_prompt = derived.lastPrompt
                    }
                    session.agent_count = derived.agentCount
                }
                loaded.append(session)
                loadedIds.insert(session.session_id)
            } catch {
                NSLog(
                    "[ClaudeMonitor] Deleting corrupt session file %@: %@", file,
                    error.localizedDescription)
                try? fm.removeItem(atPath: path)
            }
        }

        // Track session files that disappeared since last read (deleted by SessionEnd hook)
        let disappeared = self.previousSessionFileIds.subtracting(currentFileIds)
        self.endedSessionIds.formUnion(disappeared)
        self.previousSessionFileIds = currentFileIds

        // Recovery: for derivedData entries with active JSONL but no session file,
        // create in-memory SessionInfo (monitor restart recovery / session file not yet written).
        // derivedData only holds JSONL modified within the last 2 minutes, so any entry here
        // represents an active session. Use JSONL birth date as started_at proxy.
        isoFmt.formatOptions = [.withInternetDateTime]
        let nowString = isoFmt.string(from: now)
        for (sessionId, derived) in derivedData {
            guard !loadedIds.contains(sessionId) else { continue }
            guard !self.endedSessionIds.contains(sessionId) else { continue }
            // Use JSONL birth date as the best proxy for session start time.
            // Fall back to mtime, then now (last resort).
            let startDate = derived.jsonlBirthDate ?? derived.jsonlMtime ?? now
            let startedAtString = isoFmt.string(from: startDate)
            let session = SessionInfo(
                session_id: sessionId, status: "idle",
                project: derived.project, cwd: derived.cwd,
                terminal: "", terminal_session_id: "",
                started_at: startedAtString, updated_at: nowString,
                last_prompt: derived.lastPrompt,
                agent_count: derived.agentCount
            )
            loaded.append(session)
        }

        // --- Sub-agent aggregation: propagate child attention to parent, hide child rows ---
        // Partition into parent and child sessions
        var childSessions: [SessionInfo] = []
        var parentSessions: [SessionInfo] = []
        for s in loaded {
            if s.parent_session_id != nil {
                childSessions.append(s)
            } else {
                parentSessions.append(s)
            }
        }

        // For each parent: if ANY non-dead child has status == "attention", override parent display to "attention"
        if !childSessions.isEmpty {
            var parentHasChildAttention: Set<String> = []
            for child in childSessions {
                guard let parentSid = child.parent_session_id, child.status == "attention" else { continue }
                parentHasChildAttention.insert(parentSid)
            }
            for i in parentSessions.indices {
                if parentHasChildAttention.contains(parentSessions[i].session_id) {
                    // Only escalate if parent isn't already in attention (or dead)
                    if parentSessions[i].status != "dead" && parentSessions[i].status != "attention" {
                        parentSessions[i].status = "attention"
                    }
                }
            }
        }
        // Replace loaded with parent-only sessions (children are hidden from UI)
        loaded = parentSessions

        // Aggregate sessions with the same project name
        var aggregated = aggregateSessions(loaded, referenceDate: Date())

        // Sort by project → numeric terminal_session_id → string terminal_session_id → cwd
        aggregated.sort {
            let cmp = $0.project.localizedCaseInsensitiveCompare($1.project)
            if cmp != .orderedSame { return cmp == .orderedAscending }
            let tid0 = $0.terminal_session_id
            let tid1 = $1.terminal_session_id
            // Numeric comparison when both are pure digits
            if let n0 = Int(tid0), let n1 = Int(tid1) { return n0 < n1 }
            if tid0 != tid1 { return tid0 < tid1 }
            return $0.cwd.localizedCaseInsensitiveCompare($1.cwd) == .orderedAscending
        }

        // Debug: dump pipeline state to JSON for diagnosing status bugs
        dumpDebugState(aggregated: aggregated)

        DispatchQueue.main.async {
            self.sessions = aggregated
        }
    }

    /// Write current pipeline state to ~/.claude/monitor/debug.json for diagnosis.
    private func dumpDebugState(aggregated: [SessionInfo]) {
        let debugPath = "\(sessionsDir)/../debug.json"
        let isoFmt = ISO8601DateFormatter()
        isoFmt.formatOptions = [.withInternetDateTime]
        let nowStr = isoFmt.string(from: Date())

        var debugDict: [String: Any] = ["timestamp": nowStr]

        // Final aggregated sessions (what the UI shows)
        debugDict["sessions"] = aggregated.map { s -> [String: Any] in
            var d: [String: Any] = [
                "session_id": s.session_id,
                "status": s.status,
                "project": s.project,
                "cwd": s.cwd,
                "updated_at": s.updated_at,
                "terminal_session_id": s.terminal_session_id,
            ]
            if let pct = s.context_pct { d["context_pct"] = pct }
            if let m = s.model { d["model"] = m }
            if s.skip_permissions == true { d["skip_permissions"] = true }
            if s.agent_count > 0 { d["agent_count"] = s.agent_count }
            if let parent = s.parent_session_id { d["parent_session_id"] = parent }
            return d
        }

        if let data = try? JSONSerialization.data(
            withJSONObject: debugDict, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: data, encoding: .utf8)
        {
            try? str.write(toFile: debugPath, atomically: true, encoding: .utf8)
        }
    }

}

// MARK: - Active Session Tracker

class ActiveSessionTracker: ObservableObject {
    @Published var activeSessionId: String?
    private weak var sessionReader: SessionReader?
    private var pollTimer: Timer?
    private var workspaceObserver: Any?
    private let backgroundQueue = DispatchQueue(label: "com.claudemonitor.activesession", qos: .utility)

    private let terminalBundleIds: Set<String> = [
        "com.mitchellh.ghostty",
        "com.googlecode.iterm2",
        "com.apple.Terminal",
    ]

    init(sessionReader: SessionReader) {
        self.sessionReader = sessionReader
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleAppActivation(notification)
        }
        // Check current app on init
        if let app = NSWorkspace.shared.frontmostApplication,
           let bundleId = app.bundleIdentifier,
           terminalBundleIds.contains(bundleId) {
            startPolling()
        }
    }

    deinit {
        if let obs = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        pollTimer?.invalidate()
    }

    private func handleAppActivation(_ notification: Notification) {
        guard let app = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication),
              let bundleId = app.bundleIdentifier else {
            stopPolling()
            return
        }
        if terminalBundleIds.contains(bundleId) {
            startPolling()
        } else {
            stopPolling()
        }
    }

    private func startPolling() {
        detectActiveSession()  // immediate first check
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.detectActiveSession()
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        if activeSessionId != nil {
            activeSessionId = nil
        }
    }

    private func detectActiveSession() {
        guard let sessions = sessionReader?.sessions, !sessions.isEmpty else { return }
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleId = app.bundleIdentifier else { return }

        if bundleId == "com.mitchellh.ghostty" {
            detectGhosttySession(app: app, sessions: sessions)
        } else if bundleId == "com.googlecode.iterm2" {
            detectITerm2Session(sessions: sessions)
        } else if bundleId == "com.apple.Terminal" {
            detectTerminalSession(sessions: sessions)
        }
    }

    private func detectGhosttySession(app: NSRunningApplication, sessions: [SessionInfo]) {
        let script = "tell application \"Ghostty\" to return id of focused terminal of selected tab of front window"
        backgroundQueue.async { [weak self] in
            guard let appleScript = NSAppleScript(source: script) else { return }
            var error: NSDictionary?
            let result = appleScript.executeAndReturnError(&error)
            guard error == nil, let termId = result.stringValue else {
                DispatchQueue.main.async { self?.activeSessionId = nil }
                return
            }
            let ghosttySessions = sessions.filter { $0.terminal == "ghostty" }
            debugLog("detectGhostty: focused=\(termId) ghosttySessions=\(ghosttySessions.map { "\($0.session_id)=\($0.terminal_session_id)" }.joined(separator: ", "))")
            let matched = sessions.first { session in
                session.terminal == "ghostty" && session.terminal_session_id == termId
            }
            DispatchQueue.main.async { self?.activeSessionId = matched?.session_id }
        }
    }

    private func detectITerm2Session(sessions: [SessionInfo]) {
        let script = """
            tell application "iTerm2"
                get unique id of current session of current tab of current window
            end tell
            """
        backgroundQueue.async { [weak self] in
            guard let appleScript = NSAppleScript(source: script) else { return }
            var error: NSDictionary?
            let result = appleScript.executeAndReturnError(&error)
            guard error == nil, let guid = result.stringValue else {
                DispatchQueue.main.async { self?.activeSessionId = nil }
                return
            }
            let matched = sessions.first { session in
                // terminal_session_id format: "w0t0p0:GUID"
                let parts = session.terminal_session_id.split(separator: ":")
                return parts.count >= 2 && String(parts[1]) == guid
            }
            DispatchQueue.main.async { self?.activeSessionId = matched?.session_id }
        }
    }

    private func detectTerminalSession(sessions: [SessionInfo]) {
        let script = """
            tell application "Terminal"
                get tty of selected tab of front window
            end tell
            """
        backgroundQueue.async { [weak self] in
            guard let appleScript = NSAppleScript(source: script) else { return }
            var error: NSDictionary?
            let result = appleScript.executeAndReturnError(&error)
            guard error == nil, let tty = result.stringValue else {
                DispatchQueue.main.async { self?.activeSessionId = nil }
                return
            }
            let matched = sessions.first { $0.terminal_session_id == tty }
            DispatchQueue.main.async { self?.activeSessionId = matched?.session_id }
        }
    }
}

// MARK: - Debug Logging

private let debugLogPath = NSHomeDirectory() + "/.claude/monitor/debug.log"

func debugLog(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(message)\n"
    if let data = line.data(using: .utf8) {
        if let fh = FileHandle(forWritingAtPath: debugLogPath) {
            fh.seekToEndOfFile()
            fh.write(data)
            fh.closeFile()
        } else {
            FileManager.default.createFile(atPath: debugLogPath, contents: data)
        }
    }
}

// MARK: - Terminal Switcher

func switchToSession(_ session: SessionInfo) {
    debugLog("switchToSession: terminal=\(session.terminal) tty=\(session.terminal_session_id) project=\(session.project) sid=\(session.session_id)")
    if session.terminal == "iterm2" && !session.terminal_session_id.isEmpty {
        switchToITerm2(sessionId: session.terminal_session_id)
    } else if session.terminal == "ghostty" {
        switchToGhostty(sessionId: session.terminal_session_id)
    } else if session.terminal == "terminal" && !session.terminal_session_id.isEmpty {
        switchToTerminal(ttyPath: session.terminal_session_id)
    } else {
        NSLog("[ClaudeMonitor] falling back to cwd switch (no terminal info)")
        switchByTerminalCwd(cwd: session.cwd)
    }

}

func switchToITerm2(sessionId: String) {
    // sessionId format from ITERM_SESSION_ID: "w0t0p0:GUID"
    let parts = sessionId.split(separator: ":")
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

func switchToTerminal(ttyPath: String) {
    // Match Terminal.app tab by its tty device path
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


func switchToGhostty(sessionId: String) {
    debugLog("switchToGhostty: sessionId=\(sessionId)")
    if sessionId.contains("-") {
        // UUID — focus directly via AppleScript
        let script = "tell application \"Ghostty\" to focus terminal id \"\(sessionId)\""
        debugLog("switchToGhostty: running AppleScript: \(script)")
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let error = error {
                debugLog("switchToGhostty: AppleScript error: \(error)")
            } else {
                debugLog("switchToGhostty: success")
                return
            }
        }
    }
    // Fallback: just activate the app
    debugLog("switchToGhostty: falling back to activate")
    NSRunningApplication.runningApplications(withBundleIdentifier: "com.mitchellh.ghostty").first?.activate()
}

func switchByTerminalCwd(cwd: String) {
    // Fallback: detect which terminal is running and activate it
    if NSRunningApplication.runningApplications(withBundleIdentifier: "com.mitchellh.ghostty").first != nil {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.mitchellh.ghostty").first?.activate()
        return
    }
    if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.googlecode.iterm2" }) {
        if let appleScript = NSAppleScript(source: "tell application \"iTerm2\" to activate") {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
        return
    }
    if let appleScript = NSAppleScript(source: "tell application \"Terminal\" to activate") {
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
    }
}

// MARK: - Pulsing Dot View

struct PulsingDot: View {
    let color: Color
    let isPulsing: Bool

    @State private var scale: CGFloat = 1.0

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .scaleEffect(scale)
            .shadow(color: color.opacity(0.6), radius: isPulsing ? 4 : 0)
            .onAppear {
                if isPulsing {
                    withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                        scale = 1.4
                    }
                }
            }
            .onChange(of: isPulsing) { _, newValue in
                if newValue {
                    withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                        scale = 1.4
                    }
                } else {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        scale = 1.0
                    }
                }
            }
    }
}

// MARK: - Session Row View

struct SessionRowView: View {
    let session: SessionInfo
    var teamInfo: TeamInfo? = nil
    var isActive: Bool = false
    var disambiguationSuffix: String? = nil
    @State private var isHovered = false
    @State private var badgeScale: CGFloat = 1.0

    private var isDanger: Bool { session.skip_permissions == true }
    private var hasTeam: Bool { teamInfo != nil }

    private var badgeCount: Int {
        let teamCount = teamInfo?.activeAgentCount ?? 0
        // Subagents only run during a turn — if session is idle, agent_count is stale
        let agentCount = session.status == "working" ? session.agent_count : 0
        return max(teamCount, agentCount)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color(red: 45/255, green: 191/255, blue: 230/255).opacity(isActive ? 0.8 : 0))
                .frame(width: 3)
                .padding(.vertical, 4)
                .animation(.easeInOut(duration: 0.2), value: isActive)

            Spacer().frame(width: 6)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    if badgeCount > 0 || hasTeam {
                        HStack(spacing: 3) {
                            Image(systemName: hasTeam ? "person.3.fill" : "person.2.fill")
                                .font(.system(size: 8))
                            if badgeCount > 0 {
                                Text("\(badgeCount)")
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                            }
                        }
                        .foregroundColor(session.statusColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(isDanger ? Color.red.opacity(0.3) : session.statusColor.opacity(0.2))
                        )
                        .overlay(
                            isDanger ? Capsule().stroke(Color.red.opacity(0.5), lineWidth: 1) : nil
                        )
                        .scaleEffect(badgeScale)
                        .shadow(color: session.status == "working" ? session.statusColor.opacity(0.6) : .clear, radius: 4)
                        .onAppear {
                            if session.status == "working" {
                                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                                    badgeScale = 1.1
                                }
                            }
                        }
                        .onChange(of: session.status) { _, newValue in
                            if newValue == "working" {
                                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                                    badgeScale = 1.1
                                }
                            } else {
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    badgeScale = 1.0
                                }
                            }
                        }
                        .fixedSize()
                        .offset(y: 1)
                    } else if session.skip_permissions == true {
                        Image(systemName: "lock.open.fill")
                            .font(.system(size: 9))
                            .foregroundColor(session.statusColor)
                            .shadow(color: session.statusColor.opacity(0.6), radius: session.status == "working" ? 4 : 0)
                            .frame(width: 8, height: 8)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.red.opacity(0.3))
                                    .frame(width: 16, height: 16)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(Color.red.opacity(0.5), lineWidth: 1)
                                    .frame(width: 16, height: 16)
                            )
                            .offset(y: 1)
                    } else {
                        PulsingDot(
                            color: session.statusColor,
                            isPulsing: session.status == "working"
                        )
                        .offset(y: 1)
                    }

                    Text(session.project)
                        .font(.system(size: 13, weight: .semibold, design: .default))
                        .foregroundColor(session.isStale ? .gray : .white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)

                    if let suffix = disambiguationSuffix {
                        Text(suffix)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.white.opacity(0.35))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    Text(session.displayStatus)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(session.statusColor.opacity(session.isStale ? 0.6 : 1.0))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(session.statusColor.opacity(session.isStale ? 0.08 : 0.2))
                        )
                        .fixedSize()

                    if let pct = session.context_pct {
                        Text("\(pct)%")
                            .font(.system(size: 10.8, weight: .medium, design: .monospaced))
                            .foregroundColor(session.contextPctColor)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(session.contextPctColor.opacity(0.15)))
                            .fixedSize()
                    }

                }

                HStack(spacing: 6) {
                    if !session.last_prompt.isEmpty {
                        Text(session.last_prompt)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.55))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Spacer(minLength: 4)

                    Text(session.elapsedString)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5))
                        .fixedSize()

                    if let modelName = session.shortModelName {
                        Text(modelName)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.45))
                            .fixedSize()
                    }
                }
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .padding(.top, 0)
        .padding(.bottom, 8)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Header Bar

struct RefreshButton: View {
    var sessionReader: SessionReader?
    @State private var showCheck = false

    var body: some View {
        Button {
            sessionReader?.scanProjects()
            sessionReader?.readSessions()
            showCheck = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                showCheck = false
            }
        } label: {
            Text(showCheck ? "\u{2713}" : "\u{21BB}")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
        }
        .buttonStyle(.plain)
        .focusable(false)
    }
}

struct ShortcutButton: View {
    @ObservedObject var shortcutManager: ShortcutManager
    @State private var showPopover = false
    @State private var recordingSlot: Int?  // nil = not recording, 1 or 2
    @State private var recordingMonitor: Any?

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            Image(systemName: "keyboard")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Jump Shortcuts")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)

                    Text("Either shortcut will cycle between sessions")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                }

                VStack(alignment: .leading, spacing: 8) {
                    shortcutRow(slot: 1,
                                display: shortcutManager.displayString,
                                onClear: { shortcutManager.clear() })

                    shortcutRow(slot: 2,
                                display: shortcutManager.displayString2,
                                onClear: { shortcutManager.clear2() })
                }
            }
            .padding(14)
            .background(Color(nsColor: NSColor(red: 0.22, green: 0.10, blue: 0.42, alpha: 1.0)))
        }
        .onChange(of: showPopover) { _, newValue in
            if !newValue { stopRecording() }
        }
    }

    @ViewBuilder
    private func shortcutRow(slot: Int, display: String, onClear: @escaping () -> Void) -> some View {
        let isThisSlotRecording = recordingSlot == slot
        HStack(spacing: 8) {
            // Shortcut display doubles as Record button
            Button {
                if isThisSlotRecording {
                    stopRecording()
                } else {
                    startRecording(slot: slot)
                }
            } label: {
                Text(isThisSlotRecording ? "Press keys…" : display)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(isThisSlotRecording ? .orange : .white.opacity(0.9))
                    .frame(minWidth: 90)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(isThisSlotRecording ? 0.18 : 0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.white.opacity(isThisSlotRecording ? 0.3 : 0.12), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .focusable(false)

            // Clear (or Cancel when recording)
            Button {
                if isThisSlotRecording {
                    stopRecording()
                } else {
                    stopRecording()
                    onClear()
                }
            } label: {
                Text(isThisSlotRecording ? "Cancel" : "Clear")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(isThisSlotRecording ? 0.7 : 0.4))
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .focusable(false)
        }
    }

    private func startRecording(slot: Int) {
        stopRecording()  // cancel any active recording first
        recordingSlot = slot
        shortcutManager.uninstall()
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            let mask: NSEvent.ModifierFlags = [.control, .shift, .option, .command]
            let mods = event.modifierFlags.intersection(mask)
            guard !mods.isEmpty else {
                if event.keyCode == 53 { stopRecording() }
                return nil
            }
            if slot == 1 {
                shortcutManager.update(keyCode: event.keyCode, modifierFlags: mods)
            } else {
                shortcutManager.update2(keyCode: event.keyCode, modifierFlags: mods)
            }
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        recordingSlot = nil
        if let m = recordingMonitor {
            NSEvent.removeMonitor(m)
            recordingMonitor = nil
        }
        shortcutManager.install()
    }
}

struct HeaderBar: View {
    let sessions: [SessionInfo]
    var sessionReader: SessionReader?
    @ObservedObject var shortcutManager: ShortcutManager

    var attentionCount: Int { sessions.filter { $0.status == "attention" }.count }
    var workingCount: Int { sessions.filter { $0.status == "working" }.count }
    var idleCount: Int { sessions.filter { $0.status == "idle" }.count }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.7))
                Text("Claude")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
            }

            Spacer()

            HStack(spacing: 12) {
                if attentionCount > 0 {
                    HStack(spacing: 3) {
                        Circle().fill(Color.orange).frame(width: 6, height: 6)
                        Text("\(attentionCount)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.orange)
                    }
                    .fixedSize()
                }
                if workingCount > 0 {
                    HStack(spacing: 3) {
                        Circle().fill(Color.workingBlue).frame(width: 6, height: 6)
                        Text("\(workingCount)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.workingBlue)
                    }
                    .fixedSize()
                }
                if idleCount > 0 {
                    HStack(spacing: 3) {
                        Circle().fill(Color.doneGreen).frame(width: 6, height: 6)
                        Text("\(idleCount)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.doneGreen)
                    }
                    .fixedSize()
                }

                Text("\(sessions.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.4))
                    .fixedSize()

                ShortcutButton(shortcutManager: shortcutManager)
                    .fixedSize()
                RefreshButton(sessionReader: sessionReader)
                    .fixedSize()
            }
            .layoutPriority(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Main Content View

struct MonitorContentView: View {
    @ObservedObject var reader: SessionReader
    @ObservedObject var teamReader: TeamReader
    @ObservedObject var shortcutManager: ShortcutManager
    @ObservedObject var activeTracker: ActiveSessionTracker
    @State private var isExpanded = true

    /// Build a map of session_id → short disambiguating suffix for sessions that share a project name.
    /// Uses first-letter abbreviation of the first differing path component walking upward.
    private var disambiguationMap: [String: String] {
        // Group sessions by project name
        var byProject: [String: [SessionInfo]] = [:]
        for s in reader.sessions {
            byProject[s.project, default: []].append(s)
        }

        var result: [String: String] = [:]
        for (_, group) in byProject {
            guard group.count > 1 else { continue }

            // Split each cwd into path components (drop the project basename at the end)
            let paths: [(SessionInfo, [String])] = group.map { s in
                var comps = s.cwd.split(separator: "/").map(String.init)
                if !comps.isEmpty { comps.removeLast() } // drop basename (== project)
                return (s, comps)
            }

            // Walk from the end of the parent path upward to find the first diverging component
            let minLen = paths.map(\.1.count).min() ?? 0
            var diffIdx: Int? = nil
            for i in stride(from: minLen - 1, through: 0, by: -1) {
                let vals = Set(paths.map { $0.1[i] })
                if vals.count > 1 {
                    diffIdx = i
                    break
                }
            }

            if let idx = diffIdx {
                for (session, comps) in paths {
                    let diffComp = comps[idx]
                    result[session.session_id] = "\(diffComp)/\(session.project)"
                }
            } else {
                // All parent paths identical — fall back to full cwd
                for (session, _) in paths {
                    result[session.session_id] = session.cwd
                }
            }
        }
        return result
    }

    var body: some View {
        let disambigMap = disambiguationMap

        VStack(spacing: 0) {
            // Header — always visible, drag to move
            HeaderBar(
                sessions: reader.sessions, sessionReader: reader,
                shortcutManager: shortcutManager)

            if isExpanded && !reader.sessions.isEmpty {
                Divider()
                    .background(Color.white.opacity(0.1))

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(reader.sessions) { session in
                            SessionRowView(
                                session: session,
                                teamInfo: teamReader.teamInfo(for: session),
                                isActive: session.session_id == activeTracker.activeSessionId,
                                disambiguationSuffix: disambigMap[session.session_id]
                            )
                            .overlay(
                                FirstMouseClickArea(
                                    action: {
                                        switchToSession(session)
                                        activeTracker.activeSessionId = session.session_id
                                    },
                                    contextMenuBuilder: { event in
                                        let menu = NSMenu()
                                        if session.terminal == "ghostty" {
                                            menu.addItem(ClosureMenuItem("Relink to Focused Tab") {
                                                reader.relinkGhosttySession(session)
                                            })
                                        }
                                        menu.addItem(ClosureMenuItem("Delete Session") {
                                            reader.deleteSession(session.session_id)
                                        })
                                        return menu
                                    }
                                )
                            )
                            if session.id != reader.sessions.last?.id {
                                Divider()
                                    .background(Color.white.opacity(0.05))
                                    .padding(.horizontal, 12)
                            }
                        }
                    }
                    .background(ScrollbarStyler())
                }
                .frame(maxHeight: 600)
            }
        }
        .frame(width: 310)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: NSColor(red: 0.129, green: 0.016, blue: 0.314, alpha: 1.0)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
        )
    }
}

// MARK: - Custom Thin Scrollbar

class ThinScroller: NSScroller {
    override class func scrollerWidth(for controlSize: ControlSize, scrollerStyle: Style) -> CGFloat
    {
        return 5
    }

    override func drawKnob() {
        var knobRect = rect(for: .knob)
        knobRect = NSRect(
            x: bounds.width - 4,
            y: knobRect.origin.y + 2,
            width: 3,
            height: max(knobRect.height - 4, 8)
        )
        let path = NSBezierPath(roundedRect: knobRect, xRadius: 1.5, yRadius: 1.5)
        NSColor.white.withAlphaComponent(0.2).setFill()
        path.fill()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        // Transparent track — no background
    }
}

struct ScrollbarStyler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.setFrameSize(.zero)
        DispatchQueue.main.async {
            var superview = view.superview
            while let sv = superview {
                if let scrollView = sv as? NSScrollView {
                    scrollView.scrollerStyle = .overlay
                    scrollView.hasVerticalScroller = true
                    scrollView.autohidesScrollers = true
                    let scroller = ThinScroller()
                    scroller.controlSize = .mini
                    scrollView.verticalScroller = scroller
                    break
                }
                superview = sv.superview
            }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - NSVisualEffectView wrapper

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Floating Panel

class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.isMovableByWindowBackground = true
        self.ignoresMouseEvents = false
    }

    func restorePosition() {
        if let x = UserDefaults.standard.object(forKey: "monitorX") as? Double,
            let y = UserDefaults.standard.object(forKey: "monitorY") as? Double
        {
            self.setFrameOrigin(NSPoint(x: x, y: y))
        } else if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            // Top-right, below menu bar
            let x = screenFrame.maxX - 296
            let y = screenFrame.maxY - 60
            self.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    func savePosition() {
        UserDefaults.standard.set(self.frame.origin.x, forKey: "monitorX")
        UserDefaults.standard.set(self.frame.origin.y, forKey: "monitorY")
    }
}

// MARK: - Click-through Hosting View

class ClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - First-Mouse Click Overlay (drag-safe)

// Shared coordinator: collects all click areas, fires only the smallest on click
private class ClickAreaCoordinator {
    static let shared = ClickAreaCoordinator()
    private static let dragThreshold: CGFloat = 4

    private var areas: [WeakClickArea] = []
    private var monitors: [Any] = []
    private var mouseDownScreenLocation: NSPoint?

    private struct WeakClickArea {
        weak var view: FirstMouseClickArea.ClickNSView?
    }

    func register(_ view: FirstMouseClickArea.ClickNSView) {
        areas.removeAll { $0.view == nil }
        guard !areas.contains(where: { $0.view === view }) else { return }
        areas.append(WeakClickArea(view: view))
        installMonitors()
    }

    func unregister(_ view: FirstMouseClickArea.ClickNSView) {
        areas.removeAll { $0.view == nil || $0.view === view }
    }

    private func installMonitors() {
        guard monitors.isEmpty else { return }

        if let m = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
            self?.mouseDownScreenLocation = NSEvent.mouseLocation
            return event
        }) { monitors.append(m) }

        if let m = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] event in
            guard let self = self, let downLoc = self.mouseDownScreenLocation else { return event }
            self.mouseDownScreenLocation = nil

            let upLoc = NSEvent.mouseLocation
            let dx = abs(upLoc.x - downLoc.x)
            let dy = abs(upLoc.y - downLoc.y)
            guard dx < ClickAreaCoordinator.dragThreshold && dy < ClickAreaCoordinator.dragThreshold else {
                return event
            }

            // Find all areas that contain the click, pick the smallest
            var best: FirstMouseClickArea.ClickNSView?
            var bestArea: CGFloat = .greatestFiniteMagnitude
            for weak in self.areas {
                guard let view = weak.view, let window = view.window,
                      event.window === window else { continue }
                let loc = view.convert(event.locationInWindow, from: nil)
                if view.bounds.contains(loc) {
                    let area = view.bounds.width * view.bounds.height
                    if area < bestArea {
                        best = view
                        bestArea = area
                    }
                }
            }
            best?.action?()
            return event
        }) { monitors.append(m) }

        // Right-click: find smallest containing click area with a context menu builder
        if let m = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown, handler: { [weak self] event in
            guard let self = self else { return event }
            var best: FirstMouseClickArea.ClickNSView?
            var bestArea: CGFloat = .greatestFiniteMagnitude
            for weak in self.areas {
                guard let view = weak.view, view.contextMenuAction != nil,
                      let window = view.window, event.window === window else { continue }
                let loc = view.convert(event.locationInWindow, from: nil)
                if view.bounds.contains(loc) {
                    let area = view.bounds.width * view.bounds.height
                    if area < bestArea {
                        best = view
                        bestArea = area
                    }
                }
            }
            if let view = best, let menu = view.contextMenuAction?(event) {
                NSMenu.popUpContextMenu(menu, with: event, for: view)
                return nil  // consume the event
            }
            return event
        }) { monitors.append(m) }
    }
}

/// NSMenuItem that holds a closure — fires via target-action.
class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.target = self
    }
    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}

struct FirstMouseClickArea: NSViewRepresentable {
    let action: () -> Void
    var contextMenuBuilder: ((NSEvent) -> NSMenu?)?

    init(action: @escaping () -> Void) {
        self.action = action
        self.contextMenuBuilder = nil
    }

    init(action: @escaping () -> Void, contextMenuBuilder: @escaping (NSEvent) -> NSMenu?) {
        self.action = action
        self.contextMenuBuilder = contextMenuBuilder
    }

    func makeNSView(context: Context) -> ClickNSView {
        let view = ClickNSView()
        view.action = action
        view.contextMenuAction = contextMenuBuilder
        return view
    }
    func updateNSView(_ nsView: ClickNSView, context: Context) {
        nsView.action = action
        nsView.contextMenuAction = contextMenuBuilder
    }

    class ClickNSView: NSView {
        var action: (() -> Void)?
        var contextMenuAction: ((NSEvent) -> NSMenu?)?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                ClickAreaCoordinator.shared.register(self)
            } else {
                ClickAreaCoordinator.shared.unregister(self)
            }
        }

        override func removeFromSuperview() {
            ClickAreaCoordinator.shared.unregister(self)
            super.removeFromSuperview()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

// MARK: - Window Drag Handle (NSViewRepresentable)

struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DragHandleNSView { DragHandleNSView() }
    func updateNSView(_ nsView: DragHandleNSView, context: Context) {}

    class DragHandleNSView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

// MARK: - Shortcut Manager

class ShortcutManager: ObservableObject {
    @Published var keyCode: UInt16
    @Published var modifierFlags: NSEvent.ModifierFlags
    @Published var keyCode2: UInt16
    @Published var modifierFlags2: NSEvent.ModifierFlags

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private let onTrigger: () -> Void

    private var accessibilityTimer: Timer?

    private static let keyNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".",
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8",
        101: "F9", 103: "F11", 105: "F13", 109: "F10", 111: "F12",
        118: "F4", 120: "F2", 122: "F1",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    init(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
        self.keyCode = UInt16(UserDefaults.standard.integer(forKey: "shortcutKeyCode"))
        let storedMods = UserDefaults.standard.object(forKey: "shortcutModifierFlags") as? UInt
        if let storedMods = storedMods {
            self.modifierFlags = NSEvent.ModifierFlags(rawValue: storedMods)
        } else {
            // Default: Ctrl+Shift+A
            self.keyCode = 0  // 'A'
            self.modifierFlags = [.control, .shift]
        }
        // Shortcut 2: no default
        let storedCode2 = UserDefaults.standard.object(forKey: "shortcutKeyCode2") as? Int
        if let storedCode2 = storedCode2 {
            self.keyCode2 = UInt16(storedCode2)
            let storedMods2 = UserDefaults.standard.object(forKey: "shortcutModifierFlags2") as? UInt
            self.modifierFlags2 = NSEvent.ModifierFlags(rawValue: storedMods2 ?? 0)
        } else {
            self.keyCode2 = UInt16.max
            self.modifierFlags2 = []
        }
        // Defer monitor installation until the run loop is active so global
        // event monitors work immediately in .accessory apps.
        DispatchQueue.main.async { [weak self] in
            self?.ensureAccessibilityAndInstall()
        }
    }

    /// Request accessibility access (prompts user if needed) and install monitors.
    /// If access isn't granted yet, poll every 2s until it is.
    private func ensureAccessibilityAndInstall() {
        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        if AXIsProcessTrustedWithOptions(opts) {
            install()
        } else {
            // Poll until user grants access in System Settings
            accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
                if AXIsProcessTrusted() {
                    timer.invalidate()
                    self?.accessibilityTimer = nil
                    self?.install()
                }
            }
        }
    }

    var isEnabled: Bool { keyCode != UInt16.max }
    var isEnabled2: Bool { keyCode2 != UInt16.max }

    func update(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
        UserDefaults.standard.set(Int(keyCode), forKey: "shortcutKeyCode")
        UserDefaults.standard.set(modifierFlags.rawValue, forKey: "shortcutModifierFlags")
        reinstall()
    }

    func update2(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        self.keyCode2 = keyCode
        self.modifierFlags2 = modifierFlags
        UserDefaults.standard.set(Int(keyCode), forKey: "shortcutKeyCode2")
        UserDefaults.standard.set(modifierFlags.rawValue, forKey: "shortcutModifierFlags2")
        reinstall()
    }

    func clear() {
        self.keyCode = UInt16.max
        self.modifierFlags = []
        UserDefaults.standard.set(Int(UInt16.max), forKey: "shortcutKeyCode")
        UserDefaults.standard.set(0, forKey: "shortcutModifierFlags")
        reinstall()
    }

    func clear2() {
        self.keyCode2 = UInt16.max
        self.modifierFlags2 = []
        UserDefaults.standard.set(Int(UInt16.max), forKey: "shortcutKeyCode2")
        UserDefaults.standard.set(0, forKey: "shortcutModifierFlags2")
        reinstall()
    }

    private func matches(_ event: NSEvent) -> Bool {
        let mask: NSEvent.ModifierFlags = [.control, .shift, .option, .command]
        let eventMods = event.modifierFlags.intersection(mask)
        if isEnabled && event.keyCode == keyCode && eventMods == modifierFlags.intersection(mask) {
            return true
        }
        if isEnabled2 && event.keyCode == keyCode2 && eventMods == modifierFlags2.intersection(mask) {
            return true
        }
        return false
    }

    func install() {
        uninstall()
        guard isEnabled || isEnabled2 else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.matches(event) == true { self?.onTrigger() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.matches(event) == true {
                self?.onTrigger()
                return nil
            }
            return event
        }
    }

    func uninstall() {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        globalMonitor = nil
        localMonitor = nil
    }

    func reinstall() {
        uninstall()
        install()
    }

    private static func formatShortcut(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if modifierFlags.contains(.control) { parts.append("⌃") }
        if modifierFlags.contains(.option) { parts.append("⌥") }
        if modifierFlags.contains(.shift) { parts.append("⇧") }
        if modifierFlags.contains(.command) { parts.append("⌘") }
        parts.append(keyNames[keyCode] ?? "Key\(keyCode)")
        return parts.joined()
    }

    var displayString: String {
        guard isEnabled else { return "None" }
        return Self.formatShortcut(keyCode: keyCode, modifierFlags: modifierFlags)
    }

    var displayString2: String {
        guard isEnabled2 else { return "None" }
        return Self.formatShortcut(keyCode: keyCode2, modifierFlags: modifierFlags2)
    }

    deinit {
        accessibilityTimer?.invalidate()
        uninstall()
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: FloatingPanel!
    let reader = SessionReader()
    let teamReader = TeamReader()
    var activeTracker: ActiveSessionTracker!
    var sizeObserver: AnyCancellable?
    var activeSessionObserver: AnyCancellable?
    var shortcutManager: ShortcutManager!
    var currentSessionId: String?

    func jumpToNextSession() {
        let sessions = reader.sessions
        guard !sessions.isEmpty else { return }

        let attentionSessions = sessions.filter { $0.status == "attention" }
        let startIndex: Int
        if let lastId = currentSessionId,
           let idx = sessions.firstIndex(where: { $0.session_id == lastId }) {
            startIndex = idx
        } else {
            startIndex = sessions.count - 1  // so wrapping starts at 0
        }

        let useAttention = attentionSessions.count > 1
            || (attentionSessions.count == 1 && currentSessionId != attentionSessions[0].session_id)

        for offset in 1...sessions.count {
            let idx = (startIndex + offset) % sessions.count
            let candidate = sessions[idx]
            if useAttention {
                if candidate.status == "attention" {
                    switchToSession(candidate)
                    currentSessionId = candidate.session_id
                    activeTracker.activeSessionId = candidate.session_id
                    return
                }
            } else {
                switchToSession(candidate)
                currentSessionId = candidate.session_id
                activeTracker.activeSessionId = candidate.session_id
                return
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        shortcutManager = ShortcutManager { [weak self] in
            DispatchQueue.main.async { self?.jumpToNextSession() }
        }

        activeTracker = ActiveSessionTracker(sessionReader: reader)

        // Sync currentSessionId when focus detection changes the active session,
        // so keyboard shortcut cycling starts from the currently focused session.
        activeSessionObserver = activeTracker.$activeSessionId.sink { [weak self] newId in
            guard let newId = newId else { return }
            self?.currentSessionId = newId
        }

        panel = FloatingPanel()

        let hostingView = ClickHostingView(
            rootView: MonitorContentView(
                reader: reader, teamReader: teamReader, shortcutManager: shortcutManager,
                activeTracker: activeTracker)
        )
        hostingView.frame = NSRect(origin: .zero, size: NSSize(width: 280, height: 40))
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        panel.contentView = hostingView

        panel.restorePosition()
        panel.orderFrontRegardless()

        // Auto-resize panel to fit content
        sizeObserver = hostingView.publisher(for: \.fittingSize)
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] newSize in
                guard let self = self, let panel = self.panel else { return }
                let origin = panel.frame.origin
                // Grow downward from top edge
                let topY = origin.y + panel.frame.height
                let newOrigin = NSPoint(x: origin.x, y: topY - newSize.height)
                panel.setFrame(
                    NSRect(origin: newOrigin, size: newSize),
                    display: true,
                    animate: false
                )
            }

        // Save position on drag
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            self?.panel.savePosition()
        }
    }
}

// MARK: - Main Entry Point

@main
struct ClaudeMonitorApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
