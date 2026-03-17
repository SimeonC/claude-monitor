# Claude Debug Skill - Quick Start

## Problem: Team Agents Showing as Separate Sessions

If your team agents appear as individual rows in the sidebar instead of being grouped under the team lead, use this skill to diagnose the issue.

## Quick Diagnosis (2 minutes)

```bash
cd ~/.claude/agents/claude-debug
./scripts/debug-team-issues.sh | tail -30
```

Look for the "⚠️ ISSUE" section in the output.

## Full Diagnosis (5 minutes)

```bash
# 1. Create a snapshot
./scripts/debug-snapshot.sh my-issue

# 2. Analyze it
./scripts/debug-team-issues.sh --snapshot ./tmp/debug-snapshots/my-issue > ./tmp/report.txt

# 3. Review the report
cat ./tmp/report.txt | grep -A 10 "RECOMMENDATIONS"
```

## What Each Section Tells You

### ✓ Teams and agents correctly linked
Everything is working. No action needed.

### ⚠️ Sessions WITHOUT parent_session_id
Agent sessions are missing the `parent_session_id` field that links them to their team lead.

**Fix**: Check the team agent linking code in `SessionReader._readSessionsOnIOQueue()` (line 913 of ClaudeMonitor.swift)

### ⚠️ ISSUE: Teams found but agents not linked
Team config exists but agents aren't being detected.

**Check**:
1. Are JSONL files modified within the last 2 minutes?
2. Do JSONL files have both `"teamName"` AND `"agentName"` fields?
3. Is `readJSONLTail()` correctly extracting teamName?

## Common Fixes

### Session files outside 2-minute window
JSONL files are only scanned if modified within 2 minutes. Touched JSONL files will be re-scanned:
```bash
touch ~/.claude/projects/*/{lead_session_id}.jsonl
```

### TeamReader reference not initialized
Make sure `AppDelegate.applicationDidFinishLaunching()` sets:
```swift
reader.teamReader = teamReader  // Line 2373 in ClaudeMonitor.swift
```

### Race condition on startup
Ensure team config exists before scanning projects. Check ordering in app startup.

## Files Explained

- **debug-snapshot.sh** - Freezes current state for analysis
- **debug-team-issues.sh** - Analyzes team detection
- **references/DEBUG_SVG_FLOOR_PLAN_TEAM.md** - Detailed case study
- **references/DEBUG_UTILITIES.md** - Full documentation

## Still Having Issues?

1. Check the detailed analysis in `DEBUG_SVG_FLOOR_PLAN_TEAM.md`
2. Add logging to the source code as described in that document
3. Review the "Verification Steps" section for each potential cause
