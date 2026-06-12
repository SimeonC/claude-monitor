import XCTest
@testable import ClaudeMonitorCore

final class StatusCountsTests: XCTestCase {

    private let fmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func makeSession(status: String, contextPct: Int? = nil) -> SessionInfo {
        SessionInfo(
            session_id: UUID().uuidString,
            status: status,
            project: "proj",
            cwd: "/proj",
            terminal: "",
            terminal_session_id: "",
            started_at: fmt.string(from: Date()),
            updated_at: fmt.string(from: Date()),
            last_prompt: "",
            context_pct: contextPct
        )
    }

    func testEmptySessionsAllZero() {
        let counts = StatusCounts([])
        XCTAssertEqual(counts.attention, 0)
        XCTAssertEqual(counts.working, 0)
        XCTAssertEqual(counts.idle, 0)
        XCTAssertEqual(counts.total, 0)
    }

    func testCountsAttention() {
        let sessions = [makeSession(status: "attention"), makeSession(status: "attention")]
        let counts = StatusCounts(sessions)
        XCTAssertEqual(counts.attention, 2)
        XCTAssertEqual(counts.working, 0)
        XCTAssertEqual(counts.idle, 0)
        XCTAssertEqual(counts.total, 2)
    }

    func testCountsWorking() {
        let sessions = [makeSession(status: "working")]
        let counts = StatusCounts(sessions)
        XCTAssertEqual(counts.working, 1)
        XCTAssertEqual(counts.attention, 0)
        XCTAssertEqual(counts.idle, 0)
        XCTAssertEqual(counts.total, 1)
    }

    func testCountsIdle() {
        let sessions = [makeSession(status: "idle"), makeSession(status: "idle"), makeSession(status: "idle")]
        let counts = StatusCounts(sessions)
        XCTAssertEqual(counts.idle, 3)
        XCTAssertEqual(counts.attention, 0)
        XCTAssertEqual(counts.working, 0)
        XCTAssertEqual(counts.total, 3)
    }

    func testMixedStatuses() {
        let sessions = [
            makeSession(status: "attention"),
            makeSession(status: "working"),
            makeSession(status: "working"),
            makeSession(status: "idle"),
        ]
        let counts = StatusCounts(sessions)
        XCTAssertEqual(counts.attention, 1)
        XCTAssertEqual(counts.working, 2)
        XCTAssertEqual(counts.idle, 1)
        XCTAssertEqual(counts.total, 4)
    }

    func testTotalIncludesUnknownStatuses() {
        let sessions = [makeSession(status: "attention"), makeSession(status: "unknown")]
        let counts = StatusCounts(sessions)
        XCTAssertEqual(counts.total, 2)
        XCTAssertEqual(counts.attention, 1)
    }

    private func makeHeadlessSession(status: String, contextPct: Int? = nil) -> SessionInfo {
        SessionInfo(
            session_id: UUID().uuidString,
            status: status,
            project: "proj",
            cwd: "/proj",
            terminal: "",
            terminal_session_id: "",
            started_at: fmt.string(from: Date()),
            updated_at: fmt.string(from: Date()),
            last_prompt: "",
            context_pct: contextPct,
            is_headless: true
        )
    }

    func testHeadlessExcludedFromInteractiveCounts() {
        let sessions = [
            makeSession(status: "working"),
            makeHeadlessSession(status: "working"),
        ]
        let counts = StatusCounts(sessions)
        XCTAssertEqual(counts.working, 1)
        XCTAssertEqual(counts.headless, 1)
        XCTAssertEqual(counts.total, 2)
    }

    func testHeadlessCountedSeparately() {
        let sessions = [
            makeHeadlessSession(status: "idle"),
            makeHeadlessSession(status: "working"),
            makeSession(status: "attention"),
        ]
        let counts = StatusCounts(sessions)
        XCTAssertEqual(counts.headless, 2)
        XCTAssertEqual(counts.attention, 1)
        XCTAssertEqual(counts.idle, 0)
        XCTAssertEqual(counts.working, 0)
        XCTAssertEqual(counts.total, 3)
    }

    // MARK: - workingContextPcts

    func testWorkingContextPctsEmptyWhenNoSessions() {
        XCTAssertEqual(StatusCounts([]).workingContextPcts, [])
    }

    func testWorkingContextPctsIncludesWorkingAtOrAboveThreshold() {
        let sessions = [makeSession(status: "working", contextPct: 75)]
        XCTAssertEqual(StatusCounts(sessions).workingContextPcts, [75])
    }

    func testWorkingContextPctsExcludesWorkingBelowThreshold() {
        let sessions = [makeSession(status: "working", contextPct: 30)]
        XCTAssertEqual(StatusCounts(sessions).workingContextPcts, [])
    }

    func testWorkingContextPctsExcludesNonWorkingEvenAboveThreshold() {
        let sessions = [
            makeSession(status: "idle", contextPct: 75),
            makeSession(status: "attention", contextPct: 90),
        ]
        XCTAssertEqual(StatusCounts(sessions).workingContextPcts, [])
    }

    func testWorkingContextPctsExcludesHeadlessSessions() {
        let sessions = [makeHeadlessSession(status: "working", contextPct: 80)]
        XCTAssertEqual(StatusCounts(sessions).workingContextPcts, [])
    }

    func testWorkingContextPctsExcludesNilContextPct() {
        let sessions = [makeSession(status: "working", contextPct: nil)]
        XCTAssertEqual(StatusCounts(sessions).workingContextPcts, [])
    }

    func testWorkingContextPctsSortedDescending() {
        let sessions = [
            makeSession(status: "working", contextPct: 60),
            makeSession(status: "working", contextPct: 90),
            makeSession(status: "working", contextPct: 75),
        ]
        XCTAssertEqual(StatusCounts(sessions).workingContextPcts, [90, 75, 60])
    }

    func testWorkingContextPctsAtExactThreshold() {
        let sessions = [makeSession(status: "working", contextPct: 50)]
        XCTAssertEqual(StatusCounts(sessions).workingContextPcts, [50])
    }
}
