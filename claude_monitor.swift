import Cocoa
import Combine
import SwiftUI

// MARK: - Color Constants

extension Color {
    static let workingBlue = Color(red: 0.149, green: 0.694, blue: 0.941)  // #26B1F0
    static let doneGreen = Color(red: 0.494, green: 0.980, blue: 0.392)  // #7EFA64
}

// MARK: - Team Model

struct TeamMember: Codable {
    let name: String
    let agentType: String
    let model: String?
    let color: String?
    let isActive: Bool?
}

struct TeamConfig: Codable {
    let name: String
    let description: String?
    let leadSessionId: String?
    let members: [TeamMember]?
}

struct TaskInfo: Codable {
    let subject: String?
    let status: String?
    let owner: String?
    let activeForm: String?
}

struct TeamInfo {
    let name: String
    let activeAgentCount: Int  // active members excluding lead
    let members: [TeamMember]
    let tasks: [TaskInfo]
}

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

// MARK: - Session Model

struct SessionInfo: Codable, Identifiable {
    let session_id: String
    var status: String
    var project: String
    var cwd: String
    var terminal: String
    var terminal_session_id: String
    var started_at: String
    var updated_at: String
    var last_prompt: String
    var agent_count: Int

    var id: String { session_id }

    enum CodingKeys: String, CodingKey {
        case session_id, status, project, cwd, terminal, terminal_session_id, started_at,
            updated_at, last_prompt, agent_count
    }

    init(
        session_id: String, status: String, project: String, cwd: String,
        terminal: String, terminal_session_id: String,
        started_at: String, updated_at: String, last_prompt: String,
        agent_count: Int = 0
    ) {
        self.session_id = session_id
        self.status = status
        self.project = project
        self.cwd = cwd
        self.terminal = terminal
        self.terminal_session_id = terminal_session_id
        self.started_at = started_at
        self.updated_at = updated_at
        self.last_prompt = last_prompt
        self.agent_count = agent_count
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        session_id = try c.decode(String.self, forKey: .session_id)
        status = (try? c.decode(String.self, forKey: .status)) ?? "unknown"
        project = (try? c.decode(String.self, forKey: .project)) ?? "unknown"
        cwd = (try? c.decode(String.self, forKey: .cwd)) ?? ""
        terminal = (try? c.decode(String.self, forKey: .terminal)) ?? ""
        terminal_session_id = (try? c.decode(String.self, forKey: .terminal_session_id)) ?? ""
        started_at = (try? c.decode(String.self, forKey: .started_at)) ?? ""
        updated_at = (try? c.decode(String.self, forKey: .updated_at)) ?? ""
        last_prompt = (try? c.decode(String.self, forKey: .last_prompt)) ?? ""
        agent_count = (try? c.decode(Int.self, forKey: .agent_count)) ?? 0
    }

    var statusColor: Color {
        switch status {
        case "starting": return .gray
        case "working": return .workingBlue
        case "idle": return .doneGreen
        case "attention": return .orange
        case "shutting_down": return .gray
        default: return .gray
        }
    }

    var statusIcon: String {
        switch status {
        case "starting": return "circle.dotted"
        case "working": return "circle.fill"
        case "idle": return "checkmark.circle.fill"
        case "attention": return "exclamationmark.triangle.fill"
        case "shutting_down": return "arrow.down.circle"
        default: return "circle"
        }
    }

    var displayStatus: String {
        switch status {
        case "starting": return "starting"
        case "working": return "working"
        case "idle": return "idle"
        case "attention": return "attention"
        case "shutting_down": return "exiting"
        default: return status
        }
    }

    var elapsedString: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Try with fractional seconds first, then without
        var date = formatter.date(from: started_at)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: started_at)
        }
        guard let start = date else { return "" }
        let elapsed = Date().timeIntervalSince(start)
        if elapsed < 60 { return "\(Int(elapsed))s" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m" }
        return
            "\(Int(elapsed / 3600))h \(Int((elapsed.truncatingRemainder(dividingBy: 3600)) / 60))m"
    }

    var isStale: Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: updated_at)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: updated_at)
        }
        guard let updated = date else { return false }
        return Date().timeIntervalSince(updated) > 600  // 10 minutes
    }
}

// MARK: - Session Reader (polls directory)

