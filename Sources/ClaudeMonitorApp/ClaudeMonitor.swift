import Carbon
import Cocoa
import Combine
import SwiftUI
import ClaudeMonitorCore

// MARK: - Terminal Providers (shared across SessionReader + ActiveSessionTracker)

let terminalProviders: [TerminalProvider] = [
    GhosttyProvider(), CMUXProvider(), ITerm2Provider(), TerminalAppProvider(), T3CodeProvider()
]

func providerFor(name: String) -> TerminalProvider? {
    terminalProviders.first { $0.name == name }
}

func providerFor(bundleId: String) -> TerminalProvider? {
    terminalProviders.first { $0.bundleIdentifier == bundleId }
}

// MARK: - Team Reader

class TeamReader: ObservableObject {
    @Published var teamsBySession: [String: TeamInfo] = [:]
    @Published var leadSessionByTeamName: [String: String] = [:]
    private var watcher: DirectoryWatcher?
    private var knownTeamNames: Set<String> = []
    var onTeamsRemoved: ((Set<String>) -> Void)?

    private let teamsDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude/teams"
    }()

    private let tasksDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude/tasks"
    }()

    private let ioQueue = DispatchQueue(label: "com.claudemonitor.teamio", qos: .userInitiated)
    private lazy var readDebouncer = Debouncer(delay: 0.25, queue: ioQueue)

    init() {
        ioQueue.async { [weak self] in self?._readTeamsOnIOQueue() }
        watcher = DirectoryWatcher(paths: [teamsDir, tasksDir], latency: 0.5) { [weak self] in
            self?.readDebouncer.schedule { self?._readTeamsOnIOQueue() }
        }
    }

    func readTeams() {
        ioQueue.async { [weak self] in self?._readTeamsOnIOQueue() }
    }

    private func _readTeamsOnIOQueue() {
        let fm = FileManager.default
        guard let teamDirs = try? fm.contentsOfDirectory(atPath: teamsDir) else {
            DispatchQueue.main.async { self.teamsBySession = [:] }
            return
        }

        var result: [String: TeamInfo] = [:]
        var nameMap: [String: String] = [:]

        for teamDir in teamDirs {
            let configPath = "\(teamsDir)/\(teamDir)/config.json"
            guard let data = fm.contents(atPath: configPath),
                let config = try? JSONDecoder().decode(TeamConfig.self, from: data),
                let leadSessionId = config.leadSessionId, !leadSessionId.isEmpty
            else { continue }

            nameMap[teamDir] = leadSessionId

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

        let currentNames = Set(nameMap.keys)
        let removed = knownTeamNames.subtracting(currentNames)
        knownTeamNames = currentNames
        if !removed.isEmpty { onTeamsRemoved?(removed) }

        DispatchQueue.main.async {
            self.teamsBySession = result
            self.leadSessionByTeamName = nameMap
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
            FSEventStreamSetDispatchQueue(
                stream,
                DispatchQueue(label: "com.claudemonitor.fsevents", qos: .userInitiated)
            )
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

// MARK: - Debouncer

/// Coalesces rapid calls into a single trailing-edge fire after `delay` seconds.
final class Debouncer {
    private let delay: TimeInterval
    private let queue: DispatchQueue
    private var workItem: DispatchWorkItem?

    init(delay: TimeInterval, queue: DispatchQueue = DispatchQueue.main) {
        self.delay = delay
        self.queue = queue
    }

    func schedule(_ block: @escaping () -> Void) {
        workItem?.cancel()
        let item = DispatchWorkItem(block: block)
        workItem = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }
}

// MARK: - Session Metadata (from JSONL head — static, cached across scan cycles)

struct SessionMeta {
    var isSubagent: Bool
    var teamName: String?
    var customTitle: String?
    /// JSONL mtime when this meta was last read; nil means never read or mtime unknown.
    var jsonlMtime: Date?
}

// MARK: - Session File Cache (mtime-keyed, avoids repeated JSON decode for unchanged files)

private struct SessionFileSnapshot {
    var jsonMtime: Date
    var contextMtime: Date?
    var modelMtime: Date?
    var info: SessionInfo
}

// MARK: - Derived Session Data (in-memory, from JSONL scanning)

struct DerivedSessionData {
    var project: String
    var cwd: String
    var agentCount: Int
    var customTitle: String?
    var jsonlMtime: Date?
    var jsonlBirthDate: Date?
    var jsonlPath: String?
}

// MARK: - Session Reader (polls directory)

class SessionReader: ObservableObject {
    @Published var sessions: [SessionInfo] = []
    /// Increments whenever any session transitions into "attention" status. Used as a
    /// realtime signal so WatcherEngine can force-emit a snapshot even if the identityHash
    /// diff would otherwise coalesce the change.
    @Published private(set) var attentionPulse: UInt64 = 0
    private var livenessTimerSource: DispatchSourceTimer?
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
    /// Coalesces burst FSEvents + liveness triggers into a single trailing-edge readSessions call
    private lazy var readDebouncer = Debouncer(delay: 0.25, queue: ioQueue)
    /// Coalesces burst FSEvents into a single trailing-edge scanProjects call
    private lazy var scanDebouncer = Debouncer(delay: 0.25, queue: ioQueue)

    /// TTY → Ghostty UUID mapping for click-to-switch (loaded from tty_map.json)
    private(set) var ttyMap: [String: String] = [:]
    /// Tmux session name → Ghostty UUID mapping (loaded from tmux_map.json)
    private(set) var tmuxMap: [String: String] = [:]
    /// Last-seen mtime of tty_map.json; nil means not yet loaded
    private var ttyMapMtime: Date?
    /// Last-seen mtime of tmux_map.json; nil means not yet loaded
    private var tmuxMapMtime: Date?

    /// Per-session JSON file cache: session_id → snapshot keyed by file mtimes
    private var sessionFileCache: [String: SessionFileSnapshot] = [:]

    /// Per-session static metadata from JSONL head (isSubagent, teamName). Persists across scan cycles.
    private var sessionMetaCache: [String: SessionMeta] = [:]

    /// Timestamp of the last dumpDebugState write; used to rate-limit to ≤ 1 write/sec
    private var lastDebugDumpAt: Date = .distantPast

    /// Reference to TeamReader for looking up team lead session IDs
    weak var teamReader: TeamReader? {
        didSet {
            teamReader?.onTeamsRemoved = { [weak self] removed in
                self?.cleanupTeamAgentSessions(teamNames: removed)
            }
            if teamReader != nil { readSessions() }
        }
    }

    private let monitorDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude-monitor"
    }()

    private let sessionsDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude-monitor/sessions"
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

        // FSEvents: reload when session files change. Sessions dir is a hot signal path for
        // "attention" alerts (Claude hooks write small .json status files). Use low latency
        // and bypass the read debouncer entirely so orange transitions surface in <200ms.
        // Reads are mtime-cached; bursts are rare here, so coalescing is unnecessary.
        dirSource = DirectoryWatcher(paths: [sessionsDir], latency: 0.05) { [weak self] in
            guard let self = self else { return }
            let leads = self.teamReader?.leadSessionByTeamName ?? [:]
            self.ioQueue.async {
                self._readSessionsOnIOQueue(teamLeadsByName: leads)
            }
        }

        // FSEvents on projects dir: detect new/changed JSONL files (debounced)
        projectsWatcher = DirectoryWatcher(paths: [projectsDir], latency: 1.0) { [weak self] in
            self?.scheduleScanAndRead()
        }

        // Liveness timer: prune dead sessions every 10s (FSEvents can't detect absence of writes)
        let livenessSource = DispatchSource.makeTimerSource(queue: ioQueue)
        livenessSource.schedule(deadline: .now() + 10, repeating: 10)
        livenessSource.setEventHandler { [weak self] in self?.pruneDeadSessions() }
        livenessSource.resume()
        livenessTimerSource = livenessSource
    }

    deinit {
        livenessTimerSource?.cancel()
    }

    private func scheduleRead() {
        readDebouncer.schedule { [weak self] in
            guard let self = self else { return }
            self._readSessionsOnIOQueue(teamLeadsByName: self.teamReader?.leadSessionByTeamName ?? [:])
        }
    }

    private func scheduleScanAndRead() {
        scanDebouncer.schedule { [weak self] in
            guard let self = self else { return }
            self._scanProjectsOnIOQueue()
            self._readSessionsOnIOQueue(teamLeadsByName: self.teamReader?.leadSessionByTeamName ?? [:])
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

    /// Read the head of a JSONL file (first 8KB) to extract static metadata: agentName, teamName, customTitle.
    private func readJSONLHead(path: String) -> SessionMeta {
        guard let fileHandle = FileHandle(forReadingAtPath: path) else {
            return SessionMeta(isSubagent: false, teamName: nil, customTitle: nil)
        }
        defer { fileHandle.closeFile() }

        let readSize: UInt64 = 8192
        let data = fileHandle.readData(ofLength: Int(readSize))
        guard let text = String(data: data, encoding: .utf8) else {
            return SessionMeta(isSubagent: false, teamName: nil, customTitle: nil)
        }

        var isSubagent = false
        var teamName: String? = nil
        var customTitle: String? = nil

        let lines = text.components(separatedBy: "\n")
        for line in lines {
            guard !line.isEmpty,
                let lineData = line.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            if json["agentName"] != nil {
                isSubagent = true
            }
            if let tn = json["teamName"] as? String, !tn.isEmpty {
                teamName = tn
            }
            if json["type"] as? String == "custom-title",
               let ct = json["customTitle"] as? String, !ct.isEmpty {
                customTitle = ct
            }
            if isSubagent && teamName != nil { break }
        }

        return SessionMeta(isSubagent: isSubagent, teamName: teamName, customTitle: customTitle)
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
    /// Static subagent/teamName metadata is read from the JSONL head and cached in sessionMetaCache.
    /// No session files are written — readSessions() merges this data at display time.
    func scanProjects() {
        ioQueue.async { [weak self] in
            self?._scanProjectsOnIOQueue()
        }
    }

    private func _scanProjectsOnIOQueue() {
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

                    // Check mtime
                    guard let attrs = try? fm.attributesOfItem(atPath: jsonlPath),
                        let mtime = attrs[.modificationDate] as? Date
                    else { continue }
                    let isFresh = mtime > twoMinAgo

                    let sessionId = String(file.dropLast(6))  // remove ".jsonl"

                    // Read static metadata from head; re-read on mtime change only.
                    let meta: SessionMeta
                    if let cached = self.sessionMetaCache[sessionId], cached.jsonlMtime == mtime {
                        meta = cached
                    } else {
                        var m = self.readJSONLHead(path: jsonlPath)
                        m.jsonlMtime = mtime
                        self.sessionMetaCache[sessionId] = m
                        meta = m
                    }

                    // Skip subagent sessions entirely
                    if meta.isSubagent { continue }

                    // Only populate derivedData from fresh files
                    if !isFresh { continue }

                    // cwd comes from session JSON (written by hook at SessionStart).
                    // Use previously cached cwd if we have one; otherwise derive from session file.
                    let sessionFilePath = "\(self.sessionsDir)/\(sessionId).json"
                    var cwd = self.derivedData[sessionId]?.cwd ?? ""
                    if cwd.isEmpty,
                       let data = fm.contents(atPath: sessionFilePath),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let sessionCwd = json["cwd"] as? String,
                       !sessionCwd.isEmpty
                    {
                        cwd = sessionCwd
                    }

                    // Skip if still no cwd (session file not yet written)
                    if cwd.isEmpty { continue }

                    let project = deriveProject(cwd: cwd, home: FileManager.default.homeDirectoryForCurrentUser.path)

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

                    let birthDate = attrs[.creationDate] as? Date
                    newDerived[sessionId] = DerivedSessionData(
                        project: project,
                        cwd: cwd,
                        agentCount: agentCount,
                        customTitle: meta.customTitle,
                        jsonlMtime: mtime,
                        jsonlBirthDate: birthDate,
                        jsonlPath: jsonlPath
                    )
                }
            }

            self.derivedData = newDerived

            // Clean up meta cache for sessions that no longer have JSONL files
            let activeIds = Set(newDerived.keys)
            for sid in Array(self.sessionMetaCache.keys) {
                if !activeIds.contains(sid),
                   !fm.fileExists(atPath: "\(self.sessionsDir)/\(sid).json") {
                    self.sessionMetaCache.removeValue(forKey: sid)
                }
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

                var ttyCheckMap: [String: [String]] = [:]
                var ghosttyUUIDMap: [String: [String]] = [:]  // backward compat: old UUID-based sessions
                var itermSessions: [(id: String, termSid: String)] = []
                let savedTtyMap = self.ttyMap  // snapshot for Ghostty UUID liveness
                var jsonlFreshSessionIds: Set<String> = []

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
                        // Backward compat: old Ghostty UUID sessions need AppleScript liveness
                        // New TTY sessions: skip JSONL-fresh sessions (TTY check below handles stale)
                        if !session.terminal_session_id.contains("-") {
                            jsonlFreshSessionIds.insert(session.session_id)
                            continue
                        }
                    }

                    if session.terminal_session_id.isEmpty {
                        continue
                    } else if session.terminal == "iterm2" {
                        itermSessions.append((session.session_id, session.terminal_session_id))
                    } else if session.terminal == "ghostty" && session.terminal_session_id.contains("-") {
                        // Backward compat: old sessions with UUID directly in terminal_session_id
                        ghosttyUUIDMap[session.terminal_session_id, default: []].append(session.session_id)
                    } else if session.terminal == "t3code" {
                        // T3Code uses synthetic PIDs ("t3-pid-<pid>"), not real TTYs — skip TTY check
                        continue
                    } else {
                        let ttyName = session.terminal_session_id.replacingOccurrences(
                            of: "/dev/", with: "")
                        ttyCheckMap[ttyName, default: []].append(session.session_id)
                    }
                }

                // --- TTY liveness check (Terminal.app, Ghostty TTY sessions) ---
                if !ttyCheckMap.isEmpty {
                    let ttys = ttyCheckMap.keys.joined(separator: " ")
                    let script =
                        "for tty in \(ttys); do ps -t \"$tty\" -o comm= 2>/dev/null | grep -q claude || echo \"$tty\"; done"
                    if let output = self.runShell(script) {
                        for tty in output.split(separator: "\n").map(String.init) {
                            if let sids = ttyCheckMap[tty] { deadSessionIds.formUnion(sids) }
                        }
                    }
                }

                // --- Surface UUID liveness check (Ghostty, CMUX, etc.) ---
                // Collect UUIDs to check: from ttyMap for active Ghostty TTY sessions + old UUID sessions
                var ghosttyTerminalIds: [String: [String]] = ghosttyUUIDMap
                for (tty, sids) in ttyCheckMap {
                    if let uuid = savedTtyMap["/dev/\(tty)"] ?? savedTtyMap[tty] {
                        ghosttyTerminalIds[uuid, default: []].append(contentsOf: sids)
                    }
                }
                if !ghosttyTerminalIds.isEmpty,
                   let provider = providerFor(name: "ghostty") {
                    let liveIds = provider.liveSurfaceIds()
                    NSLog("[ClaudeMonitor] Ghostty liveness: live=%@ checking=%@",
                          liveIds.sorted().joined(separator: ","),
                          ghosttyTerminalIds.keys.sorted().joined(separator: ","))
                    if !liveIds.isEmpty {
                        for (termId, sids) in ghosttyTerminalIds where !liveIds.contains(termId) {
                            deadSessionIds.formUnion(sids)
                        }
                    }
                }

                // CMUX workspace liveness check — liveSurfaceIds() returns workspace refs + UUIDs
                let cmuxSessions = currentSessions.filter {
                    $0.0.terminal == "cmux"
                        && $0.0.status != "dead" && $0.0.status != "idle" && $0.0.status != "ended"
                        && !jsonlFreshSessionIds.contains($0.0.session_id)
                }
                if !cmuxSessions.isEmpty, let cmuxProvider = providerFor(name: "cmux") {
                    let liveIds = cmuxProvider.liveSurfaceIds()
                    if !liveIds.isEmpty {
                        for (session, _) in cmuxSessions {
                            guard let wsId = session.cmux_workspace_id, !wsId.isEmpty else { continue }
                            if !liveIds.contains(wsId) {
                                deadSessionIds.insert(session.session_id)
                            }
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
                    && session.terminal != "t3code"
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
                    if !deadSessionIds.isEmpty {
                        self._readSessionsOnIOQueue(teamLeadsByName: self.teamReader?.leadSessionByTeamName ?? [:])
                    }
                }
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

    /// Relink a session to the currently focused terminal surface.
    /// CMUX (and other surface-id providers) persist the focused surface into the
    /// session JSON — that's what matching/focus reads. Ghostty persists the
    /// TTY → UUID mapping in tty_map.json instead.
    func relinkSession(_ session: SessionInfo) {
        guard let provider = providerFor(name: session.terminal) else {
            debugLog("relink: no provider for terminal '\(session.terminal)'")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // Surface-id providers (CMUX): write cmux_surface_id/_workspace_id into
            // the session file, since matchSessions/focusSurface consult it directly.
            if let ids = provider.relinkSurfaceIds() {
                self.ioQueue.async {
                    let path = "\(self.sessionsDir)/\(session.session_id).json"
                    guard let data = FileManager.default.contents(atPath: path),
                          let out = CMUXSessionRelink.apply(jsonData: data, surfaceId: ids.surfaceId, workspaceId: ids.workspaceId, checkpoint: ids.checkpoint) else {
                        debugLog("relink: could not update session file \(path)")
                        return
                    }
                    do {
                        try out.write(to: URL(fileURLWithPath: path), options: .atomic)
                        debugLog("relink: set cmux_surface_id=\(ids.surfaceId) workspace=\(ids.workspaceId ?? "-") checkpoint=\(ids.checkpoint ?? "-") for \(session.session_id)")
                    } catch {
                        debugLog("relink: write failed for \(path): \(error)")
                    }
                }
                return
            }

            guard let uuid = provider.relinkSession(session) else {
                debugLog("relink: provider returned nil for \(session.terminal)")
                return
            }
            let ttyKey = session.terminal_session_id
            guard !ttyKey.isEmpty else {
                debugLog("relink: session has no terminal_session_id (TTY)")
                return
            }

            self.ioQueue.async {
                let mapPath = "\(self.monitorDir)/tty_map.json"
                var map = self.ttyMap
                map[ttyKey] = uuid
                if let data = try? JSONSerialization.data(withJSONObject: map),
                   let str = String(data: data, encoding: .utf8) {
                    try? str.write(toFile: mapPath, atomically: true, encoding: .utf8)
                    self.ttyMap = map
                    debugLog("relink: mapped \(ttyKey) → \(uuid) in tty_map.json")
                } else {
                    debugLog("relink: failed to serialize tty_map.json")
                }
            }
        }
    }

    /// Delete session files for team agent sessions whose team has been removed.
    func cleanupTeamAgentSessions(teamNames: Set<String>) {
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            let fm = FileManager.default
            var toRemove: [String] = []
            for (sid, meta) in self.sessionMetaCache {
                if meta.isSubagent, let tn = meta.teamName, teamNames.contains(tn) {
                    toRemove.append(sid)
                }
            }
            for sid in toRemove {
                try? fm.removeItem(atPath: "\(self.sessionsDir)/\(sid).json")
                try? fm.removeItem(atPath: "\(self.sessionsDir)/\(sid).context")
                try? fm.removeItem(atPath: "\(self.sessionsDir)/\(sid).model")
                self.sessionMetaCache.removeValue(forKey: sid)
                debugLog("Cleaned up orphaned team agent session \(sid)")
            }
            if !toRemove.isEmpty {
                self._readSessionsOnIOQueue(teamLeadsByName: self.teamReader?.leadSessionByTeamName ?? [:])
            }
        }
    }

    func readSessions() {
        let teamLeads = teamReader?.leadSessionByTeamName ?? [:]
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            self._readSessionsOnIOQueue(teamLeadsByName: teamLeads)
        }
    }

    /// Actual readSessions implementation — must be called on ioQueue.
    private func _readSessionsOnIOQueue(teamLeadsByName: [String: String] = [:]) {
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
        /// Session IDs that just transitioned cached.status != attention → new.status == attention.
        var newAttentionIds: Set<String> = []

        for file in files where file.hasSuffix(".json") {
            let path = "\(sessionsDir)/\(file)"
            let sessionId = String(file.dropLast(5)) // filename = <session_id>.json

            // Stat JSON file first (needed for phantom filter and mtime cache check)
            guard let jsonAttrs = try? fm.attributesOfItem(atPath: path),
                  let jsonMtime = jsonAttrs[.modificationDate] as? Date
            else { continue }

            let contextPath = "\(sessionsDir)/\(sessionId).context"
            let modelPath = "\(sessionsDir)/\(sessionId).model"
            let contextMtime = (try? fm.attributesOfItem(atPath: contextPath))?[.modificationDate] as? Date
            let modelMtime = (try? fm.attributesOfItem(atPath: modelPath))?[.modificationDate] as? Date

            // Fast path: all mtimes unchanged → reuse cached SessionInfo (skip JSON decode + sidecar reads)
            if let snap = sessionFileCache[sessionId],
               snap.jsonMtime == jsonMtime,
               snap.contextMtime == contextMtime,
               snap.modelMtime == modelMtime
            {
                currentFileIds.insert(sessionId)
                endedTimestamps.removeValue(forKey: sessionId)
                var enriched = snap.info
                if let derived = derivedData[sessionId] {
                    if enriched.project == "unknown" || enriched.cwd.isEmpty {
                        enriched.project = derived.project
                        enriched.cwd = derived.cwd
                    }
                    enriched.agent_count = derived.agentCount
                    enriched.custom_title = derived.customTitle
                }
                // Fallback: subagent sessions skip derivedData but their meta cache has customTitle
                if enriched.custom_title == nil {
                    enriched.custom_title = sessionMetaCache[sessionId]?.customTitle
                }
                loaded.append(enriched)
                loadedIds.insert(sessionId)
                continue
            }

            // Slow path: read and decode
            guard let data = fm.contents(atPath: path) else { continue }
            // Delete empty/corrupt session files so the hook can recreate them
            if data.isEmpty {
                try? fm.removeItem(atPath: path)
                sessionFileCache.removeValue(forKey: sessionId)
                continue
            }
            do {
                var session = try JSONDecoder().decode(SessionInfo.self, from: data)
                currentFileIds.insert(session.session_id)
                // Dead sessions: delete from disk and skip
                if session.status == "dead" {
                    try? fm.removeItem(atPath: path)
                    try? fm.removeItem(atPath: contextPath)
                    try? fm.removeItem(atPath: modelPath)
                    sessionFileCache.removeValue(forKey: sessionId)
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
                        try? fm.removeItem(atPath: contextPath)
                        try? fm.removeItem(atPath: modelPath)
                        endedTimestamps.removeValue(forKey: session.session_id)
                        endedSessionIds.insert(session.session_id)
                    }
                    sessionFileCache.removeValue(forKey: sessionId)
                    continue
                }
                // Phantom filter: T3 Code uses heartbeat; others require JSONL backing
                let age = now.timeIntervalSince(jsonMtime)
                let phantom: Bool
                if session.terminal == "t3code" {
                    phantom = isPhantomHeartbeat(mtimeAge: age)
                } else {
                    let jsonlExists = derivedData[session.session_id]?.jsonlPath != nil
                        || (derivedData[session.session_id] == nil && findJSONLPath(sessionId: session.session_id) != nil)
                    phantom = isPhantomSession(jsonlExists: jsonlExists, mtimeAge: age)
                }
                if phantom {
                    try? fm.removeItem(atPath: path)
                    try? fm.removeItem(atPath: contextPath)
                    try? fm.removeItem(atPath: modelPath)
                    try? fm.removeItem(atPath: "\(sessionsDir)/\(session.session_id).context.tmp")
                    sessionFileCache.removeValue(forKey: sessionId)
                    continue
                }
                // Session reactivated from "ended" — clear its timestamp
                endedTimestamps.removeValue(forKey: session.session_id)
                // Read context_pct from sidecar file
                if let contextData = fm.contents(atPath: contextPath),
                   let contextStr = String(data: contextData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   let pct = Int(contextStr) {
                    session.context_pct = pct
                }
                // Read model from sidecar file
                if let modelData = fm.contents(atPath: modelPath),
                   let modelStr = String(data: modelData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !modelStr.isEmpty {
                    session.model = modelStr
                }
                // Detect a fresh idle/working/etc → attention transition for realtime push.
                if session.status == "attention",
                   sessionFileCache[sessionId]?.info.status != "attention"
                {
                    newAttentionIds.insert(session.session_id)
                }
                // Update session file cache (before derivedData enrichment — agent_count re-applied each cycle)
                sessionFileCache[sessionId] = SessionFileSnapshot(
                    jsonMtime: jsonMtime, contextMtime: contextMtime, modelMtime: modelMtime,
                    info: session
                )
                // Enrich with JSONL-derived data (project, cwd, agent_count, custom_title)
                if let derived = derivedData[session.session_id] {
                    if session.project == "unknown" || session.cwd.isEmpty {
                        session.project = derived.project
                        session.cwd = derived.cwd
                    }
                    session.agent_count = derived.agentCount
                    session.custom_title = derived.customTitle
                }
                // Fallback: subagent sessions skip derivedData but their meta cache has customTitle
                if session.custom_title == nil {
                    session.custom_title = sessionMetaCache[session.session_id]?.customTitle
                }
                loaded.append(session)
                loadedIds.insert(session.session_id)
            } catch {
                NSLog(
                    "[ClaudeMonitor] Deleting corrupt session file %@: %@", file,
                    error.localizedDescription)
                try? fm.removeItem(atPath: path)
                sessionFileCache.removeValue(forKey: sessionId)
            }
        }

        // Track session files that disappeared since last read (deleted by SessionEnd hook)
        let disappeared = self.previousSessionFileIds.subtracting(currentFileIds)
        self.endedSessionIds.formUnion(disappeared)
        self.previousSessionFileIds = currentFileIds
        // Evict stale cache entries for files that no longer exist
        for sid in disappeared { sessionFileCache.removeValue(forKey: sid) }

        // Clean up orphaned sidecar files with no matching .json, older than 1 day.
        let sidecarSuffixes = [".context.tmp", ".json.tmp", ".context", ".model", ".lock"]
        for file in files {
            guard let suffix = sidecarSuffixes.first(where: { file.hasSuffix($0) }) else { continue }
            let baseName = String(file.dropLast(suffix.count))
            let jsonExists = fm.fileExists(atPath: "\(sessionsDir)/\(baseName).json")
            let sidecarPath = "\(sessionsDir)/\(file)"
            if let attrs = try? fm.attributesOfItem(atPath: sidecarPath),
               let mtime = attrs[.modificationDate] as? Date,
               isStaleTmpSidecar(hasMatchingJson: jsonExists, mtimeAge: now.timeIntervalSince(mtime)) {
                try? fm.removeItem(atPath: sidecarPath)
            }
        }

        // Load TTY → Ghostty UUID mapping (skip if file unchanged)
        let ttyMapPath = "\(monitorDir)/tty_map.json"
        let newTtyMapMtime = (try? fm.attributesOfItem(atPath: ttyMapPath))?[.modificationDate] as? Date
        if newTtyMapMtime != ttyMapMtime {
            if let ttyMapData = fm.contents(atPath: ttyMapPath),
               let decoded = try? JSONSerialization.jsonObject(with: ttyMapData) as? [String: String] {
                self.ttyMap = decoded
                self.ttyMapMtime = newTtyMapMtime
            }
        }

        // Load tmux session → Ghostty UUID mapping (skip if file unchanged)
        let tmuxMapPath = "\(monitorDir)/tmux_map.json"
        let newTmuxMapMtime = (try? fm.attributesOfItem(atPath: tmuxMapPath))?[.modificationDate] as? Date
        if newTmuxMapMtime != tmuxMapMtime {
            if let tmuxMapData = fm.contents(atPath: tmuxMapPath),
               let decoded = try? JSONSerialization.jsonObject(with: tmuxMapData) as? [String: String] {
                self.tmuxMap = decoded
                self.tmuxMapMtime = newTmuxMapMtime
            }
        }

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
                last_prompt: "",
                agent_count: derived.agentCount,
                custom_title: derived.customTitle
            )
            loaded.append(session)
        }

        // --- Team agent linking: set parent_session_id from meta cache teamName ---
        // Ensure sessionMetaCache is populated for all loaded sessions.
        // The dirSource watcher calls readSessions() without scanProjects(),
        // so newly-created agent sessions may not have cached meta yet.
        if !teamLeadsByName.isEmpty {
            for session in loaded {
                let cached = self.sessionMetaCache[session.session_id]
                let needsRead = cached == nil || (!cached!.isSubagent && cached!.teamName == nil)
                if needsRead,
                   let jsonlPath = self.findJSONLPath(sessionId: session.session_id) {
                    let currentMtime = (try? fm.attributesOfItem(atPath: jsonlPath))?[.modificationDate] as? Date
                    // Skip re-read if mtime hasn't changed (file hasn't grown)
                    guard cached == nil || currentMtime != cached?.jsonlMtime else { continue }
                    var meta = self.readJSONLHead(path: jsonlPath)
                    meta.jsonlMtime = currentMtime
                    self.sessionMetaCache[session.session_id] = meta
                }
            }
        }
        let teamNameBySession: [String: String] = loaded.reduce(into: [:]) { dict, s in
            if let tn = self.sessionMetaCache[s.session_id]?.teamName {
                dict[s.session_id] = tn
            }
        }
        let parentIds = resolveTeamParents(
            sessions: loaded,
            teamNameBySession: teamNameBySession,
            leadSessionByTeamName: teamLeadsByName
        )
        for i in loaded.indices {
            if let parentId = parentIds[loaded[i].session_id] {
                loaded[i].parent_session_id = parentId
                let teamName = teamNameBySession[loaded[i].session_id] ?? "?"
                debugLog("Linked agent \(loaded[i].session_id) (team: \(teamName)) → lead \(parentId)")
            }
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

        // Escalate "working" from any active child to parent
        if !childSessions.isEmpty {
            var parentHasChildWorking: Set<String> = []
            for child in childSessions {
                guard let parentSid = child.parent_session_id, child.status == "working" else { continue }
                parentHasChildWorking.insert(parentSid)
            }
            for i in parentSessions.indices {
                if parentHasChildWorking.contains(parentSessions[i].session_id) {
                    // Only promote to working if parent isn't already in attention or working (or dead)
                    if parentSessions[i].status != "dead" && parentSessions[i].status != "attention" && parentSessions[i].status != "working" {
                        parentSessions[i].status = "working"
                    }
                }
            }
        }

        // Count linked child sessions per parent and add to agent_count
        if !childSessions.isEmpty {
            var childCount: [String: Int] = [:]
            for child in childSessions {
                guard let parentSid = child.parent_session_id else { continue }
                childCount[parentSid, default: 0] += 1
            }
            for i in parentSessions.indices {
                let linked = childCount[parentSessions[i].session_id] ?? 0
                if linked > 0 {
                    parentSessions[i].agent_count = max(parentSessions[i].agent_count, linked)
                }
            }
        }

        // Replace loaded with parent-only sessions (children are hidden from UI)
        loaded = parentSessions

        // Separate headless sessions so they sort to the bottom and aggregate independently
        let interactiveLoaded = loaded.filter { $0.is_headless != true }
        let headlessLoaded    = loaded.filter { $0.is_headless == true }

        let sessionComparator: (SessionInfo, SessionInfo) -> Bool = { a, b in
            let cmp = a.project.localizedCaseInsensitiveCompare(b.project)
            if cmp != .orderedSame { return cmp == .orderedAscending }
            let tid0 = a.terminal_session_id
            let tid1 = b.terminal_session_id
            if let n0 = Int(tid0), let n1 = Int(tid1) { return n0 < n1 }
            if tid0 != tid1 { return tid0 < tid1 }
            return a.cwd.localizedCaseInsensitiveCompare(b.cwd) == .orderedAscending
        }

        var aggregated = aggregateSessions(interactiveLoaded, referenceDate: Date())
        aggregated.sort(by: sessionComparator)
        var headlessAgg = aggregateSessions(headlessLoaded, referenceDate: Date())
        headlessAgg.sort(by: sessionComparator)
        aggregated += headlessAgg

        // Debug: dump pipeline state to JSON (rate-limited to ≤1 write/sec)
        let sinceLastDump = now.timeIntervalSince(lastDebugDumpAt)
        if sinceLastDump >= 1.0 {
            lastDebugDumpAt = now
            dumpDebugState(aggregated: aggregated)
        }

        let hasNewAttention = !newAttentionIds.isEmpty
        DispatchQueue.main.async {
            if self.sessions != aggregated { self.sessions = aggregated }
            // Pulse AFTER sessions so subscribers reading the combined stream see the
            // attention status alongside the pulse trigger.
            if hasNewAttention { self.attentionPulse &+= 1 }
        }
    }

    /// Write current pipeline state to ~/.claude-monitor/debug.json for diagnosis.
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
            if let mode = s.permission_mode { d["permission_mode"] = mode }
            if let gid = s.ghostty_terminal_id { d["ghostty_terminal_id"] = gid }
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
    @Published var activeSessionId: String? {
        didSet {
            // Snapshot TTY of the active session for carryover on restart
            if let newId = activeSessionId,
               let session = sessionReader?.sessions.first(where: { $0.session_id == newId }) {
                lastActiveTTY = session.terminal_session_id
                lastActiveTTYTime = Date()
            }
        }
    }
    private weak var sessionReader: SessionReader?
    private var pollTimerSource: DispatchSourceTimer?
    private var workspaceObserver: Any?
    private var sessionsObserver: AnyCancellable?
    private var lastActiveTTY: String?
    private var lastActiveTTYTime: Date?
    private let backgroundQueue = DispatchQueue(label: "com.claudemonitor.activesession", qos: .utility)

    private var lastFocusedUUID: String?        // cached focused UUID to skip redundant matching

    private let terminalBundleIds: Set<String> = Set(terminalProviders.map(\.bundleIdentifier))

    init(sessionReader: SessionReader) {
        self.sessionReader = sessionReader
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleAppActivation(notification)
        }
        // React to session list changes immediately for TTY carryover
        sessionsObserver = sessionReader.$sessions.sink { [weak self] _ in
            self?.tryTTYCarryover()
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
        sessionsObserver?.cancel()
        pollTimerSource?.cancel()
    }

    private func handleAppActivation(_ notification: Notification) {
        guard let app = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication),
              let bundleId = app.bundleIdentifier else {
            stopPolling()
            return
        }
        if terminalBundleIds.contains(bundleId) {
            backgroundQueue.async { self.lastFocusedUUID = nil }  // force re-check on app switch
            startPolling()
        } else {
            stopPolling()
        }
    }

    private func startPolling() {
        detectActiveSession()  // immediate first check
        guard pollTimerSource == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + 2.0, repeating: 2.0)
        source.setEventHandler { [weak self] in self?.detectActiveSession() }
        source.resume()
        pollTimerSource = source
    }

    private func stopPolling() {
        pollTimerSource?.cancel()
        pollTimerSource = nil
        if activeSessionId != nil {
            activeSessionId = nil
        }
    }

    /// When the active session disappears (e.g. plan-accept restart) and a new session
    /// appears on the same TTY within 10s, auto-transfer focus — no AppleScript needed.
    private func tryTTYCarryover() {
        guard let tty = lastActiveTTY, !tty.isEmpty,
              let ttyTime = lastActiveTTYTime,
              Date().timeIntervalSince(ttyTime) < 10,
              let sessions = sessionReader?.sessions else { return }
        // Only act if the current activeSessionId is stale (no longer in session list)
        if let currentId = activeSessionId,
           sessions.contains(where: { $0.session_id == currentId }) {
            return  // still valid
        }
        // Find a replacement session on the same TTY
        if let replacement = sessions.first(where: { $0.terminal_session_id == tty }) {
            debugLog("TTY carryover: \(activeSessionId ?? "nil") → \(replacement.session_id) on \(tty)")
            activeSessionId = replacement.session_id
        }
    }

    private func detectActiveSession() {
        guard let sessions = sessionReader?.sessions, !sessions.isEmpty else { return }

        // Try TTY carryover before expensive terminal polling
        if activeSessionId == nil || !sessions.contains(where: { $0.session_id == activeSessionId }) {
            if let tty = lastActiveTTY, !tty.isEmpty,
               let ttyTime = lastActiveTTYTime,
               Date().timeIntervalSince(ttyTime) < 10,
               let replacement = sessions.first(where: { $0.terminal_session_id == tty }) {
                debugLog("TTY carryover (poll): \(activeSessionId ?? "nil") → \(replacement.session_id) on \(tty)")
                activeSessionId = replacement.session_id
                return
            }
        }

        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleId = app.bundleIdentifier,
              let provider = providerFor(bundleId: bundleId) else { return }

        backgroundQueue.async { [weak self] in
            guard let self = self else { return }
            guard let surface = provider.focusedSurface() else {
                // Socket unavailable (transient) — don't clear activeSessionId.
                // stopPolling() clears it when CMUX definitively loses focus.
                self.lastFocusedUUID = nil
                return
            }

            // Skip matching if focused surface hasn't changed (read/write on backgroundQueue only)
            if surface.id == self.lastFocusedUUID,
               let currentId = self.activeSessionId,
               sessions.contains(where: { $0.session_id == currentId }) {
                return
            }

            let ttyMap = self.sessionReader?.ttyMap ?? [:]
            let candidates = provider.matchSessions(sessions, toSurface: surface, ttyMap: ttyMap)

            debugLog("detectActive(\(provider.name)): surface=\(surface.id) tab=\(surface.tabName ?? "nil") candidates=\(candidates.map { "\($0.session_id)(\($0.status))" }.joined(separator: ", "))")

            let best = bestCandidate(candidates)
            self.lastFocusedUUID = surface.id
            DispatchQueue.main.async {
                self.activeSessionId = best?.session_id
            }
        }
    }
}

