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

    // MARK: - Probe-first selection

    func testProbeSkipsDeadHigherPrioritySocketPicksLiveOne() {
        // CMUX_SOCKET_PATH points to a dead orphan; hint points to the live socket.
        // Without probe the dead orphan would be returned (exists=true, first candidate).
        let dead = "/dead/cmux.sock"
        let live = "/Users/test/.local/state/cmux/cmux-502.sock"
        let p = CMUXSocketPath.resolve(
            explicit: nil,
            env: ["CMUX_SOCKET_PATH": dead],
            home: home,
            fileExists: { _ in true },
            readFile: { path in path.hasSuffix("last-socket-path") ? live + "\n" : nil },
            probe: { path in path == live }
        )
        XCTAssertEqual(p, live)
    }

    // MARK: - Glob discovery

    func testGlobDiscoversCmuxUIDSocketWithNoHint() {
        // No hint file; listDir returns a numbered socket alongside the generic one.
        // The numbered socket probes live; the generic probes dead.
        let dir = "/Users/test/.local/state/cmux"
        let numbered = dir + "/cmux-502.sock"
        let generic = dir + "/cmux.sock"
        let p = CMUXSocketPath.resolve(
            explicit: nil,
            env: [:],
            home: home,
            fileExists: { $0 == numbered || $0 == generic },
            readFile: { _ in nil },
            probe: { path in path == numbered },
            listDir: { d in d == dir ? ["cmux-502.sock", "cmux.sock"] : [] }
        )
        XCTAssertEqual(p, numbered)
    }

    func testHintOutranksGlobbedSiblingWhenBothProbeLive() {
        // Hint and glob both surface live sockets; hint must win (it's higher priority).
        let dir = "/Users/test/.local/state/cmux"
        let hintSock = dir + "/cmux-502.sock"
        let globSock = dir + "/cmux-503.sock"
        let p = CMUXSocketPath.resolve(
            explicit: nil,
            env: [:],
            home: home,
            fileExists: { _ in true },
            readFile: { path in path.hasSuffix("last-socket-path") ? hintSock + "\n" : nil },
            probe: { _ in true },
            listDir: { d in d == dir ? ["cmux-503.sock", "cmux-502.sock", "cmux.sock"] : [] }
        )
        XCTAssertEqual(p, hintSock)
    }

    func testDedupHintEqualsGlobbedPath() {
        // hint == a globbed entry; candidate list must not contain it twice.
        let dir = "/Users/test/.local/state/cmux"
        let sock = dir + "/cmux-502.sock"
        let cands = CMUXSocketPath.candidates(
            env: [:],
            home: home,
            readFile: { path in path.hasSuffix("last-socket-path") ? sock + "\n" : nil },
            listDir: { d in d == dir ? ["cmux-502.sock", "cmux.sock"] : [] }
        )
        let count = cands.filter { $0 == sock }.count
        XCTAssertEqual(count, 1, "duplicate candidate: \(cands)")
    }
}
