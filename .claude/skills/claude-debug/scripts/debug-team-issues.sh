#!/bin/bash
# Debug Team Detection Issues
# Analyzes team agent detection and session linking problems
# Usage: ./debug-team-issues.sh [--snapshot /path/to/snapshot]

set -e

# Use snapshot if provided, otherwise use live ~/.claude
SNAPSHOT_PATH="${2:-$HOME/.claude}"

OUTPUT_FILE="./tmp/team-debug-analysis.txt"
mkdir -p ./tmp

{
    echo "Team Detection Debug Analysis"
    echo "=============================="
    echo "Generated: $(date)"
    echo "Source: $SNAPSHOT_PATH"
    echo ""

    # Check team configurations
    echo "## 1. TEAM CONFIGURATIONS"
    echo "========================="
    if [ -d "$SNAPSHOT_PATH/teams" ]; then
        for team_dir in "$SNAPSHOT_PATH/teams"/*; do
            if [ -d "$team_dir" ]; then
                team_name=$(basename "$team_dir")
                echo ""
                echo "Team: $team_name"
                if [ -f "$team_dir/config.json" ]; then
                    echo "  Config exists: ✓"
                    lead_session=$(grep -o '"leadSessionId":"[^"]*' "$team_dir/config.json" | cut -d'"' -f4 || echo "NOT FOUND")
                    echo "  Lead session ID: $lead_session"
                    member_count=$(grep -o '"name":"[^"]*"' "$team_dir/config.json" | wc -l)
                    echo "  Member count: $member_count"
                else
                    echo "  Config missing: ✗"
                fi
            fi
        done
    else
        echo "No teams directory found"
    fi

    echo ""
    echo ""
    echo "## 2. SESSION FILES ANALYSIS"
    echo "============================"
    if [ -d "$SNAPSHOT_PATH/monitor/sessions" ]; then
        echo ""
        echo "Total session files: $(ls -1 "$SNAPSHOT_PATH/monitor/sessions"/*.json 2>/dev/null | wc -l)"

        echo ""
        echo "Sessions with parent_session_id:"
        grep -l '"parent_session_id"' "$SNAPSHOT_PATH/monitor/sessions"/*.json 2>/dev/null | \
            while read f; do
                sid=$(basename "$f" .json)
                parent=$(grep -o '"parent_session_id":"[^"]*' "$f" | cut -d'"' -f4)
                echo "  $sid -> $parent"
            done || echo "  (none found)"

        echo ""
        echo "Sessions WITHOUT parent_session_id:"
        grep -L '"parent_session_id"' "$SNAPSHOT_PATH/monitor/sessions"/*.json 2>/dev/null | \
            while read f; do
                sid=$(basename "$f" .json)
                project=$(grep -o '"project":"[^"]*' "$f" | cut -d'"' -f4)
                agent_count=$(grep -o '"agent_count":[0-9]*' "$f" | cut -d':' -f2)
                echo "  $sid (project: $project, agents: $agent_count)"
            done || echo "  (all have parent_session_id)"
    else
        echo "No monitor/sessions directory found"
    fi

    echo ""
    echo ""
    echo "## 3. JSONL TEAM TAG ANALYSIS"
    echo "=============================="
    echo ""
    echo "Sessions with teamName in JSONL:"
    if [ -d "$SNAPSHOT_PATH/projects" ]; then
        find "$SNAPSHOT_PATH/projects" -maxdepth 2 -name "*.jsonl" -type f | \
            while read f; do
                # Check tail of file for teamName
                if tail -20 "$f" 2>/dev/null | grep -q '"teamName"'; then
                    sid=$(basename "$f" .jsonl)
                    team=$(tail -20 "$f" 2>/dev/null | grep '"teamName"' | tail -1 | grep -o '"teamName":"[^"]*' | cut -d'"' -f4)
                    agent=$(tail -20 "$f" 2>/dev/null | grep '"agentName"' | tail -1 | grep -o '"agentName":"[^"]*' | cut -d'"' -f4)
                    is_agent="$([ -n "$agent" ] && echo "yes ($agent)" || echo "no (lead)")"
                    echo "  $sid -> team: $team, agent: $is_agent"
                fi
            done
        echo ""
        echo "Mismatch Analysis:"
        echo "  Sessions tagged with teamName in JSONL but missing parent_session_id in JSON:"

        find "$SNAPSHOT_PATH/projects" -maxdepth 2 -name "*.jsonl" -type f | \
            while read jsonl; do
                sid=$(basename "$jsonl" .jsonl)
                session_file="$SNAPSHOT_PATH/monitor/sessions/$sid.json"

                # Check if JSONL has teamName
                if tail -20 "$jsonl" 2>/dev/null | grep -q '"teamName"'; then
                    # Check if session JSON has parent_session_id
                    if [ -f "$session_file" ]; then
                        if ! grep -q '"parent_session_id"' "$session_file"; then
                            team=$(tail -20 "$jsonl" 2>/dev/null | grep '"teamName"' | tail -1 | grep -o '"teamName":"[^"]*' | cut -d'"' -f4)
                            echo "    ⚠️  $sid (team: $team)"
                        fi
                    fi
                fi
            done
    else
        echo "No projects directory found"
    fi

    echo ""
    echo ""
    echo "## 4. TEAM-AGENT LINKING STATUS"
    echo "================================"
    echo ""
    echo "Expected linking summary:"
    teams_found=0
    agents_found=0
    correctly_linked=0

    if [ -d "$SNAPSHOT_PATH/teams" ]; then
        for team_dir in "$SNAPSHOT_PATH/teams"/*; do
            if [ -d "$team_dir" ] && [ -f "$team_dir/config.json" ]; then
                teams_found=$((teams_found + 1))
                team_name=$(basename "$team_dir")
                lead_session=$(grep -o '"leadSessionId":"[^"]*' "$team_dir/config.json" | cut -d'"' -f4 || echo "")
                member_names=$(grep -o '"name":"[^"]*"' "$team_dir/config.json" | cut -d'"' -f4 | grep -v team-lead | tr '\n' ',' | sed 's/,$//') || true

                echo "  Team '$team_name':"
                echo "    Lead: $lead_session"
                echo "    Members: $member_names"

                # Check if agents have parent_session_id pointing to lead
                if [ -d "$SNAPSHOT_PATH/monitor/sessions" ]; then
                    agent_count=0
                    linked_count=0
                    for f in "$SNAPSHOT_PATH/monitor/sessions"/*.json; do
                        if [ -f "$f" ]; then
                            parent=$(grep -o '"parent_session_id":"[^"]*' "$f" 2>/dev/null | cut -d'"' -f4 || echo "")
                            if [ "$parent" = "$lead_session" ]; then
                                agent_count=$((agent_count + 1))
                                linked_count=$((linked_count + 1))
                                correctly_linked=$((correctly_linked + 1))
                            fi
                        fi
                    done
                    agents_found=$((agents_found + agent_count))
                    echo "    Agents found: $agent_count, Correctly linked: $linked_count"
                fi
            fi
        done
    fi

    echo ""
    echo "Summary: $teams_found teams, $agents_found agents, $correctly_linked correctly linked"

    echo ""
    echo ""
    echo "## 5. RECOMMENDATIONS"
    echo "===================="
    echo ""
    if [ "$correctly_linked" -eq 0 ] && [ "$teams_found" -gt 0 ]; then
        echo "⚠️  ISSUE: Teams found but agents not linked to team leads"
        echo ""
        echo "Check:"
        echo "  1. TeamReader.readTeams() - verify leadSessionByTeamName is populated"
        echo "  2. SessionReader.teamAgentSessions - verify agent sessions are tracked"
        echo "  3. SessionReader._readSessionsOnIOQueue() - verify team linking code executes"
        echo "  4. Timing - ensure TeamCreate completes before sessions are loaded"
    elif [ "$teams_found" -eq 0 ]; then
        echo "✓ No teams configured - team detection not applicable"
    else
        echo "✓ Teams and agents correctly linked"
    fi

} | tee "$OUTPUT_FILE"

echo ""
echo "📝 Analysis saved to: $OUTPUT_FILE"
