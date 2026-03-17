# Debug Report: SVG-Floor-Plan Team Agent Detection

**Date**: 2026-03-17
**Issue**: svg-floor-plan team agents are showing as multiple separate sessions instead of being grouped under a team lead session.

## Summary

The svg-floor-plan sessions are correctly tagged with the `decoration-phase0` team in their JSONL files, but the `parent_session_id` field is **not being set** in the session JSON files, causing them to appear as independent sessions in the sidebar instead of being hidden under their team lead.

## Root Cause Analysis

### Team Configuration Status ✓
- Team config exists: `~/.claude/teams/decoration-phase0/config.json`
- Team name: `"decoration-phase0"`
- Lead session ID: `"44e5ca5b-a0e3-4cab-922f-3ceee6058f6e"` ✓ (correct)
- Team members include: `crud-agent` and `resize-agent`

### JSONL Tagging Status ✓
The agent sessions are correctly tagged in their JSONL files:

**Session 1 (Lead)**
- File: `~/.claude/projects/-workspaces-svg-floor-plan/44e5ca5b-a0e3-4cab-922f-3ceee6058f6e.jsonl`
- JSONL entry: `"teamName":"decoration-phase0"`
- No `agentName` field (correctly identifies as lead)
- Status: ✓ Correct

**Session 2 (CRUD Agent)**
- File: `~/.claude/projects/-workspaces-svg-floor-plan/caa72758-5a42-4968-995f-b6dac69e749e.jsonl`
- JSONL entry: `"teamName":"decoration-phase0","agentName":"crud-agent"`
- Status: ✓ Correct

**Session 3 (Resize Agent)**
- File: `~/.claude/projects/-workspaces-svg-floor-plan/e6e8a507-8edd-4163-ba1c-2a5a0ca0b273.jsonl`
- JSONL entry: `"teamName":"decoration-phase0","agentName":"resize-agent"`
- Status: ✓ Correct

### Session JSON Files Status ✗ **PROBLEM**

The issue is in the session JSON files in `~/.claude/monitor/sessions/`:

**Session 44e5ca5b-a0e3-4cab-922f-3ceee6058f6e.json** (Lead)
```json
{
  "session_id": "44e5ca5b-a0e3-4cab-922f-3ceee6058f6e",
  "status": "working",
  "project": "svg-floor-plan",
  "cwd": "/workspaces/svg-floor-plan",
  "terminal": "ghostty",
  "agent_count": 0,
  // ✓ No parent_session_id (correct - this is the lead)
}
```

**Session caa72758-5a42-4968-995f-b6dac69e749e.json** (CRUD Agent)
```json
{
  "session_id": "caa72758-5a42-4968-995f-b6dac69e749e",
  "status": "idle",
  "project": "svg-floor-plan",
  "cwd": "/workspaces/svg-floor-plan",
  // ✗ MISSING: "parent_session_id": "44e5ca5b-a0e3-4cab-922f-3ceee6058f6e"
}
```

**Session e6e8a507-8edd-4163-ba1c-2a5a0ca0b273.json** (Resize Agent)
```json
{
  "session_id": "e6e8a507-8edd-4163-ba1c-2a5a0ca0b273",
  "status": "idle",
  "project": "svg-floor-plan",
  "cwd": "/workspaces/svg-floor-plan",
  // ✗ MISSING: "parent_session_id": "44e5ca5b-a0e3-4cab-922f-3ceee6058f6e"
}
```

## Data Flow Analysis

The intended flow (from commit 1317554) is:

1. **JSONL Scanning** (`SessionReader.scanProjects()`)
   - Reads JSONL tails from project directories
   - Extracts `teamName` field from JSONL entries with `agentName`
   - Populates `SessionReader.teamAgentSessions` dictionary: `sessionId → teamName`
   - Status: ✓ Should work correctly based on code

2. **Team Configuration Loading** (`TeamReader.readTeams()`)
   - Reads `.claude/teams/{name}/config.json` files
   - Builds `leadSessionByTeamName` mapping: `teamName → leadSessionId`
   - Status: ✓ Data is correct (verified team config file)

3. **Session ID Linking** (`SessionReader._readSessionsOnIOQueue()`)
   - Takes `teamLeadsByName` snapshot from TeamReader
   - For each loaded session, checks if `sessionId` exists in `teamAgentSessions`
   - If found, looks up lead session ID via `teamLeadsByName[teamName]`
   - **Should set**: `loaded[i].parent_session_id = leadSessionId`
   - Status: ✗ **This is not happening**

## Potential Issues

### 1. Timing/Race Condition
The code flow shows:
```swift
func readSessions() {
    let teamLeads = teamReader?.leadSessionByTeamName ?? [:]  // Snapshot at call time
    ioQueue.async { [weak self] in
        self?._readSessionsOnIOQueue(teamLeadsByName: teamLeads)
    }
}
```

**Problem**: If `TeamReader.readTeams()` hasn't completed yet when `readSessions()` is called, the `teamLeads` snapshot will be empty or outdated.

**Evidence**: The sessions are created immediately with `/TeamsCreate`, but `~/.claude/teams/decoration-phase0/` might not exist yet or the `leadSessionByTeamName` mapping hasn't been populated.

### 2. Stale JSONL Entries Not Persisting Across Scans
From commit 45c21c7, the fix carries forward team agent entries:
```swift
var newTeamAgents: [String: String] = [:]
// Carry forward known team agents...
for (sid, teamName) in self.teamAgentSessions {
    if fm.fileExists(atPath: "\(self.sessionsDir)/\(sid).json"),
       !self.endedSessionIds.contains(sid) {
        newTeamAgents[sid] = teamName
    }
}
```

