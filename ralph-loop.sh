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
AGENT_TIMEOUT="${AGENT_TIMEOUT:-600}"  # Kill agent after N seconds of no output (default: 10min)
# Halt after this many consecutive iterations that exit 0 but make no real
# progress (no working-tree change, no task closed). Guards against a model
# that claims a task and then no-ops the turn (e.g. a malformed tool call),
# which would otherwise strand the claim and silently block all dependents.
MAX_NO_PROGRESS="${MAX_NO_PROGRESS:-2}"

# Use shared log directory and project name (set by ralph-in-a-box.sh) or fallback
LOG_DIR="${RALPH_LOG_DIR:-/tmp}"
PROJECT_NAME="${RALPH_PROJECT_NAME:-$(basename "$(pwd)")}"
AGENT_PREFIX="${RALPH_AGENT}"
LOG_FILE="${LOG_DIR}/${AGENT_PREFIX}_live_${PROJECT_NAME}.log"
COST_FILE="${LOG_DIR}/${AGENT_PREFIX}_cost_${PROJECT_NAME}.txt"
ITERATION_FILE="${LOG_DIR}/${AGENT_PREFIX}_iteration_${PROJECT_NAME}.txt"
# Persists the count of consecutive no-progress iterations across the loop's
# context resets (each iteration is a fresh agent invocation).
NO_PROGRESS_FILE="${LOG_DIR}/${AGENT_PREFIX}_noprogress_${PROJECT_NAME}.txt"
TOTAL_COST=0
ITERATION=0

# Remove stale Dolt lock on exit so the next run starts clean.
# Handles: docker stop (SIGTERM), Ctrl+C (SIGINT), and normal exit.
# Note: SIGKILL cannot be trapped — startup cleanup below covers that case.
cleanup() {
    rm -f .beads/dolt-access.lock 2>/dev/null
    rm -f "$USAGE_LIMIT_FILE" 2>/dev/null
    rm -f "$ENV_ERROR_FILE" 2>/dev/null
    rm -f "$MALFORMED_TOOLCALL_FILE" 2>/dev/null
    rm -f "$LAST_TOOL_ERROR_FILE" 2>/dev/null
}
trap cleanup EXIT SIGTERM SIGINT

# Timestamp file for watchdog (tracks last output from agent)
HEARTBEAT_FILE=$(mktemp /tmp/ralph-heartbeat-XXXXXX)

# Flag file: set by parse_stream when the agent reports an account usage/quota
# limit (e.g. Cursor "You've reached your normal usage limit"). The agent keeps
# emitting this every iteration without a non-zero exit, so the loop must detect
# it from the stream and halt — re-running only burns more attempts.
USAGE_LIMIT_FILE=$(mktemp /tmp/ralph-usagelimit-XXXXXX)

# Flag file: set by parse_stream when the agent emits the RALPH_ENV_ERROR
# sentinel. The agent runs as `claude -p` (headless) and CANNOT control its own
# process exit code — it always exits 0 on completion. So "exit non-zero on
# environment errors" is impossible for the agent to honour directly. Instead
# the agent prints the sentinel and the loop detects it here, halting so the
# user fixes the environment instead of re-running an identical failure every
# iteration (e.g. AWS token expired, Docker OOM, missing tool).
ENV_ERROR_FILE=$(mktemp /tmp/ralph-enverror-XXXXXX)

# Flag file: set by parse_stream when an assistant text block contains the
# tell-tale fragments of a malformed tool call (raw "<parameter ...>",
# "<function ...>", "<tool_use ...>" markup, or the corrupt "=**message**="
# pattern emitted by some quantized local builds). When a model serializes a
# tool call as plain text, the harness never executes it: the turn ends
# "successfully" (exit 0) having done nothing, which silently strands the
# claimed task. The loop uses this only as an advisory signal feeding the
# no-progress guard — it never halts on it directly.
MALFORMED_TOOLCALL_FILE=$(mktemp /tmp/ralph-malformed-XXXXXX)

# Flag file: holds the text of the most recent failing tool_result this
# iteration. A tool error (e.g. a beads/Dolt schema fault, a missing module) is
# usually what triggers an env-error bail-out, so the banner shows it as the
# likely trigger even when the model's own explanation is thin.
LAST_TOOL_ERROR_FILE=$(mktemp /tmp/ralph-toolerr-XXXXXX)

