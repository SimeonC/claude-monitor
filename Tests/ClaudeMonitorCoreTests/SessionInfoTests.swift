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

    // MARK: - Equatable

    func testEqualSessionsAreEqual() {
        let s1 = SessionInfo(
            session_id: "abc", status: "idle", project: "p", cwd: "/p",
            terminal: "ghostty", terminal_session_id: "tty1",
            started_at: "2024-01-01T00:00:00Z", updated_at: "2024-01-01T01:00:00Z",
            last_prompt: "hello", agent_count: 2
        )
        let s2 = SessionInfo(
            session_id: "abc", status: "idle", project: "p", cwd: "/p",
            terminal: "ghostty", terminal_session_id: "tty1",
            started_at: "2024-01-01T00:00:00Z", updated_at: "2024-01-01T01:00:00Z",
            last_prompt: "hello", agent_count: 2
        )
        XCTAssertEqual(s1, s2)
    }

    func testDifferentStatusNotEqual() {
        let s1 = makeSession(status: "idle")
        var s2 = s1
        s2.status = "working"
        XCTAssertNotEqual(s1, s2)
    }

    func testSessionsArrayEqualityGatePublish() {
        let s = makeSession(status: "idle")
        let a1: [SessionInfo] = [s]
        let a2: [SessionInfo] = [s]
        XCTAssertEqual(a1, a2)
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

    // MARK: - permission_mode decoding

    func testDecodeWithPermissionModePlan() throws {
        let json = """
        {"session_id":"s3","status":"idle","project":"p","cwd":"/p",
         "terminal":"","terminal_session_id":"","started_at":"","updated_at":"",
         "last_prompt":"","agent_count":0,"permission_mode":"plan"}
        """
        let session = try JSONDecoder().decode(SessionInfo.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(session.permission_mode, "plan")
    }

    func testDecodeWithoutPermissionModeIsNil() throws {
        let json = """
        {"session_id":"s4","status":"idle","project":"p","cwd":"/p",
         "terminal":"","terminal_session_id":"","started_at":"","updated_at":"",
         "last_prompt":"","agent_count":0}
        """
        let session = try JSONDecoder().decode(SessionInfo.self, from: json.data(using: .utf8)!)
        XCTAssertNil(session.permission_mode)
    }

    // MARK: - modeIcon

    func testModeIconForKnownModes() {
        var s = makeSession()
        s.permission_mode = "plan"
        XCTAssertEqual(s.modeIcon, "pause.fill")
        s.permission_mode = "acceptEdits"
        XCTAssertEqual(s.modeIcon, "play.fill")
        s.permission_mode = "bypassPermissions"
        XCTAssertEqual(s.modeIcon, "forward.fill")
    }

    func testModeIconCircleForDefaultAndNil() {
        var s = makeSession()
        s.permission_mode = "default"
        XCTAssertEqual(s.modeIcon, "circle.fill")
        s.permission_mode = nil
        XCTAssertEqual(s.modeIcon, "circle.fill")
    }

    // MARK: - modeLabel

    func testModeLabelForKnownModes() {
        var s = makeSession()
        s.permission_mode = "plan"
        XCTAssertEqual(s.modeLabel, "Plan mode")
        s.permission_mode = "acceptEdits"
        XCTAssertEqual(s.modeLabel, "Accept edits")
        s.permission_mode = "bypassPermissions"
        XCTAssertEqual(s.modeLabel, "Bypass permissions")
    }

    func testModeLabelNilForDefaultAndNil() {
        var s = makeSession()
        s.permission_mode = "default"
        XCTAssertNil(s.modeLabel)
        s.permission_mode = nil
        XCTAssertNil(s.modeLabel)
    }
}
