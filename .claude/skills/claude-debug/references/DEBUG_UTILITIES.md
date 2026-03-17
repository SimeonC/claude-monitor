# Claude Code Manager - Debug Utilities

> **Note**: These utilities are now bundled as a Claude Code skill at `~/.claude/agents/claude-debug/`. See [Skill Usage](#skill-usage) below.

This directory includes utilities for debugging Claude Code session and team management issues.

## Skill Usage

These debugging tools are available as a Claude Code skill:

```bash
# Navigate to the skill
cd ~/.claude/agents/claude-debug/

# Create a snapshot of current ~/.claude state
./scripts/debug-snapshot.sh [snapshot-name]

# Analyze team detection issues
./scripts/debug-team-issues.sh [--snapshot /path/to/snapshot]
```

See `~/.claude/agents/claude-debug/SKILL.md` for full documentation.

## Files

### 1. `DEBUG_SVG_FLOOR_PLAN_TEAM.md`
A comprehensive analysis of the current svg-floor-plan team agent detection issue.

**Read this first** to understand:
- What the problem is (agents not linking to team lead)
- Why it's happening (missing `parent_session_id` in session files)
- What should work (the intended data flow)
- Root cause hypothesis and verification steps

### 2. `debug-snapshot.sh`
Creates a frozen snapshot of `~/.claude` for offline analysis.

**Purpose**: When debugging issues with active sessions, the live data keeps changing. This script creates a copy of `~/.claude` that won't be modified by running sessions.

**Usage**:
```bash
# Create a snapshot with auto-generated name
./debug-snapshot.sh

# Create a snapshot with custom name
./debug-snapshot.sh my-debug-session

# Snapshots are stored in: ./tmp/debug-snapshots/
```

**What it excludes** (to keep size manageable):
- Large binary caches
- Telemetry data
- Backups
- Shell snapshots
- Log files

**Key directories in snapshot**:
- `teams/` - Team configurations
- `monitor/sessions/` - Session metadata (.json files)
- `projects/` - JSONL transcripts and project data
- `tasks/` - Task lists

### 3. `debug-team-issues.sh`
Analyzes team and agent detection problems.

**Purpose**: Automatically scans the current `~/.claude` (or a snapshot) and generates a detailed report about:
- Team configurations and member lists
- Session files and their parent relationships
- JSONL tagging of team agents
- Mismatches between what JSONL says and what session files show
- Recommendations for fixing issues

**Usage**:
```bash
# Analyze live ~/.claude
./debug-team-issues.sh

# Analyze a snapshot
./debug-team-issues.sh --snapshot ./tmp/debug-snapshots/my-debug-session

# Output is saved to: ./tmp/team-debug-analysis.txt
```

**Output sections**:
1. **Team Configurations** - List all teams and their lead session IDs
2. **Session Files Analysis** - Which sessions have parent_session_id set
3. **JSONL Team Tag Analysis** - Which JSONL files have teamName fields
4. **Team-Agent Linking Status** - Summary of linking success/failure
5. **Recommendations** - What to check if issues are found

## Workflow for Debugging Team Issues

### Step 1: Snapshot Current State
```bash
./debug-snapshot.sh issue-debug-1
```

### Step 2: Generate Analysis Report
```bash
./debug-team-issues.sh --snapshot ./tmp/debug-snapshots/issue-debug-1
```

This produces `./tmp/team-debug-analysis.txt` with the full breakdown.

### Step 3: Review the Report
Look for "⚠️ ISSUE" sections and "Check:" recommendations.

### Step 4: Add Debugging to Code
Based on findings, add logging to:
- `SessionReader.readJSONLTail()` - verify teamName extraction
- `SessionReader.scanProjects()` - verify teamAgentSessions population
- `SessionReader._readSessionsOnIOQueue()` - verify team lead lookup and parent_session_id assignment
- `TeamReader.readTeams()` - verify leadSessionByTeamName mapping

## Key Data Files for Investigation

**In the snapshot**, examine:

### Team Configuration
```
teams/decoration-phase0/config.json
```
Verify `leadSessionId` matches the actual lead session ID.

### Session Files
```
monitor/sessions/44e5ca5b-a0e3-4cab-922f-3ceee6058f6e.json  (lead)
monitor/sessions/caa72758-5a42-4968-995f-b6dac69e749e.json   (agent 1)
monitor/sessions/e6e8a507-8edd-4163-ba1c-2a5a0ca0b273.json   (agent 2)
```

Check:
- Lead session should NOT have `parent_session_id`
- Agent sessions SHOULD have `parent_session_id` pointing to lead

### JSONL Files
```
projects/-workspaces-svg-floor-plan/44e5ca5b-*.jsonl  (lead)
projects/-workspaces-svg-floor-plan/caa72758-*.jsonl   (agent 1)
projects/-workspaces-svg-floor-plan/e6e8a507-*.jsonl   (agent 2)
```

Check the last 10-20 lines for:
- `"teamName":"decoration-phase0"`
- `"agentName":"crud-agent"` (or other agent name) for agents

## Common Issues and Quick Fixes

### Issue: Agents not showing under team lead

**Symptom**: Multiple session rows for same project, no team badge visible

**Check**: Do agent sessions have `parent_session_id` set to lead session ID?

```bash
grep parent_session_id ./tmp/debug-snapshots/*/monitor/sessions/*.json
```

If empty or missing, the linking didn't happen.

### Issue: Team config exists but agents not recognized

**Check**: Do the JSONL files have both `teamName` AND `agentName`?

```bash
tail -20 projects/*/*.jsonl | grep -E '"teamName"|"agentName"'
```

If only `teamName` without `agentName`, the session won't be recognized as an agent.

### Issue: Multiple teams showing up as separate sessions

**Check**: Are the session files from different teams being merged?

Look at `monitor/sessions/*.json` to see which have the same `project` and `cwd` values.

## Adding Logging for Debugging

To trace the team linking flow, add NSLog statements to:

```swift
// In SessionReader.readJSONLTail()
NSLog("[DEBUG] Extracted from JSONL: isSubagent=%d, teamName=%@", isSubagent, teamName ?? "nil")

// In SessionReader.scanProjects()
NSLog("[DEBUG] teamAgentSessions populated with %zu entries", newTeamAgents.count)

// In SessionReader._readSessionsOnIOQueue()
NSLog("[DEBUG] teamLeadsByName snapshot: %@", teamLeadsByName)
NSLog("[DEBUG] sessionId %@ -> teamName %@ -> leadSid %@", sessionId, teamName, leadSid)
```

Then rebuild and run to see the data flow in real time.

## Related Code

- `Sources/ClaudeMonitorApp/ClaudeMonitor.swift` - Main session/team logic
  - Line 291: `readJSONLTail()` - extracts teamName
  - Line 378: `scanProjects()` - populates teamAgentSessions
  - Line 785: `readSessions()` - calls with team leads snapshot
  - Line 913: `_readSessionsOnIOQueue()` - performs linking

- `Sources/ClaudeMonitorCore/Aggregation.swift` - Session grouping logic
- `Sources/ClaudeMonitorCore/SessionInfo.swift` - SessionInfo struct with parent_session_id field
- `Sources/ClaudeMonitorCore/TeamModel.swift` - Team data structures
