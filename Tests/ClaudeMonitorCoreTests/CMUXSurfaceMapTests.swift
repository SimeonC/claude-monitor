import XCTest
@testable import ClaudeMonitorCore

final class CMUXSurfaceMapTests: XCTestCase {

    private func makeSurface(id: String, checkpoint: String?) -> [String: Any] {
        var s: [String: Any] = ["surface_id": id]
        if let ckpt = checkpoint {
            s["resume_binding"] = ["checkpoint_id": ckpt]
        }
        return s
    }

    private func makeSurfaceListResult(_ surfaces: [[String: Any]]) -> [String: Any] {
        ["surfaces": surfaces]
    }

    // MARK: - Basic construction

    func testEmptyInputsProduceEmptyMap() {
        let map = CMUXSurfaceMap(workspacesResult: [:], surfacesByWorkspace: [])
        XCTAssertTrue(map.byCheckpoint.isEmpty)
        XCTAssertTrue(map.checkpointBySurfaceId.isEmpty)
    }

    func testSingleWorkspaceSingleSurface() {
        let result = makeSurfaceListResult([makeSurface(id: "SF1", checkpoint: "claude-100")])
        let map = CMUXSurfaceMap(workspacesResult: [:], surfacesByWorkspace: [("WS1", result)])
        XCTAssertEqual(map.byCheckpoint["claude-100"]?.surfaceId, "SF1")
        XCTAssertEqual(map.byCheckpoint["claude-100"]?.workspaceId, "WS1")
        XCTAssertEqual(map.byCheckpoint["claude-100"]?.checkpoint, "claude-100")
        XCTAssertEqual(map.checkpointBySurfaceId["SF1"], "claude-100")
    }

    func testTwoWorkspacesTwoSurfaces() {
        let r1 = makeSurfaceListResult([makeSurface(id: "SF1", checkpoint: "claude-100")])
        let r2 = makeSurfaceListResult([makeSurface(id: "SF2", checkpoint: "claude-200")])
        let map = CMUXSurfaceMap(workspacesResult: [:], surfacesByWorkspace: [("WS1", r1), ("WS2", r2)])
        XCTAssertEqual(map.byCheckpoint["claude-100"]?.surfaceId, "SF1")
        XCTAssertEqual(map.byCheckpoint["claude-100"]?.workspaceId, "WS1")
        XCTAssertEqual(map.byCheckpoint["claude-200"]?.surfaceId, "SF2")
        XCTAssertEqual(map.byCheckpoint["claude-200"]?.workspaceId, "WS2")
        XCTAssertEqual(map.checkpointBySurfaceId["SF1"], "claude-100")
        XCTAssertEqual(map.checkpointBySurfaceId["SF2"], "claude-200")
    }

    func testMultipleSurfacesInSameWorkspace() {
        let result = makeSurfaceListResult([
            makeSurface(id: "SF1", checkpoint: "claude-100"),
            makeSurface(id: "SF2", checkpoint: "claude-101"),
        ])
        let map = CMUXSurfaceMap(workspacesResult: [:], surfacesByWorkspace: [("WS1", result)])
        XCTAssertEqual(map.byCheckpoint["claude-100"]?.workspaceId, "WS1")
        XCTAssertEqual(map.byCheckpoint["claude-101"]?.workspaceId, "WS1")
        XCTAssertEqual(map.checkpointBySurfaceId["SF1"], "claude-100")
        XCTAssertEqual(map.checkpointBySurfaceId["SF2"], "claude-101")
    }

    // MARK: - Defensive: skip bad entries

    func testSkipSurfaceWithNullResumeBinding() {
        let surface: [String: Any] = ["surface_id": "SF_BAD"]  // no resume_binding
        let result = makeSurfaceListResult([surface])
        let map = CMUXSurfaceMap(workspacesResult: [:], surfacesByWorkspace: [("WS1", result)])
        XCTAssertTrue(map.byCheckpoint.isEmpty)
        XCTAssertTrue(map.checkpointBySurfaceId.isEmpty)
    }

    func testSkipSurfaceWithEmptyCheckpoint() {
        let surface: [String: Any] = ["surface_id": "SF_BAD", "resume_binding": ["checkpoint_id": ""]]
        let result = makeSurfaceListResult([surface])
        let map = CMUXSurfaceMap(workspacesResult: [:], surfacesByWorkspace: [("WS1", result)])
        XCTAssertTrue(map.byCheckpoint.isEmpty)
    }

    func testSkipSurfaceWithMissingSurfaceId() {
        let surface: [String: Any] = ["resume_binding": ["checkpoint_id": "claude-100"]]
        let result = makeSurfaceListResult([surface])
        let map = CMUXSurfaceMap(workspacesResult: [:], surfacesByWorkspace: [("WS1", result)])
        XCTAssertTrue(map.byCheckpoint.isEmpty)
    }

    func testSkipEmptyWorkspaceId() {
        let result = makeSurfaceListResult([makeSurface(id: "SF1", checkpoint: "claude-100")])
        let map = CMUXSurfaceMap(workspacesResult: [:], surfacesByWorkspace: [("", result)])
        XCTAssertTrue(map.byCheckpoint.isEmpty)
    }

    func testMalformedSurfacesKeyIgnored() {
        // surfaceListResult with wrong type for "surfaces"
        let result: [String: Any] = ["surfaces": "not-an-array"]
        let map = CMUXSurfaceMap(workspacesResult: [:], surfacesByWorkspace: [("WS1", result)])
        XCTAssertTrue(map.byCheckpoint.isEmpty)
    }

    func testValidSurfacesMixedWithBadOnesSkipsBad() {
        let result = makeSurfaceListResult([
            makeSurface(id: "SF_GOOD", checkpoint: "claude-999"),
            ["surface_id": "SF_BAD"],  // no resume_binding
        ])
        let map = CMUXSurfaceMap(workspacesResult: [:], surfacesByWorkspace: [("WS1", result)])
        XCTAssertEqual(map.byCheckpoint.count, 1)
        XCTAssertNotNil(map.byCheckpoint["claude-999"])
    }

    // MARK: - Reverse lookup

    func testReverseCheckpointLookup() {
        let result = makeSurfaceListResult([makeSurface(id: "SF1", checkpoint: "claude-100")])
        let map = CMUXSurfaceMap(workspacesResult: [:], surfacesByWorkspace: [("WS1", result)])
        XCTAssertEqual(map.checkpointBySurfaceId["SF1"], "claude-100")
        XCTAssertNil(map.checkpointBySurfaceId["UNKNOWN"])
    }

    func testUnknownCheckpointReturnsNil() {
        let map = CMUXSurfaceMap(workspacesResult: [:], surfacesByWorkspace: [])
        XCTAssertNil(map.byCheckpoint["claude-999"])
    }
}
