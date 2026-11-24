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

# Titles of plan work the loop executes. Epics and discovered-work issues (filed
# without a prefix, see agent-settings CLAUDE.md) are not plan work: they never
# keep a plan from landing, and leftover discovered work is listed as backlog.
ACTIONABLE_TITLE_RE='^\[(impl|test|review)\]'

# Use shared log directory and project name (set by ralph-in-a-box.sh) or fallback
LOG_DIR="${RALPH_LOG_DIR:-/tmp}"
PROJECT_NAME="${RALPH_PROJECT_NAME:-$(basename "$(pwd)")}"
AGENT_PREFIX="${RALPH_AGENT}"
LOG_FILE="${LOG_DIR}/${AGENT_PREFIX}_live_${PROJECT_NAME}.log"
COST_FILE="${LOG_DIR}/${AGENT_PREFIX}_cost_${PROJECT_NAME}.txt"
ITERATION_FILE="${LOG_DIR}/${AGENT_PREFIX}_iteration_${PROJECT_NAME}.txt"
# Deterministic gates (bash/python run by the loop instead of the agent). See gates/.
# RALPH_GATES=0 disables them all and restores the pure-agent behaviour.
GATES_DIR="${GATES_DIR:-/opt/ralph/gates}"
GATE_CONTEXT_FILE="${LOG_DIR}/${AGENT_PREFIX}_gate-context_${PROJECT_NAME}.md"
GATE_ENV_ERROR_FILE="${LOG_DIR}/${AGENT_PREFIX}_gate-env-error_${PROJECT_NAME}.txt"
export GATE_CONTEXT_FILE GATE_ENV_ERROR_FILE
# Per-invocation cost/usage metrics (one JSON line per agent run). Append-only:
# unlike LOG_FILE it survives iterations. Summarise with ralph-report.py.
METRICS_FILE="${LOG_DIR}/${AGENT_PREFIX}_metrics_${PROJECT_NAME}.jsonl"
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
    rm -f "$WATCHDOG_FIRED_FILE" 2>/dev/null
}
trap cleanup EXIT
# The handler does not exit (the loop stops through the agent-error path), so
# remember the interrupt: after Ctrl+C / docker stop a watchdog kill must not be
# mistaken for a plain timeout (see WATCHDOG_FIRED_FILE).
INTERRUPTED=0
trap 'INTERRUPTED=1; cleanup' SIGTERM SIGINT

# Timestamp file for watchdog (tracks last output from agent)
HEARTBEAT_FILE=$(mktemp /tmp/ralph-heartbeat-XXXXXX)

