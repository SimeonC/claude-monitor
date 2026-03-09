import Foundation

// MARK: - Session Model

public struct SessionInfo: Codable, Identifiable {
    public let session_id: String
    public var status: String
    public var project: String
    public var cwd: String
    public var terminal: String
    public var terminal_session_id: String
    public var started_at: String
    public var updated_at: String
    public var last_prompt: String
    public var agent_count: Int
    public var parent_session_id: String?
    public var context_pct: Int?
    public var model: String?
    public var skip_permissions: Bool?

    public var id: String { session_id }

    public enum CodingKeys: String, CodingKey {
        case session_id, status, project, cwd, terminal, terminal_session_id,
            started_at, updated_at, last_prompt, agent_count, parent_session_id, context_pct,
            model, skip_permissions
    }

    public init(
        session_id: String, status: String, project: String, cwd: String,
        terminal: String, terminal_session_id: String,
        started_at: String, updated_at: String, last_prompt: String,
        agent_count: Int = 0, parent_session_id: String? = nil,
        context_pct: Int? = nil, model: String? = nil, skip_permissions: Bool? = nil
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
        self.parent_session_id = parent_session_id
        self.context_pct = context_pct
        self.model = model
        self.skip_permissions = skip_permissions
    }

    public init(from decoder: Decoder) throws {
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
        parent_session_id = try? c.decode(String.self, forKey: .parent_session_id)
        context_pct = try? c.decode(Int.self, forKey: .context_pct)
        model = try? c.decode(String.self, forKey: .model)
        skip_permissions = try? c.decode(Bool.self, forKey: .skip_permissions)
    }

    public var shortModelName: String? {
        guard let m = model, !m.isEmpty else { return nil }
        // "Claude 3.5 Sonnet" -> "Sonnet 3.5", "Claude Haiku 4.5" -> "Haiku 4.5"
        let stripped = m.hasPrefix("Claude ") ? String(m.dropFirst(7)) : m
        // Rearrange "3.5 Sonnet" -> "Sonnet 3.5" if version comes first
        let parts = stripped.split(separator: " ", maxSplits: 1)
        if parts.count == 2, parts[0].first?.isNumber == true {
            return "\(parts[1]) \(parts[0])"
        }
        return stripped
    }

    public var statusIcon: String {
        switch status {
        case "starting": return "circle.dotted"
        case "working": return "circle.fill"
        case "idle": return "checkmark.circle.fill"
        case "attention": return "exclamationmark.triangle.fill"
        case "shutting_down": return "arrow.down.circle"
        default: return "circle"
        }
    }

    public var displayStatus: String {
        switch status {
        case "starting": return "starting"
        case "working": return "working"
        case "idle": return "idle"
        case "attention": return "attention"
        case "shutting_down": return "exiting"
        default: return status
        }
    }

    public var elapsedString: String {
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

    /// Returns whether the session hasn't been updated within the last 10 minutes,
    /// relative to the given reference date (injectable for testing).
    public func isStale(at referenceDate: Date = Date()) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: updated_at)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: updated_at)
        }
        guard let updated = date else { return false }
        return referenceDate.timeIntervalSince(updated) > 600  // 10 minutes
    }

    public var isStale: Bool { isStale(at: Date()) }
}
