import XCTest
@testable import ClaudeMonitorCore

final class PhantomSessionFilterTests: XCTestCase {

    // MARK: - isPhantomSession

    func testPhantomDetectedWhenNoJSONLAndOldFile() {
        // No JSONL + >60s old → phantom, should be deleted
        XCTAssertTrue(isPhantomSession(jsonlExists: false, mtimeAge: 61))
    }

    func testPhantomNotDetectedWhenJSONLExists() {
        // Real session with JSONL → keep regardless of age
        XCTAssertFalse(isPhantomSession(jsonlExists: true, mtimeAge: 300))
    }

    func testPhantomNotDetectedWithinGracePeriod() {
        // No JSONL but fresh file (≤60s) → keep during grace period
        XCTAssertFalse(isPhantomSession(jsonlExists: false, mtimeAge: 59))
    }

    func testPhantomNotDetectedAtExactly60Seconds() {
        // Boundary: exactly 60s is NOT old enough (> 60, not ≥)
        XCTAssertFalse(isPhantomSession(jsonlExists: false, mtimeAge: 60))
    }

    func testPhantomDetectedWhenNoJSONLAndVeryOldFile() {
        // Very old phantom (hours/days) → should delete
        XCTAssertTrue(isPhantomSession(jsonlExists: false, mtimeAge: 3600))
    }

    // MARK: - isStaleTmpSidecar

    func testStaleTmpDetectedWhenNoMatchingJsonAndOldFile() {
        // No .json + >1 day old → stale tmp, should delete
        XCTAssertTrue(isStaleTmpSidecar(hasMatchingJson: false, mtimeAge: 86401))
    }

    func testStaleTmpNotDetectedWhenMatchingJsonExists() {
        // .json exists → mid-write, leave alone
        XCTAssertFalse(isStaleTmpSidecar(hasMatchingJson: true, mtimeAge: 200000))
    }

    func testStaleTmpNotDetectedWhenFresh() {
        // No .json but tmp is fresh → keep
        XCTAssertFalse(isStaleTmpSidecar(hasMatchingJson: false, mtimeAge: 3600))
    }

    func testStaleTmpNotDetectedAtExactly1Day() {
        // Boundary: exactly 1 day is NOT old enough (> 86400, not ≥)
        XCTAssertFalse(isStaleTmpSidecar(hasMatchingJson: false, mtimeAge: 86400))
    }

    // MARK: - isPhantomHeartbeat

    func testHeartbeatNotPhantomWhenFresh() {
        // T3Code session with recent heartbeat (<30min) → keep
        XCTAssertFalse(isPhantomHeartbeat(mtimeAge: 1799))
    }

    func testHeartbeatPhantomWhenStale() {
        // T3Code session with stale heartbeat (>30min) → phantom
        XCTAssertTrue(isPhantomHeartbeat(mtimeAge: 1801))
    }

    func testHeartbeatNotPhantomAtExactBoundary() {
        // Boundary: exactly 1800s is NOT phantom (> 1800, not ≥)
        XCTAssertFalse(isPhantomHeartbeat(mtimeAge: 1800))
    }
}