# Flag file: written by the watchdog right before it kills a silent agent. A
# missing rc (exit code 124) has two causes that must not be confused: the
# watchdog killed the agent (the turn may still have produced work, so the loop
# judges it by progress) or the user interrupted it with Ctrl+C (the loop must
# stop). Only the first one writes this file.
WATCHDOG_FIRED_FILE=$(mktemp /tmp/ralph-watchdog-XXXXXX)

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
        # Skip prompt echoes, reasoning and tool traffic: file contents and
        # command output (e.g. code handling a "usage limit exceeded" error)
        # would otherwise trigger a false halt.
        case "$line" in
        *'"type":"user"'* | *'"role":"user"'* | *'"type":"thinking"'* | *'"thinking":"'* | *'"type":"tool_use"'* | *'"type":"tool_result"'* | *'"type":"tool_call"'*) ;;
        *"reached your normal usage limit"* | *"out of usage"* | *"increase your limit to continue"* | *"usage limit"*)
            echo "LIMIT" >"$USAGE_LIMIT_FILE"
            ;;
        esac

        # Detect the agent's environment-error sentinel. The agent cannot set
        # its own exit code in headless mode, so it prints this marker and the
        # loop halts in invoke_agent.
        #
        # Three false-positive sources, all excluded:
        #   1. Prompt echo — some agents replay the prompt as a "type":"user"
        #      event, and the prompt documents the token.
        #   2. The model *citing* the token while reasoning about it (e.g.
        #      gemma4's thinking: "print the exact token `RALPH_ENV_ERROR` on
        #      its own line"). Reasoning lives in "thinking" blocks and quotes
        #      the token inline (backticks, mid-sentence).
        #   3. An explicit non-error ("RALPH_ENV_ERROR: none — this is a test
        #      defect…"), which models print to say there is *no* problem.
        # So: skip user/thinking lines and explicit non-errors entirely, and
        # otherwise require the token to appear as an isolated JSON string
        # value or alone on its own line
        # ("\n…\n"), which is how a genuine emission ("on its own line") arrives
        # in an assistant text block — not as a substring of prose.
        case "$line" in
        *'"type":"user"'* | *'"role":"user"'* | *'"type":"thinking"'* | *'"thinking":"'*) ;;
        *'RALPH_ENV_ERROR: none'* | *'RALPH_ENV_ERROR: None'* | *'RALPH_ENV_ERROR: n/a'*) ;;
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
            # Cursor (run with --stream-partial-output) emits each text delta as
            # its own assistant event AND, at the end of the block, a single
            # consolidated assistant event carrying the whole message. Printing
            # both duplicates every message — once char-by-char, once whole. The
            # consolidated event is the only one that carries "model_call_id", so
            # for cursor we skip the partial fragments and print only the join.
            # Other agents (claude/codex/ollama) emit whole blocks with no
            # "model_call_id", so this gate never suppresses their output.
            if [ "$RALPH_AGENT" = "cursor" ] \
                && [ "$(echo "$line" | jq -r 'has("model_call_id")' 2>/dev/null)" != "true" ]; then
                continue
            fi
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
        local now=$(date +%s)
        local last_beat=$(cat "$HEARTBEAT_FILE" 2>/dev/null)
        # parse_stream writes via `date +%s >"$HEARTBEAT_FILE"`, which opens
        # with O_TRUNC before the timestamp is written. A poll landing in that
        # window reads an empty file — `cat` still exits 0, so the old
        # `|| echo "0"` fallback (which only covers a *failed* cat) never
        # caught it, and `$(( now - "" ))` evaluated the empty string as 0,
        # producing silent ~= now (the current epoch, ~1.7 billion) and an
        # instant false-positive kill. Default to `now` instead: a stale or
        # unreadable read costs at most one extra 30s poll, never a guaranteed
        # kill.
        last_beat=${last_beat:-$now}
        local silent=$(( now - last_beat ))
        if [ "$silent" -ge "$AGENT_TIMEOUT" ]; then
            echo ""
            echo "⚠️  WATCHDOG: Agent silent for ${silent}s (timeout: ${AGENT_TIMEOUT}s) — killing"
            echo 1 >"$WATCHDOG_FIRED_FILE"
            kill_tree "$agent_pid" TERM
            sleep 2
            kill_tree "$agent_pid" KILL
            # Close the read side so the pipeline unblocks and invoke_agent returns.
            kill "$reader_pid" 2>/dev/null
            break
        fi
    done
}