class SessionReader: ObservableObject {
    @Published var sessions: [SessionInfo] = []
    private var livenessTimer: Timer?
    private var dirSource: DirectoryWatcher?
    private var projectsWatcher: DirectoryWatcher?
    /// Last known stable status per session (working/idle/attention) for suppressing transient flicker
    private var lastStableStatus: [String: String] = [:]
    /// Full SessionInfo snapshot for re-injecting disappeared sessions during grace period
    private var lastStableSession: [String: SessionInfo] = [:]
    /// When a transient status (shutting_down/starting) was first seen, for grace period timing
    private var transientSince: [String: Date] = [:]

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
            DispatchQueue.main.async {
                self?.readSessions()
            }
        }

        // FSEvents on projects dir: detect new/changed JSONL files
        projectsWatcher = DirectoryWatcher(paths: [projectsDir], latency: 1.0) { [weak self] in
            DispatchQueue.main.async {
                self?.scanProjects()
                self?.readSessions()
            }
        }

        // Liveness timer: prune dead sessions (absence of writes can't trigger FSEvents)
        livenessTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) {
            [weak self] _ in
            self?.pruneDeadSessions()
        }
    }

    /// Delete session files last updated before the most recent boot (survived an ungraceful shutdown)
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
        // Format: "{ sec = 1234567890, usec = 123456 } ..."
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
                var dead = session
                dead.status = "dead"
                writeSessionFile(dead, to: path)
                NSLog(
                    "[ClaudeMonitor] Marked pre-boot session %@ as dead (updated %@)", session.session_id,
                    session.updated_at)
            }
        }
    }

    /// Mark legacy `discovered-*` session files as dead.
    private func cleanupLegacyDiscoveredSessions() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: sessionsDir) else { return }
        for file in files where file.hasPrefix("discovered-") && file.hasSuffix(".json") {
            let path = "\(sessionsDir)/\(file)"
            if let data = fm.contents(atPath: path),
               var session = try? JSONDecoder().decode(SessionInfo.self, from: data) {
                session.status = "dead"
                writeSessionFile(session, to: path)
            }
            NSLog("[ClaudeMonitor] Marked legacy discovered session %@ as dead", file)
        }
    }

    /// Read the last ~4KB of a JSONL file to extract cwd, latest user prompt, timestamp, and whether it's a subagent.
    private func readJSONLTail(path: String) -> (
        cwd: String, prompt: String, timestamp: String?, isSubagent: Bool
    ) {
        guard let fileHandle = FileHandle(forReadingAtPath: path) else {
            return ("", "", nil, false)
        }
        defer { fileHandle.closeFile() }

        let fileSize = fileHandle.seekToEndOfFile()
        guard fileSize > 0 else { return ("", "", nil, false) }
        let readSize: UInt64 = min(fileSize, 4096)
        fileHandle.seek(toFileOffset: fileSize - readSize)
        let data = fileHandle.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return ("", "", nil, false) }

        let lines = text.components(separatedBy: "\n")
        var cwd = ""
        var prompt = ""
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
            // Extract user prompts: type=="user", message.content is a plain string (not tool results or teammate messages)
            if let type = json["type"] as? String, type == "user",
                !isSubagent,
                let message = json["message"] as? [String: Any],
                let content = message["content"] as? String,
                !content.hasPrefix("<teammate-message")
            {
                prompt = String(content.prefix(200))
            }
        }

        return (cwd, prompt, timestamp, isSubagent)
    }

    /// Write a SessionInfo to a JSON file atomically.
    private func writeSessionFile(_ session: SessionInfo, to path: String) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        let tmpPath = path + ".tmp"
        try? data.write(to: URL(fileURLWithPath: tmpPath))
        // POSIX rename() is atomic — no window where the file doesn't exist
        rename(tmpPath, path)
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

    /// Scan `~/.claude/projects/` JSONL files to discover and update sessions.
    /// This is the primary session detection mechanism — replaces TTY-based discovery.
    func scanProjects() {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: projectsDir) else { return }
        let now = Date()
        let twoMinAgo = now.addingTimeInterval(-120)
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        let nowString = isoFormatter.string(from: now)

        for projectDir in projectDirs {
            let projectPath = "\(projectsDir)/\(projectDir)"

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
                let (cwd, lastPrompt, lastTimestamp, isSubagent) = readJSONLTail(path: jsonlPath)

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

                // Update existing session files (don't touch status — hooks own lifecycle).
                // Only create new files for very fresh JSONLs (monitor restart recovery).
                let sessionFile = "\(sessionsDir)/\(sessionId).json"
                if let data = fm.contents(atPath: sessionFile),
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                {
                    // Don't touch shutting_down sessions — they're waiting to be hidden
                    if json["status"] as? String == "shutting_down" { continue }

                    // Update only scanner-owned fields; preserve status and everything else from disk
                    var updated = json
                    if (updated["project"] as? String) == "unknown" || (updated["cwd"] as? String ?? "").isEmpty {
                        updated["project"] = project
                        updated["cwd"] = cwd
                    }
                    if !lastPrompt.isEmpty {
                        updated["last_prompt"] = lastPrompt
                    }
                    updated["agent_count"] = agentCount
                    updated["updated_at"] = nowString
                    if let outData = try? JSONSerialization.data(withJSONObject: updated) {
                        let tmpPath = sessionFile + ".tmp"
                        try? outData.write(to: URL(fileURLWithPath: tmpPath))
                        rename(tmpPath, sessionFile)
                    }
                } else if mtime > now.addingTimeInterval(-30) {
                    // Only create for JSONLs modified in last 30s (recovery after monitor restart).
                    // Older JSONLs without session files were intentionally cleaned up.
                    // Use "idle" — a recovered session is not truly starting, it was already running.
                    let session = SessionInfo(
                        session_id: sessionId, status: "idle",
                        project: project, cwd: cwd,
                        terminal: "", terminal_session_id: "",
                        started_at: lastTimestamp ?? nowString,
                        updated_at: nowString,
                        last_prompt: lastPrompt,
                        agent_count: agentCount
                    )
                    writeSessionFile(session, to: sessionFile)
                }
            }
        }
    }

    /// Remove session files whose `claude` process is no longer running
    func pruneDeadSessions() {
        // Read raw files from disk instead of using aggregated `sessions` property,
        // so every session file gets liveness-checked (not just deduplicated ones)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: sessionsDir) else { return }
        var currentSessions: [SessionInfo] = []
        for file in files where file.hasSuffix(".json") {
            let path = "\(sessionsDir)/\(file)"
            guard let data = fm.contents(atPath: path),
                let session = try? JSONDecoder().decode(SessionInfo.self, from: data)
            else { continue }
            currentSessions.append(session)
        }
        guard !currentSessions.isEmpty else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            var deadSessionIds: [String] = []

            // --- Primary liveness: JSONL mtime check for ALL sessions ---
            // Also separate sessions without JSONL by terminal type for fallback checks
            var ttyMap: [String: [String]] = [:]  // ttyName -> [session_id]
            var itermSessions: [(id: String, termSid: String)] = []
            var noInfoSessions: [SessionInfo] = []

            for session in currentSessions {
                // Skip already-dead sessions
                if session.status == "dead" { continue }
                // Skip "starting" sessions — they're brand new, may not have JSONL yet
                if session.status == "starting" && !session.isStale { continue }

                // First try JSONL mtime — most reliable per-session check
                if let jsonlPath = self.findJSONLPath(sessionId: session.session_id),
                    let attrs = try? FileManager.default.attributesOfItem(atPath: jsonlPath),
                    let mtime = attrs[.modificationDate] as? Date
                {
                    // Prune any session whose JSONL is older than 12 hours
                    let age = Date().timeIntervalSince(mtime)
                    if age > 43200 {
                        deadSessionIds.append(session.session_id)
                    }
                    // Otherwise keep the file — shutting_down sessions are hidden from UI
                    // but kept on disk so session resumption can "reboot" them.
                    continue
                }

                // No JSONL found — use terminal-based fallback
                if session.terminal_session_id.isEmpty {
                    noInfoSessions.append(session)
                } else if session.terminal == "iterm2" {
                    itermSessions.append((session.session_id, session.terminal_session_id))
                } else {
                    let ttyName = session.terminal_session_id.replacingOccurrences(
                        of: "/dev/", with: "")
                    ttyMap[ttyName, default: []].append(session.session_id)
                }
            }

            // --- Fallback: Terminal/Ghostty TTY check (only for sessions without JSONL) ---
            if !ttyMap.isEmpty {
                let ttys = ttyMap.keys.joined(separator: " ")
                let script =
                    "for tty in \(ttys); do ps -t \"$tty\" -o comm= 2>/dev/null | grep -q claude || echo \"$tty\"; done"
                if let output = self.runShell(script) {
                    for tty in output.split(separator: "\n").map(String.init) {
                        if let sids = ttyMap[tty] { deadSessionIds.append(contentsOf: sids) }
                    }
                }
            }

            // --- Fallback: iTerm2 check (only for sessions without JSONL) ---
            if !itermSessions.isEmpty {
                let itermRunning = NSWorkspace.shared.runningApplications.contains {
                    $0.bundleIdentifier == "com.googlecode.iterm2"
                }
                if !itermRunning {
                    deadSessionIds.append(contentsOf: itermSessions.map(\.id))
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
                                deadSessionIds.append(sid)
                            }
                        }
                    }
                }
            }

            // --- Fallback: no JSONL and no terminal info → use staleness ---
            for session in noInfoSessions where session.isStale {
                deadSessionIds.append(session.session_id)
            }

            // Mark dead sessions (skip team leads with active agents)
            for sid in deadSessionIds {
                if self.sessionHasActiveTeam(sid) {
                    NSLog("[ClaudeMonitor] Skipping prune of team lead %@ (has active agents)", sid)
                    continue
                }
                let path = "\(self.sessionsDir)/\(sid).json"
                if let data = FileManager.default.contents(atPath: path),
                   var session = try? JSONDecoder().decode(SessionInfo.self, from: data) {
                    session.status = "dead"
                    self.writeSessionFile(session, to: path)
                }
                NSLog("[ClaudeMonitor] Marked dead session %@", sid)
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

    func readSessions() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: sessionsDir) else {
            DispatchQueue.main.async { self.sessions = [] }
            return
        }

        let isoFmt = ISO8601DateFormatter()
        var loaded: [SessionInfo] = []
        for file in files where file.hasSuffix(".json") {
            let path = "\(sessionsDir)/\(file)"
            guard let data = fm.contents(atPath: path) else { continue }
            do {
                let session = try JSONDecoder().decode(SessionInfo.self, from: data)
                // Never show dead sessions
                if session.status == "dead" { continue }
                // Hide shutting_down sessions after 30s (file stays for potential resume)
                if session.status == "shutting_down" {
                    isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    var updDate = isoFmt.date(from: session.updated_at)
                    if updDate == nil {
                        isoFmt.formatOptions = [.withInternetDateTime]
                        updDate = isoFmt.date(from: session.updated_at)
                    }
                    if let d = updDate, Date().timeIntervalSince(d) > 30 { continue }
                }
                loaded.append(session)
            } catch {
                NSLog(
                    "[ClaudeMonitor] Skipping corrupt session file %@: %@", file,
                    error.localizedDescription)
            }
        }

        // Stabilize transient statuses to prevent flicker during plan mode exit.
        // Plan mode exit fires SessionEnd → SessionStart → tool hooks in rapid succession,
        // causing brief "shutting_down" → "starting" → "working" transitions, or the
        // session file may briefly become "dead"/absent before a new one appears.
        // Suppress transient states and re-inject disappeared sessions for a 3s grace period.
        let stableStatuses: Set<String> = ["working", "idle", "attention"]
        let transientStatuses: Set<String> = ["shutting_down", "starting"]
        let now = Date()
        let loadedIds = Set(loaded.map(\.session_id))

        // Re-inject sessions that disappeared but were recently stable
        for (sid, status) in lastStableStatus {
            guard !loadedIds.contains(sid) else { continue }
            if transientSince[sid] == nil {
                transientSince[sid] = now
            }
            if now.timeIntervalSince(transientSince[sid]!) < 3.0,
               let cached = lastStableSession[sid] {
                var ghost = cached
                ghost.status = status
                loaded.append(ghost)
            }
        }

        for i in loaded.indices {
            let sid = loaded[i].session_id
            if stableStatuses.contains(loaded[i].status) {
                lastStableStatus[sid] = loaded[i].status
                lastStableSession[sid] = loaded[i]
                transientSince.removeValue(forKey: sid)
            } else if transientStatuses.contains(loaded[i].status),
                      let prev = lastStableStatus[sid] {
                if transientSince[sid] == nil {
                    transientSince[sid] = now
                }
                if now.timeIntervalSince(transientSince[sid]!) < 3.0 {
                    loaded[i].status = prev
                }
            }
        }
        // Clean up tracking for sessions gone longer than grace period
        let allIds = Set(loaded.map(\.session_id))
        for sid in Array(lastStableStatus.keys) {
            if !allIds.contains(sid) {
                if let since = transientSince[sid], now.timeIntervalSince(since) >= 3.0 {
                    lastStableStatus.removeValue(forKey: sid)
                    lastStableSession.removeValue(forKey: sid)
                    transientSince.removeValue(forKey: sid)
                }
            }
        }

        // Aggregate sessions with the same project name
        let statusPriority: [String: Int] = [
            "working": 0, "attention": 1, "idle": 2, "shutting_down": 3, "starting": 4,
        ]
        var grouped: [String: [SessionInfo]] = [:]
        for s in loaded { grouped[s.project, default: []].append(s) }

        // Merge groups that share the exact same CWD (different project names, same directory)
        var didMerge = true
        while didMerge {
            didMerge = false
            let keys = Array(grouped.keys)
            outer: for i in 0..<keys.count {
                for j in (i + 1)..<keys.count {
                    let a = keys[i]
                    let b = keys[j]
                    let cwdsA = Set(grouped[a]!.map { $0.cwd })
                    let cwdsB = Set(grouped[b]!.map { $0.cwd })
                    if !cwdsA.isDisjoint(with: cwdsB) {
                        grouped[a]!.append(contentsOf: grouped[b]!)
                        grouped.removeValue(forKey: b)
                        didMerge = true
                        break outer
                    }
                }
            }
        }

        var aggregated: [SessionInfo] = []
        for (_, group) in grouped {
            if group.count == 1 {
                aggregated.append(group[0])
                continue
            }
            NSLog("[ClaudeMonitor] aggregating group of %d sessions for project '%@':", group.count, group[0].project)
            for s in group {
                NSLog("[ClaudeMonitor]   sid=%@ status=%@ terminal=%@ tty=%@ cwd=%@ updated=%@", s.session_id, s.status, s.terminal, s.terminal_session_id, s.cwd, s.updated_at)
            }
            // Pick representative: highest-priority status, then most recently updated
            let best = group.min { a, b in
                let pa = statusPriority[a.status] ?? 9
                let pb = statusPriority[b.status] ?? 9
                if pa != pb { return pa < pb }
                return a.updated_at > b.updated_at  // ISO8601 sorts lexicographically
            }!
            var merged = best
            // Use first non-empty description
            if merged.last_prompt.isEmpty {
                merged.last_prompt =
                    group.first(where: { !$0.last_prompt.isEmpty })?.last_prompt ?? ""
            }
            // Use earliest started_at for largest elapsed time
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var earliest = merged.started_at
            var earliestDate: Date? =
                formatter.date(from: earliest)
                ?? {
                    formatter.formatOptions = [.withInternetDateTime]
                    return formatter.date(from: earliest)
                }()
            for s in group {
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let d = formatter.date(from: s.started_at)
                    ?? {
                        formatter.formatOptions = [.withInternetDateTime]
                        return formatter.date(from: s.started_at)
                    }()
                {
                    if earliestDate == nil || d < earliestDate! {
                        earliestDate = d
                        earliest = s.started_at
                    }
                }
            }
            merged.started_at = earliest
            NSLog("[ClaudeMonitor]   → representative: sid=%@ status=%@ terminal=%@ tty=%@ cwd=%@", merged.session_id, merged.status, merged.terminal, merged.terminal_session_id, merged.cwd)
            aggregated.append(merged)
        }

        // Sort alphabetically by project name for stable ordering
        aggregated.sort {
            $0.project.localizedCaseInsensitiveCompare($1.project) == .orderedAscending
        }

        DispatchQueue.main.async {
            self.sessions = aggregated
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
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
              let focusedWindow = focusedRef else {
            DispatchQueue.main.async { self.activeSessionId = nil }
            return
        }
        let window = focusedWindow as! AXUIElement

        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
        let title = titleRef as? String ?? ""

        var docRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &docRef)
        let doc = docRef as? String ?? ""

        var bestId: String? = nil
        var bestScore = 0
        for session in sessions {
            let score = scoreGhosttyWindow(title: title, doc: doc, cwd: session.cwd)
            if score > bestScore {
                bestScore = score
                bestId = session.session_id
            }
        }
        DispatchQueue.main.async { self.activeSessionId = bestId }
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

