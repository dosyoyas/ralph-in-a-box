#!/bin/bash

# Shell script to run an AI agent (claude, cursor, or codex) in headless mode with beads task tracking
# Each iteration = ONE phase of a feature pipeline, then exit to reset context

CHECK_INTERVAL=5

# Agent selection (claude, cursor, or codex)
RALPH_AGENT="${RALPH_AGENT:-claude}"

# Configuration (can be overridden via environment)
AGENT_CONFIG_DIR="${AGENT_CONFIG_DIR:-$HOME/.claude}"
DO_TASK_FILE="${DO_TASK_FILE:-DO_TASK_PYTHON.md}"
BOOTSTRAP_FILE="${BOOTSTRAP_FILE:-/opt/ralph/BOOTSTRAP.md}"
VERIFY_FILE="${VERIFY_FILE:-/opt/ralph/VERIFY.md}"

# Safety limits (can be overridden via environment)
MAX_ITERATIONS="${MAX_ITERATIONS:-50}"
MAX_COST="${MAX_COST:-100.00}"

# Use shared log directory and project name (set by ralph-in-a-box.sh) or fallback
LOG_DIR="${RALPH_LOG_DIR:-/tmp}"
PROJECT_NAME="${RALPH_PROJECT_NAME:-$(basename "$(pwd)")}"
AGENT_PREFIX="${RALPH_AGENT}"
LOG_FILE="${LOG_DIR}/${AGENT_PREFIX}_live_${PROJECT_NAME}.log"
COST_FILE="${LOG_DIR}/${AGENT_PREFIX}_cost_${PROJECT_NAME}.txt"
ITERATION_FILE="${LOG_DIR}/${AGENT_PREFIX}_iteration_${PROJECT_NAME}.txt"
TOTAL_COST=0
ITERATION=0

# Remove stale Dolt lock on exit so the next run starts clean.
# Handles: docker stop (SIGTERM), Ctrl+C (SIGINT), and normal exit.
# Note: SIGKILL cannot be trapped — startup cleanup below covers that case.
cleanup() {
    rm -f .beads/dolt-access.lock 2>/dev/null
}
trap cleanup EXIT SIGTERM SIGINT

# Parse stream-json: full output to log file, summaries to console
parse_stream() {
    while IFS= read -r line; do
        echo "$line" >>"$LOG_FILE"

        TYPE=$(echo "$line" | jq -r '.type // empty' 2>/dev/null)
        case "$TYPE" in
        assistant)
            MSG=$(echo "$line" | jq -r '.message.content[]? | select(.type=="tool_use") | "\(.name): \(.input | tostring | .[0:80])..."' 2>/dev/null)
            [ -n "$MSG" ] && echo "[TOOL] $MSG"
            TEXT=$(echo "$line" | jq -r '.message.content[]? | select(.type=="text") | .text' 2>/dev/null)
            [ -n "$TEXT" ] && echo "$TEXT"
            ;;
        tool_call)
            # Cursor Agent — dedicated tool_call events
            SUBTYPE=$(echo "$line" | jq -r '.subtype // empty' 2>/dev/null)
            if [ "$SUBTYPE" = "started" ]; then
                TOOL_NAME=$(echo "$line" | jq -r '.tool_call | keys[0] // empty' 2>/dev/null)
                [ -n "$TOOL_NAME" ] && echo "[TOOL] $TOOL_NAME"
            fi
            ;;
        result)
            # Cost tracking — Claude only
            if [ "$RALPH_AGENT" = "claude" ]; then
                COST=$(echo "$line" | jq -r '.total_cost_usd // 0' 2>/dev/null)
                if [ -n "$COST" ] && [ "$COST" != "null" ] && [ "$COST" != "0" ]; then
                    TOTAL_COST=$(echo "scale=6; $TOTAL_COST + $COST" | bc 2>/dev/null || echo "$TOTAL_COST")
                    printf "[COST] This run: \$%.2f | Total: \$%.2f\n" "$COST" "$TOTAL_COST"
                    echo "$TOTAL_COST" >"$COST_FILE"
                fi
            fi
            ;;
        content_block_delta)
            TEXT=$(echo "$line" | jq -r '.delta.text // empty' 2>/dev/null)
            [ -n "$TEXT" ] && echo "$TEXT"
            ;;
        esac
    done
}

