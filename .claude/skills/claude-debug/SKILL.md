---
name: claude-debug
description: Debug Claude Code session and team management issues. Snapshot ~/.claude state, analyze team agent detection, diagnose session linking problems, and generate detailed debugging reports.
tools: Bash, Read, Write, Glob, Grep
---

# Claude Code Debug Skill

Debug and diagnose Claude Code session management, team detection, and agent linking issues.

## Overview

This skill provides utilities for debugging issues with:
- **Team agent detection** - Agents not showing under team leads
- **Session linking** - parent_session_id not being set properly
- **Active state conflicts** - Multiple sessions appearing instead of grouped teams
- **JSONL parsing** - teamName and agentName field extraction

## Usage

### 1. Create a Frozen Snapshot

```bash
./scripts/debug-snapshot.sh [snapshot-name]
```

**Purpose**: Creates a copy of `~/.claude` that won't be modified by running sessions

**Example**:
```bash
cd ~/.claude/agents/claude-debug
./scripts/debug-snapshot.sh svg-floor-plan-issue-1
# Output: snapshots created in ./tmp/debug-snapshots/
```

**Use when**: You need to analyze the current state without it changing during investigation

### 2. Analyze Team Detection Issues

```bash
./scripts/debug-team-issues.sh [--snapshot /path/to/snapshot]
```

**Purpose**: Scans `~/.claude` (or snapshot) and generates detailed team detection report

**Example**:
```bash
# Analyze current live state
./scripts/debug-team-issues.sh

# Analyze a snapshot
./scripts/debug-team-issues.sh --snapshot ./tmp/debug-snapshots/svg-floor-plan-issue-1

# Output: ./tmp/team-debug-analysis.txt
```

**Report includes**:
- Team configurations and member lists
- Session files and parent relationship status
- JSONL team tagging analysis
- Mismatches between JSONL and session files
- Linking success/failure summary
- Recommendations for fixes

## Common Issues & Solutions

### Issue: Team Agents Appearing as Separate Sessions

**Symptom**:
- Multiple rows in sidebar for same project (team lead + agents)
- No team badge showing "N agents"
- Each session shows separately

**Root cause**: `parent_session_id` not set in agent session JSON files

**Debug steps**:
1. Run `./scripts/debug-team-issues.sh`
2. Look for "Sessions WITHOUT parent_session_id" section
3. Check if agent sessions are listed there
4. Verify they have corresponding JSONL files with `teamName`

**To fix**:
- Check `SessionReader._readSessionsOnIOQueue()` in ClaudeMonitor.swift (line 913)
- Verify `teamAgentSessions` dictionary is populated
- Ensure `TeamReader.leadSessionByTeamName` mapping exists
- Check for race conditions during startup

### Issue: Team Config Exists but Agents Not Recognized

**Symptom**:
- `~/.claude/teams/{name}/config.json` exists
- Agents listed in members array
- But they're not being linked to lead session

**Debug steps**:
1. Run `./scripts/debug-team-issues.sh`
2. Check "Team Configurations" section - does the team appear?
3. Check "JSONL Team Tag Analysis" - do agents have `teamName` field?
4. Look for "Mismatch Analysis" section

**To fix**:
- Verify JSONL files have both `"teamName"` and `"agentName"` fields
- Check if JSONL file modification time is within 2-minute freshness window
- Ensure `readJSONLTail()` is correctly extracting teamName (line 326)

### Issue: Session Project Mismatch

**Symptom**:
- Team agents have different project name than lead
- Sessions won't group together

**Debug steps**:
1. Compare project names in session JSON files
2. Check `cwd` values - are they the same directory?
3. Run aggregation analysis

**To fix**:
- Session grouping relies on matching `(project, cwd)` pairs
- If CWD differs, sessions won't aggregate

## Architecture Overview

### Team Agent Linking Flow

```
1. readJSONLTail()              Extract teamName from JSONL
   ↓
2. scanProjects()               Populate teamAgentSessions dict
   ↓
3. TeamReader.readTeams()       Build leadSessionByTeamName mapping
   ↓
4. readSessions()               Get team leads snapshot
   ↓
5. _readSessionsOnIOQueue()     Set parent_session_id on agents
   ↓
6. UI hides agents, shows under lead
```

### Key Files

- **Main logic**: `Sources/ClaudeMonitorApp/ClaudeMonitor.swift`
  - `readJSONLTail()` (line 291) - Extract teamName
  - `scanProjects()` (line 378) - Populate teamAgentSessions
  - `_readSessionsOnIOQueue()` (line 913) - Link agents to leads
  - `TeamReader.readTeams()` (line 30) - Build mappings

- **Data structures**: `Sources/ClaudeMonitorCore/SessionInfo.swift`
  - `parent_session_id` field - Links agent to lead

- **Team data**: `Sources/ClaudeMonitorCore/TeamModel.swift`
  - `TeamConfig`, `TeamMember`, `TeamInfo`

## References

- [Debug SVG-Floor-Plan Team Issue](references/DEBUG_SVG_FLOOR_PLAN_TEAM.md) - Detailed analysis of the svg-floor-plan case
- [Debug Utilities Guide](references/DEBUG_UTILITIES.md) - Complete documentation
- [Team Model](../../../Sources/ClaudeMonitorCore/TeamModel.swift) - Data structures
- [Session Info](../../../Sources/ClaudeMonitorCore/SessionInfo.swift) - Session metadata

## Adding Logging for Tracing

To debug the linking flow, add NSLog statements:

```swift
// SessionReader.readJSONLTail()
NSLog("[DEBUG] Extracted from JSONL: isSubagent=%d, teamName=%@", isSubagent, teamName ?? "nil")

// SessionReader.scanProjects()
NSLog("[DEBUG] teamAgentSessions populated: %@", newTeamAgents)

// SessionReader._readSessionsOnIOQueue()
NSLog("[DEBUG] Team lead mapping: %@", teamLeadsByName)
NSLog("[DEBUG] Linking %@ (team %@) -> lead %@", sessionId, teamName, leadSid)
```

## Snapshot Structure

When you create a snapshot, it contains:

```
tmp/debug-snapshots/snapshot-name/
├── teams/               # Team configurations
├── monitor/sessions/    # Session metadata (JSON)
├── projects/            # JSONL transcripts
├── tasks/               # Task lists
└── ...
```

Excluded (to keep size reasonable):
- telemetry/
- cache/
- shell-snapshots/
- Large binary logs

## Tips for Debugging

1. **Timeline Analysis**: Check file modification times to understand ordering
2. **Verify Each Step**: Check output at each stage of the linking flow
3. **Compare JSONL vs JSON**: JSONL should have teamName, JSON should have parent_session_id
4. **Race Conditions**: Check if TeamCreate writes config before sessions are scanned
5. **Stale Data**: JSONL must be modified within 2 minutes to be scanned

## See Also

- Claude Code docs: Team agents and session management
- `CLAUDE.md` in this project: Build and test instructions