// MARK: - Terminal Switcher

func switchToSession(_ session: SessionInfo) {
    NSLog(
        "[ClaudeMonitor] switchToSession: terminal=\(session.terminal) tty=\(session.terminal_session_id) project=\(session.project) cwd=\(session.cwd) sid=\(session.session_id)"
    )
    if session.terminal == "iterm2" && !session.terminal_session_id.isEmpty {
        switchToITerm2(sessionId: session.terminal_session_id)
    } else if session.terminal == "ghostty" {
        switchToGhostty(cwd: session.cwd, ttyPath: session.terminal_session_id)
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

/// Score a Ghostty window/tab title + AXDocument against a target CWD.
/// Returns 0 (no match), 25 (title contains basename), or 30 (AXDocument CWD match).
/// Only considers windows whose title starts with "tmux ".
func scoreGhosttyWindow(title: String, doc: String, cwd: String) -> Int {
    let lower = title.lowercased()
    guard lower.hasPrefix("tmux ") else { return 0 }

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

func switchToGhostty(cwd: String, ttyPath: String) {
    let basename = (cwd as NSString).lastPathComponent

    guard
        let ghosttyApp = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.mitchellh.ghostty"
        ).first
            ?? NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == "Ghostty" }
            )
    else { return }

    let appElement = AXUIElementCreateApplication(ghosttyApp.processIdentifier)
    let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(opts)

    var windowsRef: CFTypeRef?
    guard
        AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
            == .success,
        let windows = windowsRef as? [AXUIElement]
    else {
        ghosttyApp.activate()
        return
    }

    // Helper: find the tab group and tabs for a window
    func getTabs(_ window: AXUIElement) -> [AXUIElement]? {
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }
        for child in children {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
            if (roleRef as? String) == "AXTabGroup" {
                var tabsRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(child, kAXChildrenAttribute as CFString, &tabsRef) == .success,
                   let tabs = tabsRef as? [AXUIElement] { return tabs }
            }
        }
        return nil
    }

    // Helper: read AXDocument from a window (file URL of CWD, reliable for direct Claude windows)
    func getDocument(_ window: AXUIElement) -> String {
        var docRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &docRef) == .success,
              let doc = docRef as? String else { return "" }
        return doc
    }

    struct Candidate {
        let window: AXUIElement
        let tab: AXUIElement?
        let title: String
        let score: Int
    }

    var candidates: [Candidate] = []

    for window in windows {
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
        let windowTitle = titleRef as? String ?? ""
        let document = getDocument(window)

        let windowScore = scoreGhosttyWindow(title: windowTitle, doc: document, cwd: cwd)

        // For multi-tab windows, score each tab individually too
        if let tabs = getTabs(window), tabs.count > 1 {
            var hadTabMatch = false
            for tab in tabs {
                var tabTitleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(tab, kAXTitleAttribute as CFString, &tabTitleRef)
                let tabTitle = tabTitleRef as? String ?? ""
                guard !tabTitle.isEmpty else { continue }
                let s = scoreGhosttyWindow(title: tabTitle, doc: document, cwd: cwd)
                if s > 0 {
                    candidates.append(Candidate(window: window, tab: tab, title: tabTitle, score: s))
                    hadTabMatch = true
                }
            }
            if !hadTabMatch && windowScore > 0 {
                candidates.append(Candidate(window: window, tab: nil, title: windowTitle, score: windowScore))
            }
        } else {
            // Single-tab window
            if windowScore > 0 {
                candidates.append(Candidate(window: window, tab: nil, title: windowTitle, score: windowScore))
            }
        }
    }

    // Sort by score descending
    candidates.sort { $0.score > $1.score }
    NSLog("[ClaudeMonitor] switchToGhostty: %d candidates for cwd=%@ basename=%@", candidates.count, cwd, basename)
    for c in candidates {
        NSLog("[ClaudeMonitor]   candidate: \"\(c.title)\" score=\(c.score)")
    }

    if let best = candidates.first {
        NSLog("[ClaudeMonitor] switchToGhostty: matched \"\(best.title)\" (score=\(best.score), doc-based=\(best.score >= 30)) for project \(basename)")
        if let tab = best.tab {
            AXUIElementPerformAction(tab, kAXPressAction as CFString)
        }
        AXUIElementPerformAction(best.window, kAXRaiseAction as CFString)
    } else {
        NSLog("[ClaudeMonitor] switchToGhostty: no match for \(basename)")
    }
    ghosttyApp.activate()
}