# Invoke the selected agent with a prompt file
invoke_agent() {
    local prompt_file="$1"
    case "$RALPH_AGENT" in
    claude)
        claude -p "$(cat "$prompt_file")" \
            --add-dir "$AGENT_CONFIG_DIR" \
            --dangerously-skip-permissions \
            --output-format stream-json \
            --verbose \
            2>&1 | parse_stream
        ;;
    cursor)
        agent -p "$(cat "$prompt_file")" \
            --force \
            --output-format stream-json \
            --stream-partial-output \
            2>&1 | parse_stream
        ;;
    codex)
        codex exec "$(cat "$prompt_file")" \
            --dangerously-bypass-approvals-and-sandbox \
            --json \
            2>&1 | parse_stream
        ;;
    esac
}

# Initialize log files (monitoring is handled by host via ralph-in-a-box.sh)
mkdir -p "$LOG_DIR"
>"$LOG_FILE"
echo "0" >"$COST_FILE"
echo "0" >"$ITERATION_FILE"
echo "Agent: $RALPH_AGENT"
echo "Logs: $LOG_FILE"
if [ "$RALPH_AGENT" = "claude" ]; then
    echo "Limits: MAX_ITERATIONS=$MAX_ITERATIONS, MAX_COST=\$$MAX_COST"
else
    echo "Limits: MAX_ITERATIONS=$MAX_ITERATIONS"
fi
echo "Starting $RALPH_AGENT automation loop with beads..."

