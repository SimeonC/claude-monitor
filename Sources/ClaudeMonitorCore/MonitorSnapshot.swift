import Foundation

// MARK: - Status Bucket

public enum StatusBucket: Hashable {
    case attention
    case working
    case idle
    case other

    public static func from(_ status: String) -> StatusBucket {
        switch status {
        case "attention": return .attention
        case "working": return .working
        case "idle": return .idle
        default: return .other
        }
    }
}

// MARK: - Session Row

public struct SessionRow: Identifiable {
    public let id: String
    public let identityHash: UInt64
    public let session: SessionInfo
    public let displayName: String
    public let team: TeamInfo?
    public let isTeamLead: Bool
    public let isActive: Bool
    public let statusBucket: StatusBucket

    public init(
        id: String,
        identityHash: UInt64,
        session: SessionInfo,
        displayName: String,
        team: TeamInfo?,
        isTeamLead: Bool,
        isActive: Bool,
        statusBucket: StatusBucket
    ) {
        self.id = id
        self.identityHash = identityHash
        self.session = session
        self.displayName = displayName
        self.team = team
        self.isTeamLead = isTeamLead
        self.isActive = isActive
        self.statusBucket = statusBucket
    }
}

// MARK: - Monitor Snapshot

public struct MonitorSnapshot {
    public let generation: UInt64
    public let rows: [SessionRow]
    public let activeSessionId: String?
    public let totalCount: Int

    public init(generation: UInt64, rows: [SessionRow], activeSessionId: String?, totalCount: Int) {
        self.generation = generation
        self.rows = rows
        self.activeSessionId = activeSessionId
        self.totalCount = totalCount
    }

    public static let empty = MonitorSnapshot(
        generation: 0, rows: [], activeSessionId: nil, totalCount: 0
    )
}