func switchByTerminalCwd(cwd: String) {
    // Fallback: just activate the terminal app
    if let appleScript = NSAppleScript(source: "tell application \"Terminal\" to activate") {
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
    }
}

// MARK: - Session Killer

func killSession(_ session: SessionInfo) {
    var ttyName: String?

    if session.terminal == "terminal" && !session.terminal_session_id.isEmpty {
        ttyName = session.terminal_session_id.replacingOccurrences(of: "/dev/", with: "")
    } else if session.terminal == "iterm2" && !session.terminal_session_id.isEmpty {
        let parts = session.terminal_session_id.split(separator: ":")
        if parts.count >= 2 {
            let uniqueId = String(parts[1])
            let script = """
                tell application "iTerm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if unique id of s is "\(uniqueId)" then
                                    return tty of s
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
                """
            if let appleScript = NSAppleScript(source: script) {
                var error: NSDictionary?
                let result = appleScript.executeAndReturnError(&error)
                if let tty = result.stringValue {
                    ttyName = tty.replacingOccurrences(of: "/dev/", with: "")
                }
            }
        }
    }

    if let tty = ttyName {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "pkill -TERM -t \(tty) -f claude 2>/dev/null"]
        try? task.run()
    }

    // Mark session as dead after delay
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let sessionFile = "\(home)/.claude/monitor/sessions/\(session.session_id).json"
    DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
        if let data = FileManager.default.contents(atPath: sessionFile),
           var s = try? JSONDecoder().decode(SessionInfo.self, from: data) {
            s.status = "dead"
            if let encoded = try? JSONEncoder().encode(s) {
                let tmp = sessionFile + ".tmp"
                try? encoded.write(to: URL(fileURLWithPath: tmp))
                rename(tmp, sessionFile)
            }
        }
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
    var onKill: (() -> Void)? = nil
    @State private var isHovered = false
    @State private var isKilling = false
    @State private var badgeScale: CGFloat = 1.0

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
                    if badgeCount > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "person.2.fill")
                                .font(.system(size: 8))
                            Text("\(badgeCount)")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                        }
                        .foregroundColor(session.statusColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(session.statusColor.opacity(0.2))
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
                        .overlay(alignment: .leading) {
                            if onKill != nil {
                                ZStack {
                                    if isKilling {
                                        PulsingDot(color: .red, isPulsing: true)
                                    } else if isHovered {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundColor(.white.opacity(0.4))
                                            .overlay(
                                                FirstMouseClickArea {
                                                    isKilling = true
                                                    onKill?()
                                                }
                                            )
                                    }
                                }
                                .frame(width: 20, height: 20)
                                .offset(x: -24)
                            }
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
                RefreshButton(sessionReader: sessionReader)
            }
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

    var body: some View {
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
                                teamInfo: teamReader.teamsBySession[session.session_id],
                                isActive: session.session_id == activeTracker.activeSessionId,
                                onKill: { killSession(session) }
                            )
                            .overlay(
                                FirstMouseClickArea {
                                    switchToSession(session)
                                    activeTracker.activeSessionId = session.session_id
                                }
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
        .frame(width: 280)
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
    }
}

struct FirstMouseClickArea: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> ClickNSView {
        let view = ClickNSView()
        view.action = action
        return view
    }
    func updateNSView(_ nsView: ClickNSView, context: Context) {
        nsView.action = action
    }

    class ClickNSView: NSView {
        var action: (() -> Void)?

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
