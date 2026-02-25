import Cocoa
import Combine
import SwiftUI

// MARK: - Config Manager

struct MonitorConfig: Codable {
    var tts_provider: String
    var elevenlabs: ElevenLabsConfig
    var say: SayConfig
    var announce: AnnounceConfig

    struct ElevenLabsConfig: Codable {
        var env_file: String
        var voice_id: String?
        var model: String
        var stability: Double
        var similarity_boost: Double
        var voice_design_prompt: String?
        var voice_design_name: String?
    }
    struct SayConfig: Codable {
        var voice: String
        var rate: Int
    }
    struct AnnounceConfig: Codable {
        var enabled: Bool
        var on_done: Bool
        var on_attention: Bool
        var on_start: Bool
        var volume: Double
    }
    struct SavedVoice: Codable {
        var id: String
        var name: String
    }
    var voices: [SavedVoice]?
}

// MARK: - ElevenLabs Voice Info

struct ElevenLabsVoice: Identifiable {
    let id: String
    let name: String
}

struct ElevenLabsVoicesResponse: Codable {
    struct Voice: Codable {
        let voice_id: String
        let name: String
        let category: String?
    }
    let voices: [Voice]
}

class VoiceFetcher: ObservableObject {
    @Published var voices: [ElevenLabsVoice] = []
    @Published var hasFetched = false
    private var apiKey: String?

    func loadAPIKey(envFilePath: String) {
        let expanded = (envFilePath as NSString).expandingTildeInPath
        guard let content = try? String(contentsOfFile: expanded, encoding: .utf8) else { return }
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("ELEVENLABS_API_KEY=") {
                apiKey = String(trimmed.dropFirst("ELEVENLABS_API_KEY=".count))
                break
            }
        }
    }

    func fetchVoices() {
        guard let apiKey = apiKey, !apiKey.isEmpty else { return }
        guard let url = URL(string: "https://api.elevenlabs.io/v1/voices") else { return }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let data = data,
                let response = try? JSONDecoder().decode(ElevenLabsVoicesResponse.self, from: data)
            else {
                return
            }
            // Only show user's own voices (cloned, generated, professional), not premade
            let voices = response.voices
                .filter { $0.category != "premade" }
                .map { ElevenLabsVoice(id: $0.voice_id, name: $0.name) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async {
                self?.voices = voices
                self?.hasFetched = true
            }
        }.resume()
    }

    func name(for voiceId: String) -> String? {
        voices.first(where: { $0.id == voiceId })?.name
    }

    func resolveVoiceName(id: String, completion: @escaping (String?) -> Void) {
        guard let apiKey = apiKey, !apiKey.isEmpty else {
            completion(nil)
            return
        }
        guard let url = URL(string: "https://api.elevenlabs.io/v1/voices/\(id)") else {
            completion(nil)
            return
        }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = data,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let name = json["name"] as? String
            else {
                completion(nil)
                return
            }
            completion(name)
        }.resume()
    }

    /// Design a voice from a text prompt, save it, and return the voice_id + name
    func designVoice(prompt: String, name: String, completion: @escaping (String?, String?) -> Void)
    {
        guard let apiKey = apiKey, !apiKey.isEmpty else {
            completion(nil, nil)
            return
        }
        guard let designURL = URL(string: "https://api.elevenlabs.io/v1/text-to-voice/design")
        else {
            completion(nil, nil)
            return
        }

        // Step 1: Generate preview
        var request = URLRequest(url: designURL)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "voice_description": prompt,
            "text":
                "Hello. A session just finished — your project is done and ready for review. Another session needs your attention, it looks like there is a permission prompt waiting. Everything else is still running smoothly.",
            "model_id": "eleven_multilingual_ttv_v2",
            "guidance_scale": 5,
            "quality": 0.9,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let data = data,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let previews = json["previews"] as? [[String: Any]],
                let first = previews.first,
                let generatedId = first["generated_voice_id"] as? String
            else {
                completion(nil, nil)
                return
            }

            // Step 2: Save as permanent voice
            self?.saveDesignedVoice(
                generatedId: generatedId, name: name, prompt: prompt, completion: completion)
        }.resume()
    }

    private func saveDesignedVoice(
        generatedId: String, name: String, prompt: String,
        completion: @escaping (String?, String?) -> Void
    ) {
        guard let apiKey = apiKey, !apiKey.isEmpty else {
            completion(nil, nil)
            return
        }
        guard let url = URL(string: "https://api.elevenlabs.io/v1/text-to-voice") else {
            completion(nil, nil)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "voice_name": name,
            "voice_description": prompt,
            "generated_voice_id": generatedId,
            "labels": ["source": "claude-monitor"],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = data,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let voiceId = json["voice_id"] as? String
            else {
                completion(nil, nil)
                return
            }
            let voiceName = json["name"] as? String ?? name
            completion(voiceId, voiceName)
        }.resume()
    }
}