// MARK: - Debug Logging

private let debugLogPath = NSHomeDirectory() + "/.claude-monitor/debug.log"
private let debugLogQueue = DispatchQueue(label: "com.claudemonitor.debuglog", qos: .utility)

func debugLog(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(message)\n"
    debugLogQueue.async {
        guard let data = line.data(using: .utf8) else { return }
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

func switchToSession(_ session: SessionInfo, ttyMap: [String: String] = [:], onError: ((String) -> Void)? = nil) {
    debugLog("switchToSession: terminal=\(session.terminal) tty=\(session.terminal_session_id) project=\(session.project) sid=\(session.session_id)")
    if let provider = providerFor(name: session.terminal) {
        provider.focusSurface(session: session, ttyMap: ttyMap)
        if (provider as? CMUXProvider)?.lastFocusError == .accessDenied {
            onError?("cmux blocked the jump. Set \"automation\": { \"socketControlMode\": \"allowAll\" } in ~/.config/cmux/cmux.json and restart cmux.")
        }
    } else {
        debugLog("switchToSession: no provider for '\(session.terminal)', falling back to CWD")
        switchByTerminalCwd(cwd: session.cwd)
    }
}

func switchByTerminalCwd(cwd: String) {
    // Fallback: find any running terminal and activate it
    for provider in terminalProviders {
        if NSRunningApplication.runningApplications(withBundleIdentifier: provider.bundleIdentifier).first != nil {
            NSRunningApplication.runningApplications(withBundleIdentifier: provider.bundleIdentifier).first?.activate()
            return
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

struct SessionRowView: View, Equatable {
    let row: SessionRow
    @State private var isHovered = false
    @State private var badgeScale: CGFloat = 1.0

    static func == (l: SessionRowView, r: SessionRowView) -> Bool {
        l.row.identityHash == r.row.identityHash
    }

    private var session: SessionInfo { row.session }
    private var isDanger: Bool { session.skip_permissions == true }
    private var isHeadless: Bool { session.is_headless == true }
    private var hasTeam: Bool { row.team != nil }

    private var badgeCount: Int {
        let teamCount = row.team?.activeAgentCount ?? 0
        // Subagents only run during a turn — if session is idle, agent_count is stale
        let agentCount = session.status == "working" ? session.agent_count : 0
        return max(teamCount, agentCount)
    }

    // A team/agents session shows a simple person glyph (no count); otherwise the mode
    // icon. Single compact swatch either way — keeps the leading column narrow.
    private var iconSymbol: String {
        if hasTeam || badgeCount > 0 { return hasTeam ? "person.3.fill" : "person.2.fill" }
        return session.modeIcon
    }

    @ViewBuilder
    private var leadingIcon: some View {
        Image(systemName: iconSymbol)
            .font(.system(size: 10))
            .foregroundColor(session.statusColor)
            .frame(width: 16, height: 16)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isDanger ? Color.red.opacity(0.3) : session.statusColor.opacity(0.15))
            )
            .overlay(
                isDanger
                    ? RoundedRectangle(cornerRadius: 4).stroke(Color.red.opacity(0.5), lineWidth: 1)
                    : nil
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
            .help(session.modeLabel ?? (isDanger ? "Bypass permissions (--dangerously-skip-permissions)" : ""))
    }

    @ViewBuilder
    private var headlessRow: some View {
        HStack(alignment: .center, spacing: 0) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.clear)
                .frame(width: 3)
                .padding(.vertical, 4)

            Spacer().frame(width: 5)

            Image(systemName: "gearshape.2.fill")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.5))
                .frame(width: 16, height: 16)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.08)))

            Spacer().frame(width: 7)

            HStack(spacing: 6) {
                Text(session.custom_title ?? session.project)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                if let modelName = session.shortModelName {
                    Text(modelName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.35))
                        .fixedSize()
                }

                Text(session.elapsedString)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.35))
                    .fixedSize()

                if let pct = session.context_pct {
                    Text("\(pct)%")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(session.contextPctColor.opacity(0.7))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(session.contextPctColor.opacity(0.10)))
                        .fixedSize()
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.leading, 5)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
        .opacity(0.45)
    }

    var body: some View {
        if isHeadless {
            headlessRow
        } else {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color(red: 45/255, green: 191/255, blue: 230/255).opacity(row.isActive ? 0.8 : 0))
                .frame(width: 3)
                .padding(.vertical, 4)
                .animation(.easeInOut(duration: 0.2), value: row.isActive)

            Spacer().frame(width: 5)

            // Leading icon — nudged down to align with the title line
            leadingIcon
                .frame(width: 16, height: 16)
                .padding(.top, 4)

            Spacer().frame(width: 7)

            VStack(alignment: .leading, spacing: 2) {
                // Line 1: title + pct%
                HStack(spacing: 4) {
                    Text(session.custom_title ?? session.project)
                        .font(.system(size: 13, weight: .semibold, design: .default))
                        .foregroundColor(session.isStale ? .gray : .white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)

                    Spacer(minLength: 4)

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

                // Line 2: CWD (head-truncated) + elapsed + model
                HStack(spacing: 4) {
                    Text(session.cwd)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.35))
                        .lineLimit(1)
                        .truncationMode(.head)

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

                // Line 3: description
                if !session.last_prompt.isEmpty {
                    Text(session.last_prompt)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.55))
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.leading, 5)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .onHover { isHovered = $0 }
        }
    }
}

