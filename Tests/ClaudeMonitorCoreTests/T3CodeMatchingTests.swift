import XCTest
@testable import ClaudeMonitorCore

final class T3CodeMatchingTests: XCTestCase {

    private static let ref = ISO8601DateFormatter().date(from: "2026-04-20T12:00:00Z")!
    private static let recentDate = "2026-04-20T11:58:00Z"
    private static let staleDate = "2026-04-20T11:50:00Z"

    private func makeT3Session(id: String, status: String, updatedAt: String = T3CodeMatchingTests.recentDate) -> SessionInfo {
        SessionInfo(
            session_id: id, status: status, project: "test", cwd: "/tmp",
            terminal: "t3code", terminal_session_id: "t3-pid-\(id)",
            started_at: "2026-04-20T11:00:00Z", updated_at: updatedAt, last_prompt: ""
        )
    }

    func testBestCandidatePrefersAttentionOverWorking() {
        let working = makeT3Session(id: "1", status: "working")
        let attention = makeT3Session(id: "2", status: "attention")
        let result = bestCandidate([working, attention], referenceDate: Self.ref)
        XCTAssertEqual(result?.session_id, "2")
    }

    func testBestCandidatePrefersWorkingOverIdle() {
        let idle = makeT3Session(id: "1", status: "idle")
        let working = makeT3Session(id: "2", status: "working")
        let result = bestCandidate([idle, working], referenceDate: Self.ref)
        XCTAssertEqual(result?.session_id, "2")
    }

    func testBestCandidateDeomotesStaleWorkingBelowIdle() {
        let staleWorking = makeT3Session(id: "1", status: "working", updatedAt: Self.staleDate)
        let idle = makeT3Session(id: "2", status: "idle")
        let result = bestCandidate([staleWorking, idle], referenceDate: Self.ref)
        XCTAssertEqual(result?.session_id, "2")
    }
}