class ConfigManager: ObservableObject {
    @Published var config: MonitorConfig?
    let voiceFetcher = VoiceFetcher()

    static let configPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude/monitor/config.json"
    }()

    init() {
        load()
        // Kick off voice fetch
        if let envFile = config?.elevenlabs.env_file {
            voiceFetcher.loadAPIKey(envFilePath: envFile)
            voiceFetcher.fetchVoices()
        }
    }

    func load() {
        guard let data = FileManager.default.contents(atPath: Self.configPath),
            let decoded = try? JSONDecoder().decode(MonitorConfig.self, from: data)
        else { return }
        self.config = decoded
    }

    func setVoice(_ voiceId: String) {
        config?.elevenlabs.voice_id = voiceId
        save()
    }

    func toggleVoice() {
        config?.announce.enabled.toggle()
        save()
    }

    var voiceEnabled: Bool {
        config?.announce.enabled ?? true
    }

    func save() {
        guard let config = config else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        try? data.write(to: URL(fileURLWithPath: Self.configPath))
    }

    var currentVoiceId: String {
        config?.elevenlabs.voice_id ?? ""
    }

    func voiceName(for id: String) -> String? {
        if let saved = config?.voices?.first(where: { $0.id == id }) {
            return saved.name
        }
        return voiceFetcher.name(for: id)
    }

    var allVoices: [ElevenLabsVoice] {
        var combined: [ElevenLabsVoice] = []
        var seenIds = Set<String>()
        if let saved = config?.voices {
            for v in saved {
                combined.append(ElevenLabsVoice(id: v.id, name: v.name))
                seenIds.insert(v.id)
            }
        }
        for v in voiceFetcher.voices {
            if !seenIds.contains(v.id) {
                combined.append(v)
            }
        }
        return combined
    }

    func addVoice(id: String, name: String) {
        var voices = config?.voices ?? []
        if !voices.contains(where: { $0.id == id }) {
            voices.append(MonitorConfig.SavedVoice(id: id, name: name))
            config?.voices = voices
            save()
        }
    }
}

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
    private var dirSource: DispatchSourceFileSystemObject?
    private var projectsWatcher: DirectoryWatcher?

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

        // FSEvents: instant reload when session files change
        let fd = open(sessionsDir, O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .delete, .rename, .extend],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                self?.readSessions()
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            dirSource = source
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
                try? fm.removeItem(atPath: path)
                NSLog(
                    "[ClaudeMonitor] Pruned pre-boot session %@ (updated %@)", session.session_id,
                    session.updated_at)
            }
        }
    }

    /// Remove legacy `discovered-*` session files from the old TTY-based discovery system.
    private func cleanupLegacyDiscoveredSessions() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: sessionsDir) else { return }
        for file in files where file.hasPrefix("discovered-") && file.hasSuffix(".json") {
            try? fm.removeItem(atPath: "\(sessionsDir)/\(file)")
            NSLog("[ClaudeMonitor] Removed legacy discovered session %@", file)
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
        // Remove destination first — moveItem fails if it already exists
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.moveItem(atPath: tmpPath, toPath: path)
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
                    let existing = try? JSONDecoder().decode(SessionInfo.self, from: data)
                {
                    // Don't touch shutting_down sessions — they're waiting to be hidden
                    if existing.status == "shutting_down" { continue }

                    var updated = existing
                    if updated.project == "unknown" || updated.cwd.isEmpty {
                        updated.project = project
                        updated.cwd = cwd
                    }
                    if !lastPrompt.isEmpty {
                        updated.last_prompt = lastPrompt
                    }
                    updated.agent_count = agentCount
                    updated.updated_at = nowString
                    writeSessionFile(updated, to: sessionFile)
                } else if mtime > now.addingTimeInterval(-30) {
                    // Only create for JSONLs modified in last 30s (recovery after monitor restart).
                    // Older JSONLs without session files were intentionally cleaned up.
                    let session = SessionInfo(
                        session_id: sessionId, status: "starting",
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

            // Delete dead session files (skip team leads with active agents)
            for sid in deadSessionIds {
                if self.sessionHasActiveTeam(sid) {
                    NSLog("[ClaudeMonitor] Skipping prune of team lead %@ (has active agents)", sid)
                    continue
                }
                let path = "\(self.sessionsDir)/\(sid).json"
                try? FileManager.default.removeItem(atPath: path)
                NSLog("[ClaudeMonitor] Pruned dead session %@", sid)
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
                    "[ClaudeMonitor] Deleting corrupt session file %@: %@", file,
                    error.localizedDescription)
                try? fm.removeItem(atPath: path)
            }
        }

        // Aggregate sessions with the same project name
        let statusPriority: [String: Int] = [
            "attention": 0, "working": 1, "idle": 2, "shutting_down": 3, "starting": 4,
        ]
        var grouped: [String: [SessionInfo]] = [:]
        for s in loaded { grouped[s.project, default: []].append(s) }

        // Merge groups where one session's CWD is ancestor of another's
        // e.g. "survey" (cwd: .../survey) absorbs "survey-e2e" (cwd: .../survey/apps/survey-e2e)
        var didMerge = true
        while didMerge {
            didMerge = false
            let keys = Array(grouped.keys)
            outer: for i in 0..<keys.count {
                for j in (i + 1)..<keys.count {
                    let a = keys[i]
                    let b = keys[j]
                    let cwdsA = grouped[a]!.map { $0.cwd }
                    let cwdsB = grouped[b]!.map { $0.cwd }
                    var aIsParent = false
                    var bIsParent = false
                    for cwdA in cwdsA {
                        for cwdB in cwdsB {
                            if cwdB.hasPrefix(cwdA + "/") { aIsParent = true }
                            if cwdA.hasPrefix(cwdB + "/") { bIsParent = true }
                        }
                    }
                    if aIsParent {
                        grouped[a]!.append(contentsOf: grouped[b]!)
                        grouped.removeValue(forKey: b)
                        didMerge = true
                        break outer
                    } else if bIsParent {
                        grouped[b]!.append(contentsOf: grouped[a]!)
                        grouped.removeValue(forKey: a)
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

// MARK: - Terminal Switcher

func switchToSession(_ session: SessionInfo) {
    NSLog(
        "[ClaudeMonitor] switchToSession: terminal=\(session.terminal) tty=\(session.terminal_session_id) project=\(session.project)"
    )
    if session.terminal == "iterm2" && !session.terminal_session_id.isEmpty {
        switchToITerm2(sessionId: session.terminal_session_id)
    } else if session.terminal == "ghostty" {
        switchToGhostty(cwd: session.cwd)
    } else if session.terminal == "terminal" && !session.terminal_session_id.isEmpty {
        switchToTerminal(ttyPath: session.terminal_session_id)
    } else {
        NSLog("[ClaudeMonitor] falling back to cwd switch (no terminal info)")
        switchByTerminalCwd(cwd: session.cwd)
    }

    // Yield active status so the terminal gets keyboard focus.
    // The floating panel stays visible but the monitor app deactivates.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        NSApp.hide(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NSApp.unhideWithoutActivation()
        }
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

func switchToGhostty(cwd: String) {
    let basename = (cwd as NSString).lastPathComponent

    // Find the Ghostty process
    guard
        let ghosttyApp = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.mitchellh.ghostty"
        ).first
            ?? NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == "Ghostty" }
            )
    else {
        return
    }

    let appElement = AXUIElementCreateApplication(ghosttyApp.processIdentifier)

    // Request accessibility if needed
    let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(opts)

    // Get all windows
    var windowsRef: CFTypeRef?
    guard
        AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
            == .success,
        let windows = windowsRef as? [AXUIElement]
    else {
        ghosttyApp.activate()
        return
    }

    // Find window whose title contains project basename or cwd
    for window in windows {
        var titleRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
                == .success,
            let title = titleRef as? String
        else { continue }

        if title.contains(basename) || title.contains(cwd) {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            break
        }
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

    // Clean up session file after delay
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let sessionFile = "\(home)/.claude/monitor/sessions/\(session.session_id).json"
    DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
        try? FileManager.default.removeItem(atPath: sessionFile)
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
    var onKill: (() -> Void)? = nil
    @State private var isHovered = false
    @State private var isKilling = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Color.clear.frame(width: 0, height: 0)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    PulsingDot(
                        color: session.statusColor,
                        isPulsing: session.status == "working"
                    )
                    .offset(y: 1)

                    Text(session.project)
                        .font(.system(size: 13, weight: .semibold, design: .default))
                        .foregroundColor(session.isStale ? .gray : .white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)

                    Spacer(minLength: 4)

                    Text(session.elapsedString)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5))
                        .fixedSize()

                    let badgeCount = max(teamInfo?.activeAgentCount ?? 0, session.agent_count)
                    if badgeCount > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "person.2.fill")
                                .font(.system(size: 8))
                            Text("\(badgeCount)")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                        }
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.08))
                        )
                        .fixedSize()
                    }

                    if onKill != nil {
                        ZStack {
                            if isKilling {
                                PulsingDot(color: .red, isPulsing: true)
                            } else if isHovered {
                                Button {
                                    isKilling = true
                                    onKill?()
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(.white.opacity(0.4))
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(width: 28, height: 28)
                    }

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
                }

                if !session.last_prompt.isEmpty {
                    Text(session.last_prompt)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.55))
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 0)
        .padding(.bottom, 8)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Header Bar