while true; do
    # Load accumulated cost and iteration count
    [ -f "$COST_FILE" ] && TOTAL_COST=$(cat "$COST_FILE" 2>/dev/null || echo "0")
    [ -f "$ITERATION_FILE" ] && ITERATION=$(cat "$ITERATION_FILE" 2>/dev/null || echo "0")

    # Increment iteration counter
    ITERATION=$((ITERATION + 1))
    echo "$ITERATION" >"$ITERATION_FILE"

    # Check iteration limit
    if [ "$ITERATION" -gt "$MAX_ITERATIONS" ]; then
        echo ""
        echo "════════════════════════════════════════"
        echo "⚠️  MAX_ITERATIONS ($MAX_ITERATIONS) REACHED"
        echo "════════════════════════════════════════"
        printf "Completed %d iterations. Total cost: \$%.2f\n" $((ITERATION - 1)) "$TOTAL_COST"
        echo ""
        echo "Remaining tasks:"
        bd list
        exit 3
    fi

    # Check cost limit (Claude only — other agents don't report cost)
    if [ "$RALPH_AGENT" = "claude" ]; then
        if (( $(echo "$TOTAL_COST > $MAX_COST" | bc -l 2>/dev/null || echo 0) )); then
            echo ""
            echo "════════════════════════════════════════"
            echo "⚠️  MAX_COST (\$$MAX_COST) EXCEEDED"
            echo "════════════════════════════════════════"
            printf "Total cost: \$%.2f. Completed %d iterations.\n" "$TOTAL_COST" "$ITERATION"
            echo ""
            echo "Remaining tasks:"
            bd list
            exit 4
        fi
    fi

    echo ""
    echo "═══════════════════════════════════════════════════════════"
    if [ "$RALPH_AGENT" = "claude" ]; then
        printf "ITERATION %d/%d | Cost: \$%.2f/\$%.2f | Agent: %s\n" "$ITERATION" "$MAX_ITERATIONS" "$TOTAL_COST" "$MAX_COST" "$RALPH_AGENT"
    else
        printf "ITERATION %d/%d | Agent: %s\n" "$ITERATION" "$MAX_ITERATIONS" "$RALPH_AGENT"
    fi
    echo "═══════════════════════════════════════════════════════════"

    # Task detection: get counts (fallback to empty if beads not initialized)
    TASK_JSON=$(bd list --json 2>/dev/null || echo "[]")
    TOTAL=$(echo "$TASK_JSON" | jq 'length')
    OPEN=$(echo "$TASK_JSON" | jq '[.[] | select(.status != "closed")] | length')
    READY=$(bd ready --json 2>/dev/null | jq 'length' 2>/dev/null || echo "0")

    if [ "$TOTAL" = "0" ] || [ -z "$TOTAL" ]; then
        # bd list --json only returns open tasks; if .beads exists, all tasks are closed
        if [ -d ".beads" ]; then
            OPEN="0"
        elif [ -f "ACTION_PLAN.md" ]; then
            echo ""
            echo "════════════════════════════════════════"
            echo "🚀 BOOTSTRAP — Creating tasks from ACTION_PLAN.md"
            echo "════════════════════════════════════════"

            rm -f .beads/dolt-access.lock 2>/dev/null
            >"$LOG_FILE"
            echo "=== Bootstrap $(date) ===" >>"$LOG_FILE"

            invoke_agent "$BOOTSTRAP_FILE"

            AGENT_EXIT_CODE=$?
            if [ $AGENT_EXIT_CODE -ne 0 ]; then
                echo ""
                echo "════════════════════════════════════════"
                echo "❌ BOOTSTRAP ERROR (exit code: $AGENT_EXIT_CODE)"
                echo "════════════════════════════════════════"
                exit $AGENT_EXIT_CODE
            fi

            sleep $CHECK_INTERVAL
            continue
        else
            echo ""
            echo "════════════════════════════════════════"
            echo "❌ NO TASKS AND NO ACTION_PLAN.md"
            echo "════════════════════════════════════════"
            echo "Create tasks with 'bd create' or provide an ACTION_PLAN.md file."
            exit 1
        fi
    fi

    if [ "$OPEN" = "0" ] || [ -z "$OPEN" ]; then
        echo ""
        echo "════════════════════════════════════════"
        echo "✅ ALL TASKS COMPLETED - LANDING THE PLANE"
        echo "════════════════════════════════════════"
        bd list --status closed | head -20

        # Verification: compare ACTION_PLAN.md against completed tasks (informational only)
        if [ -f "ACTION_PLAN.md" ] && [ -f "$VERIFY_FILE" ]; then
            echo ""
            echo "════════════════════════════════════════"
            echo "📋 VERIFYING PLAN COVERAGE"
            echo "════════════════════════════════════════"

            rm -f .beads/dolt-access.lock 2>/dev/null
            >"$LOG_FILE"
            echo "=== Verify $(date) ===" >>"$LOG_FILE"

            invoke_agent "$VERIFY_FILE"

            echo ""
        fi

        echo "Landing workflow:"
        if git remote | grep -q .; then
            echo "1. Syncing with git..."
            git pull --rebase
            echo "2. Pushing commits to remote..."
            git push
        else
            echo "No git remote configured — skipping push"
        fi
        echo "Verifying status..."
        git status
        echo ""
        echo "════════════════════════════════════════"
        echo "✅ WORK SESSION COMPLETE"
        echo "════════════════════════════════════════"
        printf "Iterations: %d | Total cost: \$%.2f\n" "$ITERATION" "$TOTAL_COST"
        exit 0
    fi

    if [ "$READY" = "0" ]; then
        echo ""
        echo "════════════════════════════════════════"
        echo "⚠️  BLOCKED - Manual intervention required"
        echo "════════════════════════════════════════"
        echo ""
        bd list
        echo ""
        echo "Use 'bd show <id>' for details on each task."
        exit 2
    fi

    echo "Tasks: $READY ready, $OPEN total open"
    echo "---"

    # Remove stale Dolt lock from any previously aborted run
    rm -f .beads/dolt-access.lock 2>/dev/null

    >"$LOG_FILE"
    echo "=== Starting task $(date) ===" >>"$LOG_FILE"

    invoke_agent "$DO_TASK_FILE"

    AGENT_EXIT_CODE=$?

    echo "---"

    if [ $AGENT_EXIT_CODE -ne 0 ]; then
        echo ""
        echo "════════════════════════════════════════"
        echo "❌ AGENT ERROR (exit code: $AGENT_EXIT_CODE)"
        echo "════════════════════════════════════════"
        echo ""
        bd list
        exit $AGENT_EXIT_CODE
    fi

    sleep $CHECK_INTERVAL
done