# Parse stream-json: full output to log file, summaries to console
parse_stream() {
    while IFS= read -r line; do
        echo "$line" >>"$LOG_FILE"
        date +%s >"$HEARTBEAT_FILE"

        # Detect account usage/quota exhaustion in the raw stream (any agent).
        # These messages are not tied to a non-zero exit code, so flag them here.
        case "$line" in
        *"reached your normal usage limit"* | *"out of usage"* | *"increase your limit to continue"* | *"usage limit"*)
            echo "LIMIT" >"$USAGE_LIMIT_FILE"
            ;;
        esac

        # Detect the agent's environment-error sentinel. The agent cannot set
        # its own exit code in headless mode, so it prints this marker and the
        # loop halts in invoke_agent.
        #
        # Two false-positive sources, both excluded:
        #   1. Prompt echo — some agents replay the prompt as a "type":"user"
        #      event, and the prompt documents the token.
        #   2. The model *citing* the token while reasoning about it (e.g.
        #      gemma4's thinking: "print the exact token `RALPH_ENV_ERROR` on
        #      its own line"). Reasoning lives in "thinking" blocks and quotes
        #      the token inline (backticks, mid-sentence).
        # So: skip user/thinking lines entirely, and otherwise require the token
        # to appear as an isolated JSON string value or alone on its own line
        # ("\n…\n"), which is how a genuine emission ("on its own line") arrives
        # in an assistant text block — not as a substring of prose.
        case "$line" in
        *'"type":"user"'* | *'"role":"user"'* | *'"type":"thinking"'* | *'"thinking":"'*) ;;
        *'"RALPH_ENV_ERROR"'* | *'"RALPH_ENV_ERROR\n'* | *'\nRALPH_ENV_ERROR"'* | *'\nRALPH_ENV_ERROR\n'* | *'"RALPH_ENV_ERROR: '* | *'\nRALPH_ENV_ERROR: '*)
            # Capture the reason the model gave (the "RALPH_ENV_ERROR: <reason>"
            # line, or the whole accompanying text block) so the banner can show
            # *why* it gave up instead of a bare token.
            local reason
            reason=$(echo "$line" | jq -r '.message.content[]? | select(.type=="text") | .text' 2>/dev/null \
                | grep -m1 "RALPH_ENV_ERROR" | sed 's/.*RALPH_ENV_ERROR:* *//' )
            echo "${reason:-(model gave no reason)}" >"$ENV_ERROR_FILE"
            ;;
        esac

        TYPE=$(echo "$line" | jq -r '.type // empty' 2>/dev/null)
        case "$TYPE" in
        user)
            # Surface failing tool results on the console (they are otherwise
            # invisible — only [TOOL] calls and assistant text are shown). A
            # tool error is almost always what triggers an env-error bail-out,
            # so showing it live is what lets the user see *why*. Also stash the
            # most recent one for the env-error banner.
            ERR=$(echo "$line" | jq -r '.message.content[]? | select(.type=="tool_result" and .is_error==true) | (.content | if type=="array" then (map(.text//"") | join(" ")) else tostring end)' 2>/dev/null)
            if [ -n "$ERR" ] && [ "$ERR" != "null" ]; then
                echo "[TOOL-ERROR] $(echo "$ERR" | head -c 400)"
                echo "$ERR" >"$LAST_TOOL_ERROR_FILE"
            fi
            ;;
        assistant)
            MSG=$(echo "$line" | jq -r '.message.content[]? | select(.type=="tool_use") | "\(.name): \(.input | tostring | .[0:80])..."' 2>/dev/null)
            [ -n "$MSG" ] && echo "[TOOL] $MSG"
            TEXT=$(echo "$line" | jq -r '.message.content[]? | select(.type=="text") | .text' 2>/dev/null)
            [ -n "$TEXT" ] && echo "$TEXT"
            # Detect a tool call that the model serialized as plain text instead
            # of a structured tool_use (seen with some quantized local GGUF
            # builds, e.g. "<parameter*=**message**=*>"). The harness can't
            # execute it, so the turn does nothing yet still exits 0. Flag it as
            # an advisory signal for the no-progress guard.
            case "$TEXT" in
            *"<parameter"* | *"<function"*"="* | *"<tool_use"* | *"=**message**="* | *"<｜tool▁call"*)
                echo "[WARN] malformed tool-call markup in assistant text — likely a tool call emitted as plain text (no-op turn)"
                echo "MALFORMED" >"$MALFORMED_TOOLCALL_FILE"
                ;;
            esac
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
            [ -n "$TEXT" ] && printf '%s' "$TEXT"
            ;;
        content_block_stop)
            echo ""
            ;;
        esac
    done
}