// MARK: - Settings Popover

struct SettingsPopover: View {
    @ObservedObject var configManager: ConfigManager
    @ObservedObject var voiceFetcher: VoiceFetcher
    var sessionReader: SessionReader?
    @State private var pastedVoiceId: String? = nil
    @State private var refreshed = false
    @State private var isGenerating = false
    @State private var generateResult: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Refresh sessions
            Button {
                sessionReader?.scanProjects()
                sessionReader?.readSessions()
                refreshed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { refreshed = false }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: refreshed ? "checkmark" : "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundColor(refreshed ? .green : .white.opacity(0.4))
                    Text(refreshed ? "Refreshed" : "Refresh sessions")
                        .font(.system(size: 11))
                        .foregroundColor(refreshed ? .green.opacity(0.8) : .white.opacity(0.6))
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            Divider().background(Color.white.opacity(0.1))

            // Master toggle
            Button {
                configManager.toggleVoice()
            } label: {
                HStack(spacing: 6) {
                    Image(
                        systemName: configManager.voiceEnabled
                            ? "speaker.wave.2.fill" : "speaker.slash.fill"
                    )
                    .font(.system(size: 10))
                    .foregroundColor(configManager.voiceEnabled ? .cyan : .gray)
                    Text(configManager.voiceEnabled ? "Voice on" : "Voice off")
                        .font(.system(size: 11))
                        .foregroundColor(configManager.voiceEnabled ? .white : .white.opacity(0.4))
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if configManager.voiceEnabled {
                Divider().background(Color.white.opacity(0.1))

                // Current voice display
                if let name = configManager.voiceName(for: configManager.currentVoiceId) {
                    HStack(spacing: 4) {
                        Text(name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.cyan)
                        Spacer()
                        Text(String(configManager.currentVoiceId.prefix(8)))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.white.opacity(0.2))
                    }
                }

                Text("Voice")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
                    .textCase(.uppercase)

                if voiceFetcher.hasFetched || !(configManager.config?.voices ?? []).isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(configManager.allVoices) { voice in
                                let isSelected = configManager.currentVoiceId == voice.id
                                Button {
                                    configManager.setVoice(voice.id)
                                    pastedVoiceId = nil
                                } label: {
                                    HStack(spacing: 6) {
                                        Circle()
                                            .fill(
                                                isSelected ? Color.cyan : Color.white.opacity(0.15)
                                            )
                                            .frame(width: 6, height: 6)
                                        Text(voice.name)
                                            .font(.system(size: 11))
                                            .foregroundColor(
                                                isSelected ? .white : .white.opacity(0.5)
                                            )
                                            .lineLimit(1)
                                        Spacer()
                                    }
                                    .padding(.vertical, 2)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                } else {
                    Text("Loading voices...")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.3))
                }

                Divider().background(Color.white.opacity(0.1))

                // Paste voice ID from clipboard
                Button {
                    if let pasted = NSPasteboard.general.string(forType: .string)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                        !pasted.isEmpty
                    {
                        configManager.setVoice(pasted)
                        pastedVoiceId = String(pasted.prefix(20))
                        // Resolve name and persist to voice list
                        let voiceId = pasted
                        if let existing = configManager.voiceName(for: voiceId) {
                            configManager.addVoice(id: voiceId, name: existing)
                        } else {
                            voiceFetcher.resolveVoiceName(id: voiceId) { name in
                                DispatchQueue.main.async {
                                    configManager.addVoice(
                                        id: voiceId,
                                        name: name ?? "Voice \(String(voiceId.prefix(8)))")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.3))
                        Text("Paste voice ID")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.4))
                        Spacer()
                    }
                }
                .buttonStyle(.plain)

                if let pasted = pastedVoiceId {
                    Text("Set to \(pasted)...")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.green.opacity(0.6))
                }

