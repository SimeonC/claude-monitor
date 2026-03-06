import XCTest
@testable import ClaudeMonitorCore

final class SessionInfoTests: XCTestCase {

    private let fmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func makeSession(
        status: String = "idle",
        updatedAt: Date = Date(),
        startedAt: Date = Date()
    ) -> SessionInfo {
        SessionInfo(
            session_id: "test-\(UUID().uuidString)",
            status: status,
            project: "test",
            cwd: "/test",
            terminal: "",
            terminal_session_id: "",
            started_at: fmt.string(from: startedAt),
            updated_at: fmt.string(from: updatedAt),
            last_prompt: ""
        )
    }

    // MARK: - isStale

    func testIsStaleReturnsFalseForFreshSession() {
        let session = makeSession(updatedAt: Date())
        XCTAssertFalse(session.isStale(at: Date()))
    }

    func testIsStaleReturnsTrueJustOver10Min() {
        let updated = Date(timeIntervalSinceReferenceDate: 0)
        let reference = updated.addingTimeInterval(601)
        let session = makeSession(updatedAt: updated)
        XCTAssertTrue(session.isStale(at: reference))
    }

    func testIsStaleReturnsFalseAtExactly10Min() {
        // Boundary: > 600 means exactly 600s is NOT stale
        let updated = Date(timeIntervalSinceReferenceDate: 0)
        let reference = updated.addingTimeInterval(600)
        let session = makeSession(updatedAt: updated)
        XCTAssertFalse(session.isStale(at: reference))
    }

    func testIsStaleReturnsFalseAt9Min59Sec() {
        let updated = Date(timeIntervalSinceReferenceDate: 0)
        let reference = updated.addingTimeInterval(599)
        let session = makeSession(updatedAt: updated)
        XCTAssertFalse(session.isStale(at: reference))
    }

    // MARK: - elapsedString

    func testElapsedStringUnder60Seconds() {
        let session = makeSession(startedAt: Date().addingTimeInterval(-30))
        let result = session.elapsedString
        XCTAssertTrue(result.hasSuffix("s"), "Expected seconds format, got '\(result)'")
        XCTAssertFalse(result.isEmpty)
    }

    func testElapsedStringUnder1Hour() {
        let session = makeSession(startedAt: Date().addingTimeInterval(-90))
        let result = session.elapsedString
        XCTAssertTrue(result.hasSuffix("m"), "Expected minutes format, got '\(result)'")
    }

    func testElapsedStringOver1Hour() {
        let session = makeSession(startedAt: Date().addingTimeInterval(-3660))
        let result = session.elapsedString
        XCTAssertTrue(result.contains("h"), "Expected hours format, got '\(result)'")
        XCTAssertTrue(result.contains("m"), "Expected hours+minutes format, got '\(result)'")
    }

    func testElapsedStringInvalidDateReturnsEmpty() {
        var session = makeSession()
        session = SessionInfo(
            session_id: session.session_id, status: session.status,
            project: session.project, cwd: session.cwd,
            terminal: "", terminal_session_id: "",
            started_at: "not-a-date", updated_at: session.updated_at,
            last_prompt: ""
        )
        XCTAssertEqual(session.elapsedString, "")
    }

    // MARK: - statusIcon

    func testStatusIcon() {
        XCTAssertEqual(makeSession(status: "starting").statusIcon, "circle.dotted")
        XCTAssertEqual(makeSession(status: "working").statusIcon, "circle.fill")
        XCTAssertEqual(makeSession(status: "idle").statusIcon, "checkmark.circle.fill")
        XCTAssertEqual(makeSession(status: "attention").statusIcon, "exclamationmark.triangle.fill")
        XCTAssertEqual(makeSession(status: "shutting_down").statusIcon, "arrow.down.circle")
        XCTAssertEqual(makeSession(status: "unknown_status").statusIcon, "circle")
    }

    // MARK: - displayStatus

    func testDisplayStatus() {
        XCTAssertEqual(makeSession(status: "starting").displayStatus, "starting")
        XCTAssertEqual(makeSession(status: "working").displayStatus, "working")
        XCTAssertEqual(makeSession(status: "idle").displayStatus, "idle")
        XCTAssertEqual(makeSession(status: "attention").displayStatus, "attention")
        XCTAssertEqual(makeSession(status: "shutting_down").displayStatus, "exiting")
        XCTAssertEqual(makeSession(status: "custom_status").displayStatus, "custom_status")
    }

    // MARK: - skip_permissions decoding

    func testDecodeWithSkipPermissionsTrue() throws {
        let json = """
        {"session_id":"s1","status":"idle","project":"p","cwd":"/p",
         "terminal":"","terminal_session_id":"","started_at":"","updated_at":"",
         "last_prompt":"","agent_count":0,"skip_permissions":true}
        """
        let session = try JSONDecoder().decode(SessionInfo.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(session.skip_permissions, true)
    }

    func testDecodeWithoutSkipPermissions() throws {
        let json = """
        {"session_id":"s2","status":"idle","project":"p","cwd":"/p",
         "terminal":"","terminal_session_id":"","started_at":"","updated_at":"",
         "last_prompt":"","agent_count":0}
        """
        let session = try JSONDecoder().decode(SessionInfo.self, from: json.data(using: .utf8)!)
        XCTAssertNil(session.skip_permissions)
    }
}
