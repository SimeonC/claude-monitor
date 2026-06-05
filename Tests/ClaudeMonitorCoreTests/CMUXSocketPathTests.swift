import XCTest
@testable import ClaudeMonitorCore

final class CMUXSocketPathTests: XCTestCase {
    private let home = "/Users/test"

    func testExplicitPathWins() {
        let p = CMUXSocketPath.resolve(
            explicit: "/custom/cmux.sock",
            env: ["CMUX_SOCKET_PATH": "/Users/test/.local/state/cmux/cmux.sock"],
            home: home,
            fileExists: { _ in true }
        )
        XCTAssertEqual(p, "/custom/cmux.sock")
    }

    func testPrefersEnvSocketPathWhenItExists() {
        let envSock = "/Users/test/.local/state/cmux/cmux.sock"
        let p = CMUXSocketPath.resolve(
            explicit: nil,
            env: ["CMUX_SOCKET_PATH": envSock],
            home: home,
            fileExists: { $0 == envSock }
        )
        XCTAssertEqual(p, envSock)
    }

    func testFallsBackToXDGStateWhenNoEnv() {
        let xdgDefault = "/Users/test/.local/state/cmux/cmux.sock"
        let p = CMUXSocketPath.resolve(
            explicit: nil,
            env: [:],
            home: home,
            fileExists: { $0 == xdgDefault }
        )
        XCTAssertEqual(p, xdgDefault)
    }

    func testRespectsXDGStateHomeEnv() {
        let xdgSock = "/xdg/state/cmux/cmux.sock"
        let p = CMUXSocketPath.resolve(
            explicit: nil,
            env: ["XDG_STATE_HOME": "/xdg/state"],
            home: home,
            fileExists: { $0 == xdgSock }
        )
        XCTAssertEqual(p, xdgSock)
    }

    func testFallsBackToLegacyApplicationSupportWhenOnlyItExists() {
        let legacy = "/Users/test/Library/Application Support/cmux/cmux.sock"
        let p = CMUXSocketPath.resolve(
            explicit: nil,
            env: [:],
            home: home,
            fileExists: { $0 == legacy }
        )
        XCTAssertEqual(p, legacy)
    }

    func testReturnsHighestPriorityCandidateWhenNoneExist() {
        // Env points somewhere not (yet) present — we should still target it so
        // a later cmux launch at that path recovers without restarting the app.
        let envSock = "/Users/test/.local/state/cmux/cmux.sock"
        let p = CMUXSocketPath.resolve(
            explicit: nil,
            env: ["CMUX_SOCKET_PATH": envSock],
            home: home,
            fileExists: { _ in false }
        )
        XCTAssertEqual(p, envSock)
    }

    func testDefaultsToXDGStateWhenNoEnvAndNothingExists() {
        let p = CMUXSocketPath.resolve(
            explicit: nil,
            env: [:],
            home: home,
            fileExists: { _ in false }
        )
        XCTAssertEqual(p, "/Users/test/.local/state/cmux/cmux.sock")
    }
}