                // Generate voice from design prompt
                if let prompt = configManager.config?.elevenlabs.voice_design_prompt,
                    !prompt.isEmpty
                {
                    Divider().background(Color.white.opacity(0.1))

                    Button {
                        guard !isGenerating else { return }
                        isGenerating = true
                        generateResult = nil
                        let voiceName =
                            configManager.config?.elevenlabs.voice_design_name ?? "claude-monitor"
                        voiceFetcher.designVoice(prompt: prompt, name: voiceName) { voiceId, name in
                            DispatchQueue.main.async {
                                isGenerating = false
                                if let voiceId = voiceId, let name = name {
                                    configManager.setVoice(voiceId)
                                    configManager.addVoice(id: voiceId, name: name)
                                    generateResult = name
                                    voiceFetcher.fetchVoices()
                                } else {
                                    generateResult = "failed"
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if isGenerating {
                                ProgressView()
                                    .scaleEffect(0.5)
                                    .frame(width: 10, height: 10)
                            } else {
                                Image(systemName: "wand.and.stars")
                                    .font(.system(size: 9))
                                    .foregroundColor(.purple.opacity(0.6))
                            }
                            Text(isGenerating ? "Generating..." : "Generate voice")
                                .font(.system(size: 10))
                                .foregroundColor(
                                    isGenerating ? .purple.opacity(0.4) : .purple.opacity(0.6))
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isGenerating)

                    if let result = generateResult {
                        Text(result == "failed" ? "Generation failed" : "Created \"\(result)\"")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(
                                result == "failed" ? .red.opacity(0.6) : .green.opacity(0.6))
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 200)
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
        )
    }
}

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
    }
}