# Recursively kill a process and all its descendants. The agent runs as a
# subshell whose child is the CLI (e.g. `claude`), which may itself spawn
# grandchildren; killing only direct children leaves grandchildren reparented
# and alive. Walks the tree bottom-up via `pgrep -P` (portable across the Linux
# container and macOS). $2 is the signal (default TERM).
kill_tree() {
    local pid=$1
    local sig="${2:-TERM}"
    local child
    for child in $(pgrep -P "$pid" 2>/dev/null); do
        kill_tree "$child" "$sig"
    done
    kill "-$sig" "$pid" 2>/dev/null
}

# Watchdog: kills the agent (and its descendants) if no output for
# AGENT_TIMEOUT seconds, then releases the stream reader so invoke_agent
# can return.
#
# Takes BOTH pids because they are different processes: agent_pid is the agent
# itself (e.g. `claude -p`), reader_pid is the parse_stream loop consuming its
# output. The agent is what hangs (e.g. blocked on an unresponsive Ollama
# before emitting a single token), so it is what must be killed — killing only
# the reader would leave the agent running and the container alive forever.
# pkill -P also reaps the agent's children (the real model/HTTP call lives in a
# child of the subshell).
start_watchdog() {
    local agent_pid=$1
    local reader_pid=$2
    while kill -0 "$agent_pid" 2>/dev/null; do
        sleep 30
        local last_beat=$(cat "$HEARTBEAT_FILE" 2>/dev/null || echo "0")
        local now=$(date +%s)
        local silent=$(( now - last_beat ))
        if [ "$silent" -ge "$AGENT_TIMEOUT" ]; then
            echo ""
            echo "⚠️  WATCHDOG: Agent silent for ${silent}s (timeout: ${AGENT_TIMEOUT}s) — killing"
            kill_tree "$agent_pid" TERM
            sleep 2
            kill_tree "$agent_pid" KILL
            # Close the read side so the pipeline unblocks and invoke_agent returns.
            kill "$reader_pid" 2>/dev/null
            break
        fi
    done
}

