import XCTest
@testable import ClaudeMonitorCore

final class CMUXSessionRelinkTests: XCTestCase {
    private func decode(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    func testSetsSurfaceAndWorkspace() {
        let input = #"{"session_id":"abc","cmux_surface_id":"OLD","cmux_workspace_id":"OLDW"}"#.data(using: .utf8)!
        let out = CMUXSessionRelink.apply(jsonData: input, surfaceId: "NEWSURF", workspaceId: "NEWWS", checkpoint: nil)
        let obj = decode(out!)
        XCTAssertEqual(obj["cmux_surface_id"] as? String, "NEWSURF")
        XCTAssertEqual(obj["cmux_workspace_id"] as? String, "NEWWS")
    }

    func testPreservesUnrelatedKeys() {
        let input = #"{"session_id":"abc","cmux_surface_id":"OLD","agent_count":3,"skip_permissions":true,"status":"working"}"#.data(using: .utf8)!
        let out = CMUXSessionRelink.apply(jsonData: input, surfaceId: "NEW", workspaceId: nil, checkpoint: nil)
        let obj = decode(out!)
        XCTAssertEqual(obj["session_id"] as? String, "abc")
        XCTAssertEqual(obj["agent_count"] as? Int, 3)
        XCTAssertEqual(obj["skip_permissions"] as? Bool, true)
        XCTAssertEqual(obj["status"] as? String, "working")
        XCTAssertEqual(obj["cmux_surface_id"] as? String, "NEW")
    }

    func testNilWorkspaceLeavesExistingWorkspaceUntouched() {
        let input = #"{"cmux_surface_id":"OLD","cmux_workspace_id":"KEEP"}"#.data(using: .utf8)!
        let out = CMUXSessionRelink.apply(jsonData: input, surfaceId: "NEW", workspaceId: nil, checkpoint: nil)
        let obj = decode(out!)
        XCTAssertEqual(obj["cmux_surface_id"] as? String, "NEW")
        XCTAssertEqual(obj["cmux_workspace_id"] as? String, "KEEP")
    }

    func testEmptyWorkspaceLeavesExistingUntouched() {
        let input = #"{"cmux_surface_id":"OLD","cmux_workspace_id":"KEEP"}"#.data(using: .utf8)!
        let out = CMUXSessionRelink.apply(jsonData: input, surfaceId: "NEW", workspaceId: "", checkpoint: nil)
        let obj = decode(out!)
        XCTAssertEqual(obj["cmux_workspace_id"] as? String, "KEEP")
    }

    func testAddsSurfaceWhenAbsent() {
        let input = #"{"session_id":"abc"}"#.data(using: .utf8)!
        let out = CMUXSessionRelink.apply(jsonData: input, surfaceId: "NEW", workspaceId: "WS", checkpoint: nil)
        let obj = decode(out!)
        XCTAssertEqual(obj["cmux_surface_id"] as? String, "NEW")
        XCTAssertEqual(obj["cmux_workspace_id"] as? String, "WS")
    }

    func testReturnsNilOnInvalidJSON() {
        let input = "not json".data(using: .utf8)!
        XCTAssertNil(CMUXSessionRelink.apply(jsonData: input, surfaceId: "NEW", workspaceId: "WS", checkpoint: nil))
    }

    // MARK: - checkpoint

    func testSetsCheckpointWhenProvided() {
        let input = #"{"session_id":"abc"}"#.data(using: .utf8)!
        let out = CMUXSessionRelink.apply(jsonData: input, surfaceId: "SF", workspaceId: "WS", checkpoint: "claude-36676")
        let obj = decode(out!)
        XCTAssertEqual(obj["cmux_checkpoint"] as? String, "claude-36676")
    }

    func testNilCheckpointLeavesExistingUntouched() {
        let input = #"{"cmux_checkpoint":"claude-OLD"}"#.data(using: .utf8)!
        let out = CMUXSessionRelink.apply(jsonData: input, surfaceId: "SF", workspaceId: nil, checkpoint: nil)
        let obj = decode(out!)
        XCTAssertEqual(obj["cmux_checkpoint"] as? String, "claude-OLD")
    }

    func testEmptyCheckpointLeavesExistingUntouched() {
        let input = #"{"cmux_checkpoint":"claude-OLD"}"#.data(using: .utf8)!
        let out = CMUXSessionRelink.apply(jsonData: input, surfaceId: "SF", workspaceId: nil, checkpoint: "")
        let obj = decode(out!)
        XCTAssertEqual(obj["cmux_checkpoint"] as? String, "claude-OLD")
    }
}