# jq program: reduce one agent run's stream-json events to a single metrics object.
# Answers "where do the tokens go": per-turn context size, cost, and bytes of tool
# output fed back into the context, grouped by tool category.
METRICS_JQ='
  def txt: if type=="array" then (map(.text? // "") | join("")) else (. // "" | tostring) end;
  def cat($u):
    if $u.name == "Bash" then
      ($u.input.command // "") as $c
      | if   ($c | test("pytest|unittest|cargo (test|nextest)|npm (run )?test")) then "Bash:test"
        elif ($c | test("\\b(sleep|tail -[nf]|wait)\\b"))                                    then "Bash:poll"
        elif ($c | test("(^|[;&| ])bd "))                                                    then "Bash:bd"
        elif ($c | test("(^|[;&| ])git "))                                                   then "Bash:git"
        elif ($c | test("ruff|pyrefly|gitleaks|clippy|biome|cargo (fmt|check)"))             then "Bash:lint"
        else "Bash:other" end
    elif $u.name == "Read" and (($u.input.file_path // "") | test("/specs/|/\\.claude/")) then "Read:spec"
    else $u.name end;
  . as $ev
  | [ $ev[] | select(.type=="assistant") ] as $asst
  | ([ $ev[] | select(.type=="result") ] | .[-1] // {}) as $res
  | ( [ $asst[] | select(.message.usage != null) ] | group_by(.message.id) | map(.[-1].message.usage) ) as $turns
  | ( [ $asst[].message.content[]? | select(.type=="tool_use") ] ) as $uses
  | ( [ $ev[] | select(.type=="user") | .message.content[]? | select(type=="object" and .type=="tool_result")
        | { key: .tool_use_id, value: ((.content | txt) | length) } ] | from_entries ) as $bytes
  | ( [ $uses[] | { c: cat(.), b: ($bytes[.id] // 0) } ]
      | group_by(.c)
      | map({ key: .[0].c, value: { n: length, result_bytes: (map(.b) | add) } }) | from_entries ) as $tools
  | ( [ $turns[] | ((.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)) ] ) as $ctx
  | {
      cost_usd:  ($res.total_cost_usd // 0),
      num_turns: ($res.num_turns // ($turns | length)),
      api_ms:    ($res.duration_api_ms // 0),
      is_error:  ($res.is_error // false),
      tokens: {
        input:          ([$turns[].input_tokens // 0] | add // 0),
        cache_read:     ([$turns[].cache_read_input_tokens // 0] | add // 0),
        cache_creation: ([$turns[].cache_creation_input_tokens // 0] | add // 0),
        output:         ([$turns[].output_tokens // 0] | add // 0)
      },
      first_turn_ctx: ($ctx[0] // 0),
      max_ctx:        ($ctx | max // 0),
      tools: $tools,
      claimed: ( [ $uses[] | select(.name=="Bash") | (.input.command // "")
                   | (capture("bd update (?<id>[^ ]+) --claim") | .id)? ] | .[0] // null )
    }'

# Append one metrics line for the agent run that just finished.
# $1 prompt file  $2 first LOG_FILE line of this run  $3 exit code  $4 wall seconds
record_metrics() {
    [ "$RALPH_AGENT" = "claude" ] || return 0
    local prompt_file="$1" start_line="$2" rc="$3" wall="$4" kind m claimed title=""
    case "$(basename "$prompt_file")" in
    BOOTSTRAP*) kind="bootstrap" ;;
    VERIFY*) kind="verify" ;;
    *) kind="task" ;;
    esac
    m=$(tail -n +"$((start_line + 1))" "$LOG_FILE" | jq -c -R 'fromjson? // empty' 2>/dev/null | jq -s -c "$METRICS_JQ" 2>/dev/null) || return 0
    [ -n "$m" ] || return 0
    claimed=$(echo "$m" | jq -r '.claimed // empty')
    # The loop claims the task itself now (RALPH_RUN_TASK); the agent no longer runs `bd update --claim`.
    [ -n "${RALPH_RUN_TASK:-}" ] && claimed="$RALPH_RUN_TASK"
    [ -n "$claimed" ] && title=$(bd show "$claimed" --json 2>/dev/null | jq -r 'if type=="array" then .[0] else . end | .title // empty' 2>/dev/null)
    local phase="$kind"
    if [ "$kind" = "task" ]; then
        phase=$(echo "$title" | sed -nE 's/^\[([a-z]+)\].*/\1/p')
        [ -z "$phase" ] && phase="task-unknown"
    fi
    echo "$m" | jq -c --argjson it "$ITERATION" --arg kind "$kind" --arg phase "$phase" \
        --arg task "$claimed" --arg title "$title" --argjson rc "$rc" --argjson wall "$wall" \
        --arg ts "$(date -u +%FT%TZ)" --arg model "${ANTHROPIC_MODEL:-default}" \
        '. + {ts:$ts, iteration:$it, kind:$kind, phase:$phase, task:$task, title:$title, exit_code:$rc, wall_s:$wall, model:$model}' \
        >>"$METRICS_FILE" 2>/dev/null || true
}

gates_enabled() { [ "${RALPH_GATES:-1}" = "1" ] && [ -d "$GATES_DIR" ]; }

# One metrics line for work done by a gate (no agent, no tokens): $1 phase $2 task $3 wall seconds
record_gate_metrics() {
    [ "$RALPH_AGENT" = "claude" ] || return 0
    jq -n -c --argjson it "$ITERATION" --arg phase "$1" --arg task "$2" --argjson wall "$3" --arg ts "$(date -u +%FT%TZ)" \
        '{ts:$ts, iteration:$it, kind:"gate", phase:$phase, task:$task, title:"", exit_code:0, wall_s:$wall, model:"bash",
          cost_usd:0, num_turns:0, api_ms:0, is_error:false,
          tokens:{input:0,cache_read:0,cache_creation:0,output:0}, first_turn_ctx:0, max_ctx:0, tools:{}}' \
        >>"$METRICS_FILE" 2>/dev/null || true
}

# Bootstrap ACTION_PLAN.md into beads: the script first, the agent only if the plan
# cannot be parsed with certainty (nothing was created in that case).
run_bootstrap() {
    if gates_enabled && [ -f "$GATES_DIR/bootstrap_plan.py" ]; then
        local t0 rc
        t0=$(date +%s)
        # shellcheck source=gates/common.sh
        . "$GATES_DIR/common.sh"
        RALPH_FEATURE_TAG_RE=$(ralph_conf RALPH_FEATURE_TAG_RE 2>/dev/null) python3 "$GATES_DIR/bootstrap_plan.py" ACTION_PLAN.md </dev/null
        rc=$?
        if [ "$rc" -eq 0 ]; then
            record_gate_metrics bootstrap-script "" "$(( $(date +%s) - t0 ))"
            return 0
        fi
        [ "$rc" -eq 3 ] && return 3
        echo "↩️  bootstrap script could not handle the plan (exit $rc) — falling back to the BOOTSTRAP agent"
    fi
    invoke_agent "$BOOTSTRAP_FILE"
}

# Final report: deterministic when the [audit] task already judged the plan, else the VERIFY agent.
# Prints the report; returns 0 PASS / 1 FAIL like the agent would.
run_verify() {
    if gates_enabled && [ -f "$GATES_DIR/verify.sh" ]; then
        local t0 rc
        t0=$(date +%s)
        bash "$GATES_DIR/verify.sh" </dev/null
        rc=$?
        if [ "$rc" -le 1 ]; then
            record_gate_metrics verify-script "" "$(( $(date +%s) - t0 ))"
            return "$rc"
        fi
        echo "↩️  verify script cannot judge this plan state (exit $rc) — falling back to the VERIFY agent"
    fi
    invoke_agent "$VERIFY_FILE"
}

# RALPH_REQUIRE_BRANCH (project profile / AGENTS.md): stop before spending anything when the checkout is on another branch.
# Mirrors the rule "wrong branch: make no commit, record BLOCKED: wrong branch in BLOCKERS.md, end the task".
check_required_branch() {
    gates_enabled || return 0
    # shellcheck source=gates/common.sh
    . "$GATES_DIR/common.sh"
    branch_ok && return 0
    local req branch
    req=$(ralph_conf RALPH_REQUIRE_BRANCH)
    branch=$(git branch --show-current 2>/dev/null)
    {
        echo ""
        echo "## BLOCKED: wrong branch"
        echo "- **Expected branch:** $req"
        echo "- **Current branch:** ${branch:-<detached HEAD>}"
        echo "- **What is needed:** switch the checkout to the required branch and re-launch ralph"
        echo "- **Date:** $(date +%F)"
    } >>BLOCKERS.md
    echo ""
    echo "════════════════════════════════════════"
    echo "❌ WRONG BRANCH: '${branch:-<detached HEAD>}' is not '$req' (RALPH_REQUIRE_BRANCH)"
    echo "════════════════════════════════════════"
    echo "No agent was started and nothing was committed. Recorded in BLOCKERS.md."
    exit 8
}

# An Epic whose last closed task is an [impl] and has nothing open is stuck (no [review] will ever follow): create it.
# Runs before the loop counts open work, otherwise such an Epic looks "done" and its work is never committed.
sweep_epics() {
    gates_enabled || return 0
    bash "$GATES_DIR/epic-sweep.sh" </dev/null
}

# Decide what the next iteration is before waking the agent.
#   return 0: the iteration was handled by a gate (no agent needed)
#   return 1: run the agent with $PROMPT_FILE (DO_TASK + a LOOP CONTEXT section)
gate_iteration() {
    PROMPT_FILE="$DO_TASK_FILE"
    gates_enabled || return 1
    # shellcheck source=gates/common.sh
    . "$GATES_DIR/common.sh"
    local next id title t0 rc files out
    RALPH_RUN_TASK="" # set below once a task is assigned; read by record_metrics
    next=$(bash "$GATES_DIR/next-task.sh" </dev/null) || return 1
    id=$(jq -r .id <<<"$next")
    title=$(jq -r .title <<<"$next")
    local phase claimed=0 parent
    phase=$(sed -nE 's/^\[([a-z]+)\].*/\1/p' <<<"$title")
    parent=$(jq -r '.parent // empty' <<<"$next")
    # The loop claims the task and hands over what the agent would otherwise fetch with
    # `bd show` / `bd list` (several turns and tens of KiB of tool output per run).
    RALPH_RUN_TASK="$id"
    if [ "$phase" != "test" ] && bd update "$id" --claim </dev/null >/dev/null 2>&1; then claimed=1; fi
    {
        echo "ASSIGNED TASK: $id — $title"
        if [ "$claimed" = 1 ]; then
            echo "The loop already found AND CLAIMED this task. Do NOT run \`bd ready\`, \`bd prime\`, \`bd show $id\` or \`bd list\` to"
            echo "orient yourself and do not claim it again: Phases 1-2 are done and their result is below. Start at Phase 3."
        else
            echo "The loop chose this task: claim exactly this one (\`bd update $id --claim\`) and skip \`bd ready\` discovery."
        fi
        echo ""
        echo "TASK (from beads, verbatim):"
        bd_task_json "$id" | jq -r '"status: \(.status)\nparent: \(.parent // "-")\n\n\(.description // "")" + (if .notes then "\n\nNOTES:\n\(.notes)" else "" end)'
        if [ -n "$parent" ] && [ -n "$(epic_tag "$parent")" ]; then
            echo ""
            echo "COMMIT TAG for this Epic (named by its Feature in the plan; use it as the commit prefix): $(epic_tag "$parent")"
        fi
        if [ -n "$parent" ]; then
            echo ""
            echo "EPIC VIEW (siblings; [status] id title :: close reason[0:80]):"
            bd list --all --json 2>/dev/null | jq -r --arg e "$parent" \
                '[.[] | select(.parent == $e)] | sort_by(.priority)[] | "[\(.status)] \(.id) \(.title) :: \((.close_reason // "-")[0:80])"'
        fi
        if [ "$phase" = "review" ] && [ -n "$parent" ]; then
            echo ""
            echo "CLOSED [impl] TASKS OF THIS EPIC (plan text, acceptance criteria, AC tables and FILES MODIFIED notes):"
            bd list --all --json 2>/dev/null | jq -r --arg e "$parent" \
                '[.[] | select(.parent == $e and .status == "closed" and (.title | startswith("[impl]")))][]
                 | "--- \(.id) \(.title)\n\(.description // "")\nNOTES:\n\(.notes // "-")\n"'
        fi
        echo ""
        echo "WORKING TREE (git status --porcelain, first 40 lines):"
        git status --porcelain 2>/dev/null | grep -vE "^\?\? ($(evidence_dir)/|ACTION_PLAN|\.beads)" | head -n 40
    } >"$GATE_CONTEXT_FILE"

    case "$title" in
    "[test]"*)
        t0=$(date +%s)
        bash "$GATES_DIR/test-gate.sh" "$id" </dev/null
        rc=$?
        if [ "$rc" -eq 0 ]; then
            record_gate_metrics test-gate "$id" "$(( $(date +%s) - t0 ))"
            label_run_issues
            return 0
        elif [ "$rc" -eq 20 ]; then
            echo ""
            echo "════════════════════════════════════════"
            echo "❌ ENVIRONMENT ERROR: the test gate hit an unrecoverable environment problem"
            echo "════════════════════════════════════════"
            echo "  $(cat "$GATE_ENV_ERROR_FILE" 2>/dev/null)"
            echo "Fix: resolve the issue above, then re-launch ralph."
            exit 6
        fi
        record_gate_metrics test-gate-fallback "$id" "$(( $(date +%s) - t0 ))"
        ;;
    "[review]"*)
        t0=$(date +%s)
        files=$(bd_task_json "$id" | jq -r '.description // ""' | parse_file_list)
        [ -n "$files" ] || files=$(git status --porcelain | grep -vE '^( D|D )' | sed -E 's/^...//' | filter_committable)
        # shellcheck disable=SC2086 # one path per word
        out=$(bash "$GATES_DIR/static-gate.sh" $files </dev/null)
        rc=$?
        {
            echo ""
            echo "STATIC GATE (ruff/pyrefly/biome/gitleaks, already run by the loop on the changed files):"
            printf '%s\n' "$out"
            if [ "$rc" -eq 0 ]; then
                echo "-> PASS. Do NOT re-run these linters or gitleaks (the lint step of [review] is done); do the rest of the phase."
            else
                echo "-> FAIL. Fix only the failures above, on changed lines, then re-run just the failing check."
            fi
            echo ""
            echo "TEST-INTEGRITY GATE (diff of test files against HEAD):"
            # shellcheck disable=SC2086 # one path per word
            bash "$GATES_DIR/test-integrity.sh" $files </dev/null
        } >>"$GATE_CONTEXT_FILE"
        record_gate_metrics review-prechecks "$id" "$(( $(date +%s) - t0 ))"
        ;;
    esac

    PROMPT_FILE=$(mktemp /tmp/ralph-prompt-XXXXXX)
    {
        bash "$GATES_DIR/build-prompt.sh" "$phase" "$DO_TASK_FILE"
        echo ""
        echo "---"
        echo "# LOOP CONTEXT (authoritative — computed by the loop before this run; overrides the workflow above where they differ)"
        cat "$GATE_CONTEXT_FILE"
    } >"$PROMPT_FILE"
    return 1
}

# Invoke the selected agent with a prompt file
# Agent runs in background; watchdog kills it if no output for AGENT_TIMEOUT seconds.
# Exit code is captured from the agent process (not parse_stream).
invoke_agent() {
    local prompt_file="$1"
    local rc_file=$(mktemp /tmp/ralph-rc-XXXXXX)
    local metrics_start_line metrics_t0
    metrics_start_line=$(wc -l <"$LOG_FILE" 2>/dev/null | tr -d ' ')
    metrics_t0=$(date +%s)
    date +%s >"$HEARTBEAT_FILE"
    # Clear any usage-limit / env-error / malformed-tool-call flag from a
    # previous invocation.
    : >"$USAGE_LIMIT_FILE"
    : >"$ENV_ERROR_FILE"
    : >"$MALFORMED_TOOLCALL_FILE"
    : >"$LAST_TOOL_ERROR_FILE"
    : >"$WATCHDOG_FIRED_FILE"

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
                --model "${RALPH_CURSOR_MODEL:-composer-2.5}" \
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
    record_metrics "$prompt_file" "${metrics_start_line:-0}" "$rc" "$(( $(date +%s) - metrics_t0 ))"
    # parse_stream runs in its own process and keeps the running total in COST_FILE: reload it so the
    # summary lines (and MAX_COST) include this run — the last run (VERIFY) is never reloaded otherwise.
    [ -f "$COST_FILE" ] && TOTAL_COST=$(cat "$COST_FILE" 2>/dev/null || echo "$TOTAL_COST")

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

# Ticket key every beads issue of this run is labelled with, for traceability
# (`bd list -l <TICKET>`). The beads prefix names the repo, so it cannot carry the
# ticket. Taken from the branch (its leading ticket, else the whole name); only on
# main/master, where the branch says nothing, from AGENTS.md. Empty = no label.
resolve_ticket() {
    local branch tag
    branch=$(git branch --show-current 2>/dev/null)
    if [ -n "$branch" ] && [ "$branch" != "main" ] && [ "$branch" != "master" ]; then
        tag=$(printf '%s' "$branch" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -n 1)
        printf '%s' "${tag:-$branch}"
        return 0
    fi
    grep -oE '[A-Z][A-Z0-9]+-[0-9]+' AGENTS.md 2>/dev/null | head -n 1
}
TICKET=$(resolve_ticket)
RUN_STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Label every issue created during this run that lacks the ticket. Runs after each
# agent turn, so it covers every creation path (bootstrap, [review], [test], RETRY,
# BLOCKED, discovered work) without relying on the prompts. Issues of earlier runs
# are left alone: they belong to their own ticket.
label_run_issues() {
    local ids
    [ -n "$TICKET" ] || return 0
    ids=$(bd list --all --json 2>/dev/null | jq -r --arg t "$TICKET" --arg since "$RUN_STARTED_AT" \
        '.[] | select(.created_at >= $since) | select((.labels // []) | index($t) | not) | .id' 2>/dev/null)
    [ -n "$ids" ] || return 0
    # shellcheck disable=SC2086 # one issue id per word
    bd label add $ids "$TICKET" >/dev/null 2>&1 || echo "⚠️  Could not label issues with $TICKET: $ids"
    return 0
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
    if [ -n "$RALPH_REQUIRE_AWS" ]; then
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
# commit, a CONTENT hash of the working tree, and the total task count.
# If this string is identical before and after an agent turn that exited 0,
# the turn made no real progress (no edits, no commits, no task created/closed).
#
# Notes on why each component is what it is:
#  - We hash `git diff HEAD` (tracked content) + the list of untracked files,
#    NOT `git status --porcelain`. Porcelain is content-blind: editing an
#    already-modified file a second time leaves the same ` M path` line, so a
#    real edit during the multi-sibling [impl] phase (which edits but does not
#    commit until [test]) would look like no progress. The diff hash changes
#    whenever file *content* changes.
#  - We hash the full set of (id, status) pairs from `bd list --all --json`,
#    NOT a task count. A count is not a reliable signal: `bd list --json`
#    returns open tasks only (flat when a [test] turn closes its task and opens
#    the next), and even a closed-count can miss a productive turn that only
#    reopens or reprioritises. A phase transition (create / close / reopen)
#    always changes the id→status map, so its hash moves whenever the task graph
#    advances — exactly the "did a phase complete" signal we want. `--all`
#    includes closed issues (the default filter hides them).
progress_signature() {
    local head diff_hash untracked tasks
    head=$(git rev-parse HEAD 2>/dev/null || echo "no-git")
    diff_hash=$(git diff HEAD 2>/dev/null | shasum 2>/dev/null | awk '{print $1}')
    untracked=$(git ls-files --others --exclude-standard 2>/dev/null | shasum 2>/dev/null | awk '{print $1}')
    tasks=$(bd list --all --json 2>/dev/null | jq -S -r '[.[] | "\(.id):\(.status)"] | sort | join(",")' 2>/dev/null | shasum 2>/dev/null | awk '{print $1}')
    echo "${head}|${diff_hash}|${untracked}|tasks=${tasks}"
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

# Discovered work still open when a plan lands: not this plan's, so it does not
# block, but it must not vanish either.
print_backlog() {
    local backlog
    backlog=$(bd list --json 2>/dev/null | jq -r --arg re "$ACTIONABLE_TITLE_RE" \
        '.[] | select(.issue_type != "epic") | select(.title | test($re) | not) | "  \(.id)  \(.title)"' 2>/dev/null)
    [ -n "$backlog" ] || return 0
    echo ""
    echo "📌 Backlog left open (discovered work, not part of this plan):"
    echo "$backlog"
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
echo "Ticket label: ${TICKET:-<none>}"
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
    check_required_branch
    sweep_epics

    # Task detection: get counts (fallback to empty if beads not initialized)
    TASK_JSON=$(bd list --json 2>/dev/null || echo "[]")
    WORK_JSON=$(echo "$TASK_JSON" | jq --arg re "$ACTIONABLE_TITLE_RE" '[.[] | select(.title | test($re))]')
    TOTAL=$(echo "$WORK_JSON" | jq 'length')
    OPEN=$(echo "$WORK_JSON" | jq '[.[] | select(.status != "closed")] | length')
    READY=$(bd ready --json 2>/dev/null | jq 'length' 2>/dev/null || echo "0")

    if [ "$TOTAL" = "0" ] || [ -z "$TOTAL" ]; then
        # bd list --json only returns open issues; none is plan work, so the previous plan is done
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
            run_bootstrap
            AGENT_EXIT_CODE=$?
            protect_after
            label_run_issues

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
            run_bootstrap
            AGENT_EXIT_CODE=$?
            protect_after
            label_run_issues

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
        print_backlog

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
            run_verify
            VERIFY_EXIT=$?
            protect_after
            label_run_issues

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
    READY_TASKS=$(bd ready --json 2>/dev/null | jq --arg re "$ACTIONABLE_TITLE_RE" '[.[] | select(.title | test($re))] | length' 2>/dev/null || echo "0")

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

    if gate_iteration; then
        # Handled by a gate: no agent run this iteration.
        echo "0" >"$NO_PROGRESS_FILE"
        sleep $CHECK_INTERVAL
        continue
    fi

    protect_before
    invoke_agent "$PROMPT_FILE"
    AGENT_EXIT_CODE=$?
    [ "$PROMPT_FILE" != "$DO_TASK_FILE" ] && rm -f "$PROMPT_FILE"
    protect_after
    label_run_issues

    echo "---"

    TIMED_OUT=0
    if [ $AGENT_EXIT_CODE -ne 0 ]; then
        if [ $AGENT_EXIT_CODE -eq 124 ] && [ -s "$WATCHDOG_FIRED_FILE" ] && [ "$INTERRUPTED" -eq 0 ]; then
            # The watchdog killed a silent agent. That says nothing about the
            # work it did before (it may have finished its phase and not
            # exited, or be blocked in one long silent command), so judge the
            # turn by progress below instead of halting. Release the task it
            # had claimed so the next iteration can pick it up again.
            TIMED_OUT=1
            echo ""
            echo "⚠️  WATCHDOG TIMEOUT (exit code 124) — judging this turn by progress, not by exit code"
            release_orphaned_tasks
        else
            echo ""
            echo "════════════════════════════════════════"
            echo "❌ AGENT ERROR (exit code: $AGENT_EXIT_CODE)"
            echo "════════════════════════════════════════"
            echo ""
            bd list
            exit $AGENT_EXIT_CODE
        fi
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
        echo "⚠️  NO PROGRESS this iteration ($NO_PROGRESS/$MAX_NO_PROGRESS) — no commits, no edits, no task change"
        [ -s "$MALFORMED_TOOLCALL_FILE" ] && echo "    likely cause: malformed tool-call markup in agent output (tool call emitted as plain text)"

        # Release the stranded claim so the next iteration can re-attempt it
        # instead of dead-ending on a permanently in_progress task.
        release_orphaned_tasks

        if [ "$NO_PROGRESS" -ge "$MAX_NO_PROGRESS" ]; then
            echo ""
            echo "════════════════════════════════════════"
            echo "❌ HALTED - $NO_PROGRESS consecutive no-progress iterations"
            echo "════════════════════════════════════════"
            echo "The agent produced no work (no edits, no commits, no task closed)"
            echo "$NO_PROGRESS times in a row. This usually means the model cannot emit valid"
            echo "tool calls (common with some quantized local builds) or is stuck re-reading"
            echo "context."
            if [ "$TIMED_OUT" -eq 1 ]; then
                echo ""
                echo "The last turn was killed by the watchdog (silent for ${AGENT_TIMEOUT}s). A long command"
                echo "that prints nothing (a test run, a build) looks like a hang: raise AGENT_TIMEOUT"
                echo "or have the agent run it in the background and poll it."
            fi
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