**Potential Issue**: If the JSONL file is outside the 2-minute freshness window AND the session JSON still exists, the agent is carried forward. But there's a gap between when sessions are created (with fresh JSONL) and when the next scan happens.

### 3. SessionReader Not Wired to TeamReader
In the code (ClaudeMonitor.swift):
```swift
weak var teamReader: TeamReader?
```

The SessionReader has a reference to TeamReader, but it needs to be properly initialized for the data flow to work:
```swift
func applicationDidFinishLaunching(...) {
    reader.teamReader = teamReader  // This line sets the reference
}
```

**Verify**: Check if `AppDelegate.applicationDidFinishLaunching()` is properly setting `reader.teamReader = teamReader` on the SessionReader instance.

## Key Files Involved

1. **Source**: `Sources/ClaudeMonitorApp/ClaudeMonitor.swift`
   - `SessionReader.readJSONLTail()` - Line ~291: Extracts `teamName` from JSONL
   - `SessionReader.scanProjects()` - Line ~378: Populates `teamAgentSessions`
   - `SessionReader.readSessions()` - Line ~783: Calls with team leads snapshot
   - `SessionReader._readSessionsOnIOQueue()` - Line ~793: **Sets `parent_session_id`**
   - `TeamReader.readTeams()` - Line ~30: Builds `leadSessionByTeamName`
   - `AppDelegate.applicationDidFinishLaunching()` - Line ~2365: Wires TeamReader reference

2. **Data**:
   - Team config: `~/.claude/teams/decoration-phase0/config.json`
   - JSONL files: `~/.claude/projects/-workspaces-svg-floor-plan/*.jsonl`
   - Session files: `~/.claude/monitor/sessions/*.json`

## Debug Steps to Verify

To confirm the issue:

1. **Check if `teamAgentSessions` is populated**
   - Add logging in `readJSONLTail()` to verify `teamName` extraction
   - Add logging in `scanProjects()` to verify dictionary population

2. **Check if `leadSessionByTeamName` is populated**
   - Add logging in `TeamReader.readTeams()` to verify the mapping
   - Verify `teamReader` reference is not nil in SessionReader

3. **Check if team leads are passed correctly**
   - Add logging in `readSessions()` to show the snapshot value
   - Add logging in `_readSessionsOnIOQueue()` to show team agent linking

4. **Check timing of `TeamCreate`**
   - Verify team config is written before or concurrently with agent session creation
   - Check if `TeamReader.readTeams()` is called after `TeamCreate` completes

## Expected Behavior vs. Current Behavior

**Expected**:
- Lead session (44e5ca5b...) appears in sidebar with name "decoration-phase0"
- Agent sessions (caa72758..., e6e8a507...) are hidden from sidebar
- Agent sessions appear under lead session's team badge showing "2 active agents"

**Actual**:
- All three sessions appear separately in sidebar
- No team grouping is visible
- Each session has `project: "svg-floor-plan"` and same `cwd`

## Timeline Analysis

**Timestamps**:
- Team config created: Mar 17 15:08
- JSONL files created: Mar 17 15:08 (crud-agent, resize-agent)
- JSONL files modified: Mar 17 15:11 (lead session still active)

The team and agents were created at nearly the same time, suggesting they were created together via TeamCreate. However, the fact that `parent_session_id` isn't being set suggests a different issue.

## Root Cause Hypothesis

**Most Likely**: The `teamAgentSessions` dictionary is being **cleared or not populated** when sessions are scanned.

**Evidence**:
1. JSONL files clearly have `"teamName":"decoration-phase0"` and `"agentName":"crud-agent"` / `"agentName":"resize-agent"`
2. `readJSONLTail()` correctly extracts these fields (code at line 326-328)
3. `scanProjects()` correctly populates `newTeamAgents` (code at line 410-413)
4. BUT: When `_readSessionsOnIOQueue()` checks `self.teamAgentSessions` (line 915), it appears to be empty or not contain these session IDs

**Possible Causes**:
1. **JSONL file not being scanned**: The file modification time check (line 403) might be filtering them out if mtime is stale
2. **isSubagent detection failing**: If the JSONL doesn't have `"agentName"` field, `isSubagent` will be false and the entry won't be added to `newTeamAgents`
3. **Timing**: If `scanProjects()` hasn't run since the agents were created, the dictionary will be empty

## Verification Steps

The JSONL files should contain lines like:
```json
{"agentName":"crud-agent","teamName":"decoration-phase0",...}
```

To verify this is actually in the JSONL, check the **tail** of the agent session JSONL files for the presence of both `agentName` AND `teamName` in the same JSON object. If `agentName` is missing, that's the root cause.

## Recommendation

The most likely issue is a **missing or stale `agentName` field in the JSONL** or a **timing issue where `teamAgentSessions` isn't populated before session linking occurs**.

Add defensive logging at these critical points:
1. In `readJSONLTail()`: Log extracted `isSubagent` and `teamName` values
2. In `scanProjects()`: Log when `newTeamAgents` is populated with entries
3. In `_readSessionsOnIOQueue()`: Log the contents of `self.teamAgentSessions` and `teamLeadsByName` before the linking loop

Also ensure:
- `AppDelegate.applicationDidFinishLaunching()` sets `reader.teamReader = teamReader` before any session reads
- `TeamReader.readTeams()` completes before sessions are aggregated
- `scanProjects()` runs and completes before `readSessions()` relies on its output
