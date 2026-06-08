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

    // MARK: - last-socket-path hint

    func testPrefersLastSocketPathOverGenericCmuxSock() {
        // Scenario: cmux.sock exists on disk (stale, ECONNREFUSED) but last-socket-path
        // points to the live numbered socket cmux-502.sock. The app must prefer the hint.
        let liveSocket = "/Users/test/.local/state/cmux/cmux-502.sock"
        let deadSocket = "/Users/test/.local/state/cmux/cmux.sock"
        let p = CMUXSocketPath.resolve(
            explicit: nil,
            env: [:],
            home: home,
            fileExists: { $0 == liveSocket || $0 == deadSocket },
            readFile: { path in path.hasSuffix("last-socket-path") ? liveSocket + "\n" : nil }
        )
        XCTAssertEqual(p, liveSocket)
    }

    func testLastSocketPathTrimsWhitespace() {
        let liveSocket = "/Users/test/.local/state/cmux/cmux-502.sock"
        let p = CMUXSocketPath.resolve(
            explicit: nil,
            env: [:],
            home: home,
            fileExists: { $0 == liveSocket },
            readFile: { path in path.hasSuffix("last-socket-path") ? "  \(liveSocket)\n  " : nil }
        )
        XCTAssertEqual(p, liveSocket)
    }

    func testFallsBackToGenericCmuxSockWhenLastSocketPathMissing() {
        let genericSock = "/Users/test/.local/state/cmux/cmux.sock"
        let p = CMUXSocketPath.resolve(
            explicit: nil,
            env: [:],
            home: home,
            fileExists: { $0 == genericSock },
            readFile: { _ in nil }
        )
        XCTAssertEqual(p, genericSock)
    }

    func testXdgStateHomeLastSocketPathUsedBeforeDefaultXdg() {
        let xdgLive = "/custom/xdg/cmux/cmux-999.sock"
        let p = CMUXSocketPath.resolve(
            explicit: nil,
            env: ["XDG_STATE_HOME": "/custom/xdg"],
            home: home,
            fileExists: { $0 == xdgLive },
            readFile: { path in path.hasSuffix("last-socket-path") ? xdgLive + "\n" : nil }
        )
        XCTAssertEqual(p, xdgLive)
    }

    func testExplicitPathStillWinsOverLastSocketPath() {
        let explicit = "/explicit/cmux.sock"
        let liveSocket = "/Users/test/.local/state/cmux/cmux-502.sock"
        let p = CMUXSocketPath.resolve(
            explicit: explicit,
            env: [:],
            home: home,
            fileExists: { _ in true },
            readFile: { _ in liveSocket }
        )
        XCTAssertEqual(p, explicit)
    }

    func testEnvSocketPathStillWinsOverLastSocketPath() {
        let envSock = "/env/cmux.sock"
        let liveSocket = "/Users/test/.local/state/cmux/cmux-502.sock"
        let p = CMUXSocketPath.resolve(
            explicit: nil,
            env: ["CMUX_SOCKET_PATH": envSock],
            home: home,
            fileExists: { _ in true },
            readFile: { _ in liveSocket }
        )
        XCTAssertEqual(p, envSock)
    }
}
