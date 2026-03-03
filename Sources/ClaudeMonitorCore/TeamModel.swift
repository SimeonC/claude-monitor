import Foundation

// MARK: - Team Model

public struct TeamMember: Codable {
    public let name: String
    public let agentType: String
    public let model: String?
    public let color: String?
    public let isActive: Bool?

    public init(name: String, agentType: String, model: String? = nil, color: String? = nil, isActive: Bool? = nil) {
        self.name = name
        self.agentType = agentType
        self.model = model
        self.color = color
        self.isActive = isActive
    }
}

public struct TeamConfig: Codable {
    public let name: String
    public let description: String?
    public let leadSessionId: String?
    public let members: [TeamMember]?
}

public struct TaskInfo: Codable {
    public let subject: String?
    public let status: String?
    public let owner: String?
    public let activeForm: String?
}

public struct TeamInfo {
    public let name: String
    public let activeAgentCount: Int  // active members excluding lead
    public let members: [TeamMember]
    public let tasks: [TaskInfo]

    public init(name: String, activeAgentCount: Int, members: [TeamMember], tasks: [TaskInfo]) {
        self.name = name
        self.activeAgentCount = activeAgentCount
        self.members = members
        self.tasks = tasks
    }
}