// MARK: - Header Bar

struct CogButton: View {
    @ObservedObject var shortcutManager: ShortcutManager
    var sessionReader: SessionReader?
    @State private var showPopover = false
    @State private var recordingSlot: Int?  // nil = not recording, 1 or 2
    @State private var recordingMonitor: Any?

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                // Jump Shortcuts section
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

                Divider()
                    .background(Color.white.opacity(0.15))

                // Actions section
                VStack(alignment: .leading, spacing: 6) {
                    actionButton(label: "Refresh Data", icon: "arrow.clockwise") {
                        sessionReader?.scanProjects()
                        sessionReader?.readSessions()  // kept for step 2; replaced by vm.refresh() in step 3
                    }
                    actionButton(label: "Reinstall Shortcuts", icon: "keyboard") {
                        shortcutManager.reinstall()
                    }
                    actionButton(label: "Restart App", icon: "arrow.counterclockwise.circle") {
                        restartApp()
                    }
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
    private func actionButton(label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.6))
                    .frame(width: 14)
                Text(label)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.8))
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
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

    private func restartApp() {
        let uid = getuid()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "launchctl kickstart -k 'gui/\(uid)/com.claude.monitor'"]
        try? task.run()
    }
}

struct HeaderBar: View {
    let sessions: [SessionInfo]
    var sessionReader: SessionReader?
    @ObservedObject var shortcutManager: ShortcutManager
    @ObservedObject var hover: PanelHoverState

