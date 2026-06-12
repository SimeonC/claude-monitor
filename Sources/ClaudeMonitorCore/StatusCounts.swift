public struct StatusCounts {
    public let attention: Int
    public let working: Int
    public let idle: Int
    public let headless: Int
    public let total: Int

    public init(_ sessions: [SessionInfo]) {
        let interactive = sessions.filter { $0.is_headless != true }
        attention = interactive.filter { $0.status == "attention" }.count
        working   = interactive.filter { $0.status == "working" }.count
        idle      = interactive.filter { $0.status == "idle" }.count
        headless  = sessions.filter { $0.is_headless == true }.count
        total     = sessions.count
    }
}