# Invoke the selected agent with a prompt file
# Agent runs in background; watchdog kills it if no output for AGENT_TIMEOUT seconds.
# Exit code is captured from the agent process (not parse_stream).
invoke_agent() {
    local prompt_file="$1"
    local rc_file=$(mktemp /tmp/ralph-rc-XXXXXX)
    date +%s >"$HEARTBEAT_FILE"
    # Clear any usage-limit / env-error / malformed-tool-call flag from a
    # previous invocation.
    : >"$USAGE_LIMIT_FILE"
    : >"$ENV_ERROR_FILE"
    : >"$MALFORMED_TOOLCALL_FILE"
    : >"$LAST_TOOL_ERROR_FILE"

    # Run the agent and the stream parser as SEPARATE processes connected by a
    # FIFO — not a shell pipeline. A pipeline (`agent | parse_stream &`) only
    # exposes the reader's pid via $!, leaving no handle on the agent itself, so
    # the watchdog could only ever kill the reader and the hung agent would
    # survive. With an explicit FIFO we capture the agent's real pid and can
    # kill it (and its children) when it stalls.
    local fifo
    fifo=$(mktemp -u /tmp/ralph-fifo-XXXXXX)
    mkfifo "$fifo"

    parse_stream <"$fifo" &
    local reader_pid=$!

    (
        case "$RALPH_AGENT" in
        ollama)
            claude -p "$(cat "$prompt_file")" \
                --add-dir "$AGENT_CONFIG_DIR" \
                --dangerously-skip-permissions \
                --output-format stream-json \
                --verbose \
                --model "${RALPH_OLLAMA_MODEL:-qwen2.5-coder:14b}"
            ;;
        claude)
            claude -p "$(cat "$prompt_file")" \
                --add-dir "$AGENT_CONFIG_DIR" \
                --dangerously-skip-permissions \
                --output-format stream-json \
                --verbose
            ;;
        cursor)
            agent -p "$(cat "$prompt_file")" \
                --force \
                --output-format stream-json \
                --stream-partial-output
            ;;
        codex)
            codex exec "$(cat "$prompt_file")" \
                --dangerously-bypass-approvals-and-sandbox \
                --json
            ;;
        esac
        echo $? >"$rc_file"
    ) >"$fifo" 2>&1 &
    local agent_pid=$!

    # Watchdog runs in the background (NOT in a command substitution, so its
    # messages reach the log and it isn't killed by a closing $() pipe). It
    # watches the agent and releases the reader if it has to kill a stalled one.
    start_watchdog "$agent_pid" "$reader_pid" &
    local watchdog_pid=$!

    # Wait for the agent to finish (or be killed by the watchdog), then let the
    # reader drain the FIFO before tearing the watchdog down.
    wait "$agent_pid" 2>/dev/null
    wait "$reader_pid" 2>/dev/null
    kill "$watchdog_pid" 2>/dev/null
    wait "$watchdog_pid" 2>/dev/null
    rm -f "$fifo"

    # The subshell writes its exit code to rc_file as its last act. If the
    # watchdog killed a stalled agent, that line never ran and rc_file is empty
    # (or absent) — treat that as a timeout (124, the conventional code) rather
    # than letting an empty value break `return "$rc"` downstream.
    local rc
    rc=$(cat "$rc_file" 2>/dev/null || echo "")
    rm -f "$rc_file"
    case "$rc" in
    ''|*[!0-9]*) rc=124 ;;
    esac

    # If the agent reported an account usage/quota limit, halt the whole loop.
    # Retrying only burns more attempts against an exhausted account; the user
    # must raise the limit (or wait for reset) before re-launching.
    if [ -s "$USAGE_LIMIT_FILE" ]; then
        echo ""
        echo "════════════════════════════════════════"
        echo "❌ ENVIRONMENT ERROR: Agent account usage limit reached"
        echo "════════════════════════════════════════"
        echo "The agent reported it is out of usage (e.g. Cursor: 'You've reached"
        echo "your normal usage limit'). The loop cannot make progress."
        echo ""
        echo "Fix: ask your admin to raise the limit (or wait for the quota to"
        echo "reset), then re-launch ralph."
        exit 6
    fi

    # If the agent flagged an environment error (RALPH_ENV_ERROR sentinel),
    # halt the whole loop. The failure is identical every iteration (expired
    # token, OOM, missing tool), so retrying only burns cost — the user must
    # fix the host.
    if [ -s "$ENV_ERROR_FILE" ]; then
        local env_reason last_err
        env_reason=$(cat "$ENV_ERROR_FILE" 2>/dev/null)
        last_err=$(cat "$LAST_TOOL_ERROR_FILE" 2>/dev/null)
        echo ""
        echo "════════════════════════════════════════"
        echo "❌ ENVIRONMENT ERROR: Agent reported an unrecoverable environment problem"
        echo "════════════════════════════════════════"
        echo "The agent emitted RALPH_ENV_ERROR and stopped. The loop cannot make"
        echo "progress until the underlying problem is fixed."
        echo ""
        echo "Reason given by the agent:"
        echo "  ${env_reason:-(none — model printed the bare token)}"
        if [ -n "$last_err" ]; then
            echo ""
            echo "Last failing tool output (likely trigger):"
            echo "$last_err" | head -c 800 | sed 's/^/  /'
            echo ""
        fi
        echo ""
        echo "Fix: resolve the issue above, then re-launch ralph."
        exit 6
    fi

    return "$rc"
}

# Protected files: restore if agent deletes them
PROTECTED_FILES="AGENTS.md specs"
ACTION_PLAN_BAK="${LOG_DIR}/action-plan_${PROJECT_NAME}.bak"

protect_before() {
    [ -f ACTION_PLAN.md ] && cp ACTION_PLAN.md "$ACTION_PLAN_BAK" || true
}

