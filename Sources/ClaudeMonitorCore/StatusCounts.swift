public struct StatusCounts {
    public let attention: Int
    public let working: Int
    public let idle: Int
    public let total: Int

    public init(_ sessions: [SessionInfo]) {
        attention = sessions.filter { $0.status == "attention" }.count
        working = sessions.filter { $0.status == "working" }.count
        idle = sessions.filter { $0.status == "idle" }.count
        total = sessions.count
    }
}