struct HeaderBar: View {
    let sessions: [SessionInfo]
    @ObservedObject var configManager: ConfigManager
    var sessionReader: SessionReader?
    @State private var showSettings = false

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

            HStack(spacing: 8) {
                if attentionCount > 0 {
                    HStack(spacing: 3) {
                        Circle().fill(Color.orange).frame(width: 6, height: 6)
                        Text("\(attentionCount)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.orange)
                    }
                }
                if workingCount > 0 {
                    HStack(spacing: 3) {
                        Circle().fill(Color.workingBlue).frame(width: 6, height: 6)
                        Text("\(workingCount)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.workingBlue)
                    }
                }
                if idleCount > 0 {
                    HStack(spacing: 3) {
                        Circle().fill(Color.doneGreen).frame(width: 6, height: 6)
                        Text("\(idleCount)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.doneGreen)
                    }
                }

                Text("\(sessions.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.4))

                RefreshButton(sessionReader: sessionReader)

                Button {
                    showSettings.toggle()
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .focusable(false)
                .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                    SettingsPopover(
                        configManager: configManager, voiceFetcher: configManager.voiceFetcher,
                        sessionReader: sessionReader)
                }
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
    @ObservedObject var configManager: ConfigManager
    @State private var isExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            // Header — always visible, drag to move
            HeaderBar(
                sessions: reader.sessions, configManager: configManager, sessionReader: reader)

            if isExpanded && !reader.sessions.isEmpty {
                Divider()
                    .background(Color.white.opacity(0.1))

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(reader.sessions) { session in
                            Button {
                                switchToSession(session)
                            } label: {
                                SessionRowView(
                                    session: session,
                                    teamInfo: teamReader.teamsBySession[session.session_id],
                                    onKill: { killSession(session) }
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
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
    override var canBecomeKey: Bool { true }
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

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: FloatingPanel!
    let reader = SessionReader()
    let teamReader = TeamReader()
    let configManager = ConfigManager()
    var sizeObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        panel = FloatingPanel()

        let hostingView = ClickHostingView(
            rootView: MonitorContentView(
                reader: reader, teamReader: teamReader, configManager: configManager)
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