protect_after() {
    for f in $PROTECTED_FILES; do
        [ ! -e "$f" ] && git checkout -- "$f" 2>/dev/null && echo "⚠️  Restored $f (agent deleted it)"
    done
    if [ ! -f ACTION_PLAN.md ] && [ -f "$ACTION_PLAN_BAK" ]; then
        cp "$ACTION_PLAN_BAK" ACTION_PLAN.md
        echo "⚠️  Restored ACTION_PLAN.md (agent deleted it)"
    fi
}

# Archive ACTION_PLAN.md after a bootstrap — but ONLY if the agent actually
# created tasks in beads. A bootstrap can "succeed" (exit 0) while producing
# zero tasks (e.g. the agent backend returned empty responses). Archiving the
# plan in that case strands the workspace with no plan and no tasks, so the
# next iteration exits 1. Instead, keep the plan and halt so the user can fix
# the agent and re-run without losing the plan.
archive_plan_or_halt() {
    local total
    total=$(bd list --json 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
    if [ -z "$total" ] || [ "$total" = "0" ]; then
        echo ""
        echo "════════════════════════════════════════"
        echo "❌ BOOTSTRAP PRODUCED NO TASKS"
        echo "════════════════════════════════════════"
        echo "The bootstrap finished but beads has no tasks. ACTION_PLAN.md is"
        echo "kept (not archived). This usually means the agent backend failed to"
        echo "respond (e.g. Ollama returned empty output). Fix the agent and"
        echo "re-launch — the plan is preserved."
        exit 6
    fi
    mv ACTION_PLAN.md "ACTION_PLAN_$(date +%Y%m%d_%H%M%S).md"
    rm -f "$ACTION_PLAN_BAK"
    echo "ACTION_PLAN.md archived after bootstrap ($total tasks created)"
}

# Pre-flight environment check: detect conditions that will cause every iteration to fail.
# Runs once at startup and before each iteration. Exits immediately so the user can fix the
# environment rather than burning iterations on BLOCKED tasks.
preflight_check() {
    # Check AWS SSO token (only if AWS CLI is available and project uses it)
    if [ -n "$RALPH_REQUIRE_AWS" ] || command -v otxb_build.py &>/dev/null; then
        if command -v aws &>/dev/null && ! aws sts get-caller-identity &>/dev/null 2>&1; then
            echo ""
            echo "════════════════════════════════════════"
            echo "❌ ENVIRONMENT ERROR: AWS credentials expired or invalid"
            echo "════════════════════════════════════════"
            echo "The AWS SSO token is not valid. Tests and Docker builds will fail."
            echo ""
            echo "Fix: run 'dev-login' or 'aws sso login' on the host, then re-launch ralph."
            exit 6
        fi
    fi

    # Check Docker is responsive and has enough memory for test suites
    if command -v docker &>/dev/null; then
        if ! docker info &>/dev/null 2>&1; then
            echo ""
            echo "════════════════════════════════════════"
            echo "❌ ENVIRONMENT ERROR: Docker is not responding"
            echo "════════════════════════════════════════"
            echo "Docker daemon is unreachable. Ensure Docker Desktop is running."
            exit 6
        fi

        DOCKER_MEM_BYTES=$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo "0")
        DOCKER_MEM_GB=$(echo "$DOCKER_MEM_BYTES / 1073741824" | bc 2>/dev/null || echo "0")
        MIN_DOCKER_MEM_GB="${RALPH_MIN_DOCKER_MEM_GB:-10}"
        if [ "$DOCKER_MEM_GB" -lt "$MIN_DOCKER_MEM_GB" ] 2>/dev/null; then
            echo ""
            echo "════════════════════════════════════════"
            echo "❌ ENVIRONMENT ERROR: Docker memory too low (${DOCKER_MEM_GB}GB < ${MIN_DOCKER_MEM_GB}GB)"
            echo "════════════════════════════════════════"
            echo "Test suites need at least ${MIN_DOCKER_MEM_GB}GB. Previous runs hit OOM (exit 137)."
            echo ""
            echo "Fix: Docker Desktop → Settings → Resources → Memory → ${MIN_DOCKER_MEM_GB}GB+"
            exit 6
        fi
    fi
}