    private var counts: StatusCounts { StatusCounts(sessions) }

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
                if counts.attention > 0 {
                    HStack(spacing: 3) {
                        Circle().fill(Color.orange).frame(width: 6, height: 6)
                        Text("\(counts.attention)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.orange)
                    }
                    .fixedSize()
                }
                if counts.working > 0 {
                    HStack(spacing: 3) {
                        Circle().fill(Color.workingBlue).frame(width: 6, height: 6)
                        Text("\(counts.working)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.workingBlue)
                    }
                    .fixedSize()
                }
                if counts.idle > 0 {
                    HStack(spacing: 3) {
                        Circle().fill(Color.doneGreen).frame(width: 6, height: 6)
                        Text("\(counts.idle)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.doneGreen)
                    }
                    .fixedSize()
                }
                if counts.headless > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "gearshape.2.fill")
                            .font(.system(size: 8))
                            .foregroundColor(.white.opacity(0.4))
                        Text("\(counts.headless)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    .fixedSize()
                }

                // Pin button — keeps panel expanded after mouse-out
                Button {
                    hover.isPinned.toggle()
                } label: {
                    Image(systemName: hover.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(hover.isPinned ? .white.opacity(0.9) : .white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .focusable(false)
                .fixedSize()

                CogButton(shortcutManager: shortcutManager, sessionReader: sessionReader)
                    .fixedSize()
            }
            .layoutPriority(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Compact Summary View

struct CompactSummaryView: View {
    let counts: StatusCounts

    var body: some View {
        HStack(spacing: 8) {
            if counts.attention > 0 {
                HStack(spacing: 4) {
                    Circle().fill(Color.orange).frame(width: 8, height: 8)
                    Text("\(counts.attention)")
                        .font(.system(size: 18, weight: .semibold, design: .monospaced))
                        .foregroundColor(.orange)
                }
            }
            if counts.working > 0 {
                HStack(spacing: 4) {
                    Circle().fill(Color.workingBlue).frame(width: 8, height: 8)
                    Text("\(counts.working)")
                        .font(.system(size: 18, weight: .semibold, design: .monospaced))
                        .foregroundColor(.workingBlue)
                }
            }
            if counts.idle > 0 || (counts.attention == 0 && counts.working == 0 && counts.headless == 0) {
                HStack(spacing: 4) {
                    Circle().fill(Color.doneGreen).frame(width: 8, height: 8)
                    Text("\(counts.idle)")
                        .font(.system(size: 18, weight: .semibold, design: .monospaced))
                        .foregroundColor(.doneGreen)
                }
            }
            if counts.headless > 0 && counts.attention == 0 && counts.working == 0 && counts.idle == 0 {
                HStack(spacing: 3) {
                    Image(systemName: "gearshape.2.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.4))
                    Text("\(counts.headless)")
                        .font(.system(size: 18, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Main Content View

/// Build a map of session_id → short disambiguating suffix for sessions that share a project name.
/// Computed once per sessions-array change; passed into the view rather than re-evaluated on every body call.
func buildDisambiguationMap(_ sessions: [SessionInfo]) -> [String: String] {
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
            for (session, _) in paths { result[session.session_id] = session.cwd }
        }
    }
    return result
}

struct MonitorContentView: View {
    @ObservedObject var vm: MonitorViewModel
    @ObservedObject var reader: SessionReader   // kept for ttyMap + action delegation
    @ObservedObject var shortcutManager: ShortcutManager
    @ObservedObject var hover: PanelHoverState

    private var isExpanded: Bool { hover.isExpanded }
    private var sessions: [SessionInfo] { vm.snapshot.rows.map { $0.session } }
    /// Collapsed pill turns orange when ≥1 session needs attention.
    private var showWaitingBorder: Bool { !isExpanded && StatusCounts(sessions).attention > 0 }

    static let baseBG = NSColor(red: 0.129, green: 0.016, blue: 0.314, alpha: 1.0)
    /// Orange muted toward the base background so the attention pill isn't blindingly bright.
    static let attentionBG = NSColor.systemOrange.blended(withFraction: 0.85, of: baseBG) ?? .systemOrange

    var body: some View {
        VStack(spacing: 0) {
            if isExpanded {
                // Header — always visible when expanded, drag to move
                HeaderBar(
                    sessions: sessions, sessionReader: reader,
                    shortcutManager: shortcutManager, hover: hover)

                if let errorMsg = vm.focusError {
                    HStack(spacing: 6) {
                        Text(errorMsg)
                            .font(.system(size: 11))
                            .foregroundColor(.white)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button(action: { vm.focusError = nil }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.red.opacity(0.75))
                }

                if !vm.snapshot.rows.isEmpty {
                    Divider()
                        .background(Color.white.opacity(0.1))

                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(vm.snapshot.rows) { row in
                                SessionRowView(row: row)
                                    .equatable()
                                    .overlay(
                                        FirstMouseClickArea(
                                            action: row.session.is_headless == true ? {} : {
                                                vm.focus(row.session, ttyMap: reader.ttyMap)
                                            },
                                            contextMenuBuilder: { event in
                                                let menu = NSMenu()
                                                if row.session.is_headless != true,
                                                   providerFor(name: row.session.terminal) != nil {
                                                    menu.addItem(ClosureMenuItem("Relink to Focused Tab") {
                                                        vm.relink(row.session)
                                                    })
                                                }
                                                menu.addItem(ClosureMenuItem("Delete Session") {
                                                    vm.delete(sessionId: row.session.session_id)
                                                })
                                                return menu
                                            }
                                        )
                                    )
                                if row.id != vm.snapshot.rows.last?.id {
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
            } else {
                CompactSummaryView(counts: StatusCounts(sessions))
            }
        }
        .frame(width: isExpanded ? 420 : nil)
        .fixedSize(horizontal: !isExpanded, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: showWaitingBorder ? Self.attentionBG : Self.baseBG))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    showWaitingBorder ? Color.orange : Color.white.opacity(0.1),
                    lineWidth: showWaitingBorder ? 2 : 0.5
                )
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

// MARK: - Panel Hover State

final class PanelHoverState: ObservableObject {
    @Published var isHovering = false
    @Published var isPinned = false
    var isExpanded: Bool { isHovering || isPinned }
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
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let vf = screen.visibleFrame
        let x = vf.maxX - self.frame.width - 60
        let y = vf.midY - self.frame.height / 2
        self.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func savePosition() {
        UserDefaults.standard.set(self.frame.origin.x, forKey: "monitorX")
        UserDefaults.standard.set(self.frame.origin.y, forKey: "monitorY")
    }
}

// MARK: - Click-through Hosting View

class ClickHostingView<Content: View>: NSHostingView<Content> {
    var onHoverChange: ((Bool) -> Void)?
    private var collapseTimer: Timer?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        let opts: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
        addTrackingArea(NSTrackingArea(rect: bounds, options: opts, owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        collapseTimer?.invalidate()
        collapseTimer = nil
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        collapseTimer?.invalidate()
        collapseTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in
            self?.onHoverChange?(false)
        }
    }
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

    private var hotKeyRef1: EventHotKeyRef?
    private var hotKeyRef2: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var localMonitor: Any?
    private let onTrigger: () -> Void

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
        // Defer installation until the run loop is active.
        DispatchQueue.main.async { [weak self] in
            self?.install()
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
        guard isEnabled || isEnabled2 else {
            debugLog("Shortcut install skipped: no shortcuts enabled")
            return
        }

        // Use Carbon RegisterEventHotKey for global hotkeys.
        // NSEvent.addGlobalMonitorForEvents and CGEvent taps both silently fail
        // on macOS Sequoia even with accessibility granted. Carbon hotkeys are
        // the only reliable method and don't require accessibility permission.
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                     eventKind: UInt32(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { _, event, refcon -> OSStatus in
            guard let refcon = refcon else { return OSStatus(eventNotHandledErr) }
            let mgr = Unmanaged<ShortcutManager>.fromOpaque(refcon).takeUnretainedValue()
            var hotKeyID = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard err == noErr else { return err }
            debugLog("Global shortcut triggered: hotKeyID=\(hotKeyID.id)")
            mgr.onTrigger()
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, refcon, &eventHandlerRef)

        if isEnabled {
            let carbonMods = Self.carbonModifiers(from: modifierFlags)
            let hotKeyID1 = EventHotKeyID(signature: OSType(0x434C4D31), id: 1)  // "CLM1"
            let status = RegisterEventHotKey(UInt32(keyCode), carbonMods, hotKeyID1,
                                             GetApplicationEventTarget(), 0, &hotKeyRef1)
            debugLog("RegisterEventHotKey slot1: keyCode=\(keyCode) mods=\(carbonMods) status=\(status)")
        }
        if isEnabled2 {
            let carbonMods = Self.carbonModifiers(from: modifierFlags2)
            let hotKeyID2 = EventHotKeyID(signature: OSType(0x434C4D32), id: 2)  // "CLM2"
            let status = RegisterEventHotKey(UInt32(keyCode2), carbonMods, hotKeyID2,
                                             GetApplicationEventTarget(), 0, &hotKeyRef2)
            debugLog("RegisterEventHotKey slot2: keyCode=\(keyCode2) mods=\(carbonMods) status=\(status)")
        }

        // Keep local monitor for events when our own panel is focused
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.matches(event) == true {
                debugLog("Local shortcut triggered: keyCode=\(event.keyCode)")
                self?.onTrigger()
                return nil
            }
            return event
        }
    }

    /// Convert NSEvent.ModifierFlags to Carbon modifier flags.
    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        return mods
    }

    func uninstall() {
        if let ref = hotKeyRef1 { UnregisterEventHotKey(ref) }
        if let ref = hotKeyRef2 { UnregisterEventHotKey(ref) }
        hotKeyRef1 = nil
        hotKeyRef2 = nil
        if let ref = eventHandlerRef { RemoveEventHandler(ref) }
        eventHandlerRef = nil
        if let m = localMonitor { NSEvent.removeMonitor(m) }
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
        uninstall()
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: FloatingPanel!
    let reader = SessionReader()
    let teamReader = TeamReader()
    var activeTracker: ActiveSessionTracker!
    var vm: MonitorViewModel!
    var engine: WatcherEngine!
    var activationShim: WorkspaceActivationShim!
    var activeSessionObserver: AnyCancellable?
    /// The panel frame as last positioned by us or the user (drag), used as a stable
    /// anchor reference. The hosting view auto-resizes the window top-left anchored, so
    /// only the top-left edge survives — settledFrame remembers the other edges.
    var settledFrame: NSRect?
    /// Guards against our re-anchoring setFrame re-triggering the resize/move observers.
    var isReanchoring = false
    var shortcutManager: ShortcutManager!
    var currentSessionId: String?
    let panelHover = PanelHoverState()

    @MainActor func jumpToNextSession() {
        let sessions = vm.snapshot.rows.map { $0.session }
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
                    switchToSession(candidate, ttyMap: reader.ttyMap)
                    currentSessionId = candidate.session_id
                    activeTracker.activeSessionId = candidate.session_id
                    return
                }
            } else {
                switchToSession(candidate, ttyMap: reader.ttyMap)
                currentSessionId = candidate.session_id
                activeTracker.activeSessionId = candidate.session_id
                return
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        reader.teamReader = teamReader

        shortcutManager = ShortcutManager { [weak self] in
            Task { @MainActor [weak self] in self?.jumpToNextSession() }
        }

        activeTracker = ActiveSessionTracker(sessionReader: reader)
        vm = MonitorViewModel(sessionReader: reader, teamReader: teamReader, activeTracker: activeTracker)

        engine = WatcherEngine()
        engine.viewModel = vm
        engine.start(sessionReader: reader, teamReader: teamReader, activeTracker: activeTracker)
        activationShim = WorkspaceActivationShim(engine: engine)

        // Sync currentSessionId when focus detection changes the active session,
        // so keyboard shortcut cycling starts from the currently focused session.
        activeSessionObserver = activeTracker.$activeSessionId.sink { [weak self] newId in
            guard let newId = newId else { return }
            self?.currentSessionId = newId
        }

        panel = FloatingPanel()

        let hostingView = ClickHostingView(
            rootView: MonitorContentView(
                vm: vm, reader: reader, shortcutManager: shortcutManager, hover: panelHover)
        )
        hostingView.frame = NSRect(origin: .zero, size: NSSize(width: 280, height: 40))
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        hostingView.onHoverChange = { [weak self] hovering in
            DispatchQueue.main.async { self?.panelHover.isHovering = hovering }
        }

        panel.contentView = hostingView

        panel.restorePosition()
        panel.orderFrontRegardless()
        settledFrame = panel.frame

        // The hosting view auto-resizes the window when SwiftUI content changes, anchored
        // top-left (so it grows down+right). fittingSize KVO doesn't fire reliably, so we
        // react to the window's own didResize and re-anchor based on which cell of a 3×3
        // screen grid the panel sits in. We anchor against the last settled frame
        // (collapsed/dragged position) because the auto-resize only preserves the top-left.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, let panel = self.panel, !self.isReanchoring else { return }
            let newSize = panel.frame.size
            guard newSize.width > 1, newSize.height > 1 else { return }
            let anchor = self.settledFrame ?? panel.frame
            let vf = (NSScreen.screens.first(where: { $0.frame.contains(anchor.origin) })
                ?? NSScreen.main
                ?? NSScreen.screens.first)?.visibleFrame ?? .zero
            // Horizontal: left third keeps left edge (grow right), center keeps center
            // (grow both ways), right third keeps right edge (grow left).
            let newX: CGFloat
            if anchor.midX < vf.minX + vf.width / 3 {
                newX = anchor.minX
            } else if anchor.midX > vf.minX + vf.width * 2 / 3 {
                newX = anchor.maxX - newSize.width
            } else {
                newX = anchor.midX - newSize.width / 2
            }
            // Vertical: top third keeps top edge (grow down), center keeps center,
            // bottom third keeps bottom edge (grow up). (origin.y is the bottom edge.)
            let newY: CGFloat
            if anchor.midY > vf.minY + vf.height * 2 / 3 {
                newY = anchor.maxY - newSize.height
            } else if anchor.midY < vf.minY + vf.height / 3 {
                newY = anchor.minY
            } else {
                newY = anchor.midY - newSize.height / 2
            }
            let frame = NSRect(origin: NSPoint(x: newX, y: newY), size: newSize)
            if frame != panel.frame {
                self.isReanchoring = true
                panel.setFrame(frame, display: true, animate: false)
                self.isReanchoring = false
            }
            self.settledFrame = frame
        }

        // Save position on user drag (and refresh the anchor reference). Only treat it
        // as a real drag when the mouse button is held — programmatic resizes also post
        // didMove and would otherwise corrupt the anchor.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, let panel = self.panel, !self.isReanchoring else { return }
            if NSEvent.pressedMouseButtons & 0x1 != 0 {
                self.settledFrame = panel.frame
                panel.savePosition()
            }
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