# A compact fingerprint of "did this iteration accomplish anything": current
# commit, a hash of the working-tree status, and the number of closed tasks.
# If this string is identical before and after an agent turn that exited 0,
# the turn made no real progress (no edits, no commits, no task closed).
progress_signature() {
    local head status_hash closed
    head=$(git rev-parse HEAD 2>/dev/null || echo "no-git")
    status_hash=$(git status --porcelain 2>/dev/null | shasum 2>/dev/null | awk '{print $1}')
    closed=$(bd list --status closed --json 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
    echo "${head}|${status_hash}|closed=${closed}"
}

# Release any task left in_progress back to open so a future iteration can
# re-claim it. Used when an iteration makes no progress: a model that claims a
# task and then no-ops the turn (e.g. a malformed tool call serialized as text)
# would otherwise strand the claim, and every dependent task stays blocked.
release_orphaned_tasks() {
    local ids
    ids=$(bd list --json 2>/dev/null | jq -r '[.[] | select(.status=="in_progress") | .id] | join(" ")' 2>/dev/null)
    [ -z "$ids" ] && return 0
    echo "↩️  Releasing stranded in_progress task(s) back to open: $ids"
    local id
    for id in $ids; do
        bd update "$id" --status open >/dev/null 2>&1 || true
    done
}

# Track elapsed time
START_TIME=$(date +%s)
elapsed() {
    local secs=$(( $(date +%s) - START_TIME ))
    printf "%dm%02ds" $((secs / 60)) $((secs % 60))
}

# Initialize log files (monitoring is handled by host via ralph-in-a-box.sh)
mkdir -p "$LOG_DIR"
>"$LOG_FILE"
echo "0" >"$COST_FILE"
echo "0" >"$ITERATION_FILE"
echo "0" >"$NO_PROGRESS_FILE"
echo "Agent: $RALPH_AGENT"
echo "Logs: $LOG_FILE"
if [ "$RALPH_AGENT" = "claude" ]; then
    echo "Limits: MAX_ITERATIONS=$MAX_ITERATIONS, MAX_COST=\$$MAX_COST"
else
    echo "Limits: MAX_ITERATIONS=$MAX_ITERATIONS"
fi
echo "Starting $RALPH_AGENT automation loop with beads..."

# Run pre-flight checks once at startup
preflight_check

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
        printf "Completed %d iterations in %s. Total cost: \$%.2f\n" $((ITERATION - 1)) "$(elapsed)" "$TOTAL_COST"
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
            printf "Total cost: \$%.2f. Completed %d iterations in %s.\n" "$TOTAL_COST" "$ITERATION" "$(elapsed)"
            echo ""
            echo "Remaining tasks:"
            bd list
            exit 4
        fi
    fi

    echo ""
    echo "═══════════════════════════════════════════════════════════"
    if [ "$RALPH_AGENT" = "claude" ]; then
        printf "ITERATION %d/%d | Cost: \$%.2f/\$%.2f | %s | Agent: %s\n" "$ITERATION" "$MAX_ITERATIONS" "$TOTAL_COST" "$MAX_COST" "$(elapsed)" "$RALPH_AGENT"
    else
        printf "ITERATION %d/%d | %s | Agent: %s\n" "$ITERATION" "$MAX_ITERATIONS" "$(elapsed)" "$RALPH_AGENT"
    fi
    echo "═══════════════════════════════════════════════════════════"

    # Re-check environment each iteration (tokens can expire mid-run)
    preflight_check

    # Task detection: get counts (fallback to empty if beads not initialized)
    TASK_JSON=$(bd list --json 2>/dev/null || echo "[]")
    TOTAL=$(echo "$TASK_JSON" | jq 'length')
    OPEN=$(echo "$TASK_JSON" | jq '[.[] | select(.status != "closed")] | length')
    READY=$(bd ready --json 2>/dev/null | jq 'length' 2>/dev/null || echo "0")

    if [ "$TOTAL" = "0" ] || [ -z "$TOTAL" ]; then
        # bd list --json only returns open tasks; if .beads exists, all tasks are closed
        if [ -d ".beads" ] && [ -f "ACTION_PLAN.md" ]; then
            # New ACTION_PLAN.md with all previous tasks closed — re-bootstrap
            echo ""
            echo "════════════════════════════════════════"
            echo "🚀 BOOTSTRAP — New ACTION_PLAN.md detected (previous tasks closed)"
            echo "════════════════════════════════════════"

            rm -f .beads/dolt-access.lock 2>/dev/null
            >"$LOG_FILE"
            echo "=== Bootstrap $(date) ===" >>"$LOG_FILE"

            protect_before
            invoke_agent "$BOOTSTRAP_FILE"
            AGENT_EXIT_CODE=$?
            protect_after

            if [ $AGENT_EXIT_CODE -ne 0 ]; then
                echo ""
                echo "════════════════════════════════════════"
                echo "❌ BOOTSTRAP ERROR (exit code: $AGENT_EXIT_CODE)"
                echo "════════════════════════════════════════"
                exit $AGENT_EXIT_CODE
            fi

            archive_plan_or_halt

            sleep $CHECK_INTERVAL
            continue
        elif [ -d ".beads" ]; then
            OPEN="0"
        elif [ -f "ACTION_PLAN.md" ]; then
            echo ""
            echo "════════════════════════════════════════"
            echo "🚀 BOOTSTRAP — Creating tasks from ACTION_PLAN.md"
            echo "════════════════════════════════════════"

            rm -f .beads/dolt-access.lock 2>/dev/null
            >"$LOG_FILE"
            echo "=== Bootstrap $(date) ===" >>"$LOG_FILE"

            protect_before
            invoke_agent "$BOOTSTRAP_FILE"
            AGENT_EXIT_CODE=$?
            protect_after

            if [ $AGENT_EXIT_CODE -ne 0 ]; then
                echo ""
                echo "════════════════════════════════════════"
                echo "❌ BOOTSTRAP ERROR (exit code: $AGENT_EXIT_CODE)"
                echo "════════════════════════════════════════"
                exit $AGENT_EXIT_CODE
            fi

            archive_plan_or_halt

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

        # Verification: compare ACTION_PLAN against completed tasks
        VERIFY_OK=true
        ACTION_PLAN=$(ls -t ACTION_PLAN_*.md 2>/dev/null | head -1)
        if [ -n "$ACTION_PLAN" ] && [ -f "$VERIFY_FILE" ]; then
            echo ""
            echo "════════════════════════════════════════"
            echo "📋 VERIFYING PLAN COVERAGE"
            echo "════════════════════════════════════════"

            rm -f .beads/dolt-access.lock 2>/dev/null
            >"$LOG_FILE"
            echo "=== Verify $(date) ===" >>"$LOG_FILE"

            protect_before
            invoke_agent "$VERIFY_FILE"
            VERIFY_EXIT=$?
            protect_after

            if [ "$VERIFY_EXIT" -ne 0 ]; then
                VERIFY_OK=false
                echo ""
                echo "⚠️  Verify reported gaps or dirty workspace (exit $VERIFY_EXIT)"
            fi
            echo ""
        fi

        # Strict landing: check for uncommitted changes
        DIRTY_FILES=$(git status --porcelain 2>/dev/null | grep -v '^?? ' || true)
        UNTRACKED=$(git status --porcelain 2>/dev/null | grep '^?? ' || true)
        if [ -n "$DIRTY_FILES" ]; then
            VERIFY_OK=false
            echo "⚠️  DIRTY WORKSPACE — uncommitted changes:"
            echo "$DIRTY_FILES"
            echo ""
        fi
        if [ -n "$UNTRACKED" ]; then
            echo "ℹ️  Untracked files (not blocking):"
            echo "$UNTRACKED"
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
        echo ""

        if [ "$VERIFY_OK" = true ]; then
            echo "════════════════════════════════════════"
            echo "✅ WORK SESSION COMPLETE"
            echo "════════════════════════════════════════"
            printf "Iterations: %d | Total cost: \$%.2f | Elapsed: %s\n" "$ITERATION" "$TOTAL_COST" "$(elapsed)"
            exit 0
        else
            echo "════════════════════════════════════════"
            echo "⚠️  SESSION FINISHED WITH WARNINGS"
            echo "════════════════════════════════════════"
            printf "Iterations: %d | Total cost: \$%.2f | Elapsed: %s\n" "$ITERATION" "$TOTAL_COST" "$(elapsed)"
            echo "Review the verify output above for gaps or uncommitted changes."
            exit 5
        fi
    fi

    # Count only actionable tasks (not epics) in the ready queue
    READY_TASKS=$(bd ready --json 2>/dev/null | jq '[.[] | select(.title | test("^\\[impl\\]|^\\[test\\]|^\\[review\\]"))] | length' 2>/dev/null || echo "0")

    if [ "$READY_TASKS" = "0" ]; then
        # Before giving up: a task stranded in_progress (e.g. an earlier crash,
        # or a no-op turn whose claim wasn't released) makes its dependents
        # unready and looks like a dead-end. Release any such orphan and retry,
        # bounded by the no-progress counter so a task that can't progress can't
        # loop forever.
        IN_PROGRESS=$(bd list --json 2>/dev/null | jq -r '[.[] | select(.status=="in_progress") | .id] | join(" ")' 2>/dev/null)
        NO_PROGRESS=$(cat "$NO_PROGRESS_FILE" 2>/dev/null || echo "0")
        if [ -n "$IN_PROGRESS" ] && [ "$NO_PROGRESS" -lt "$MAX_NO_PROGRESS" ]; then
            echo ""
            echo "⚠️  No ready tasks, but task(s) stuck in_progress — releasing and retrying"
            NO_PROGRESS=$((NO_PROGRESS + 1))
            echo "$NO_PROGRESS" >"$NO_PROGRESS_FILE"
            release_orphaned_tasks
            sleep "$CHECK_INTERVAL"
            continue
        fi

        echo ""
        echo "════════════════════════════════════════"
        echo "⚠️  BLOCKED - No actionable tasks (only epics/deferred remain)"
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

    PROGRESS_BEFORE=$(progress_signature)

    protect_before
    invoke_agent "$DO_TASK_FILE"
    AGENT_EXIT_CODE=$?
    protect_after

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

    # No-progress guard. A headless agent always exits 0, so exit code alone
    # can't tell a productive turn from a no-op (e.g. a tool call the model
    # serialized as plain text, which the harness never executes). The
    # authoritative signal is a before/after fingerprint of the working tree +
    # closed-task count: if it's unchanged, the turn did nothing. The
    # malformed-tool-call flag is only a corroborating diagnostic — it never
    # triggers the guard on its own (legitimate prose can mention "<tool_use>"),
    # but the real bug always also shows up as no progress.
    PROGRESS_AFTER=$(progress_signature)
    NO_PROGRESS=$(cat "$NO_PROGRESS_FILE" 2>/dev/null || echo "0")
    if [ "$PROGRESS_BEFORE" = "$PROGRESS_AFTER" ]; then
        NO_PROGRESS=$((NO_PROGRESS + 1))
        echo "$NO_PROGRESS" >"$NO_PROGRESS_FILE"
        echo ""
        echo "⚠️  NO PROGRESS this iteration ($NO_PROGRESS/$MAX_NO_PROGRESS) — no commits, no edits, no task closed"
        [ -s "$MALFORMED_TOOLCALL_FILE" ] && echo "    likely cause: malformed tool-call markup in agent output (tool call emitted as plain text)"

        # Release the stranded claim so the next iteration can re-attempt it
        # instead of dead-ending on a permanently in_progress task.
        release_orphaned_tasks

        if [ "$NO_PROGRESS" -ge "$MAX_NO_PROGRESS" ]; then
            echo ""
            echo "════════════════════════════════════════"
            echo "❌ HALTED - $NO_PROGRESS consecutive no-progress iterations"
            echo "════════════════════════════════════════"
            echo "The agent ran without error but produced no work (no edits, no"
            echo "commits, no task closed) $NO_PROGRESS times in a row. This usually means"
            echo "the model cannot emit valid tool calls (common with some quantized"
            echo "local builds) or is stuck re-reading context."
            echo ""
            echo "Fix: try a different model/build, or inspect $LOG_FILE."
            echo ""
            bd list
            exit 7
        fi
    else
        # Productive iteration — reset the streak.
        echo "0" >"$NO_PROGRESS_FILE"
    fi

    sleep $CHECK_INTERVAL
done
