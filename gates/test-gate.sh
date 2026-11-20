#!/bin/bash
# test-gate.sh TASK_ID — handle a [test] task without the agent.
#
# Runs the project's tests (background + progress), writes the evidence log, then:
#   pass -> commits the Epic's files (JIRA-prefixed) and closes [test] and the Epic
#   fail -> creates the [impl] RETRY task with the last failure lines and closes [test]
#
# Exit codes:
#   0   handled (committed + closed, or turned into an [impl] RETRY)
#   10  not handled: the agent must take the task; why is appended to $GATE_CONTEXT_FILE
#   20  environment error (expired AWS token, Docker down, ...): the loop must halt
GATES_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common.sh
. "$GATES_DIR/common.sh"

TASK_ID=${1:?usage: test-gate.sh TASK_ID}
CONTEXT=${GATE_CONTEXT_FILE:-/tmp/ralph-gate-context.md}
EVID=${RALPH_EVIDENCE_DIR:-ralph-evidence}
MAX_RETRIES=${MAX_RETRIES:-2}
TIMEOUT=${TEST_GATE_TIMEOUT:-3600}
ENV_ERROR_RE='TokenRetrievalError|InvalidGrantException|ExpiredTokenException|Cannot connect to the Docker daemon|Is the docker daemon running|error: failed to (get|fetch|download)|Could not resolve host|Temporary failure in name resolution|otxb_build.py: (command )?not found|exit code 137|Killed$'

say() { echo "[GATE] $*"; }

# Hand the task to the agent, telling it what the gate already established.
fallback() {
    {
        echo "TEST GATE (run by the loop before you): not handled, you take the [test] task."
        echo "Reason: $1"
        [ -n "${2:-}" ] && printf '%s\n' "$2"
    } >>"$CONTEXT"
    say "falling back to the agent: $1"
    bd update "$TASK_ID" --status open >/dev/null 2>&1
    exit 10
}

# A failure of this gate -> [impl] RETRY task ($1 heading, $2 output); at MAX_RETRIES the agent takes over.
retry_or_fallback() {
    local heading="$1" output="$2" retry files
    retry=$(grep -oE '^RETRY:[ ]*[0-9]+' <<<"$desc" | head -n 1 | grep -oE '[0-9]+')
    retry=${retry:-0}
    if [ "$retry" -ge "$MAX_RETRIES" ]; then
        fallback "$heading and RETRY=$retry reached MAX_RETRIES=$MAX_RETRIES. The checks already ran: DO NOT run them again. Follow the Blocker procedure (BLOCKED task, close the Epic, BLOCKERS.md)." "OUTPUT:
$output"
    fi
    files=$(parse_file_list <<<"$desc")
    bd create "[impl] RETRY: $epic_title" --parent "$epic" --type task --priority 0 --json \
        --description "RETRY: $((retry + 1))

FILES MODIFIED:
$files

$heading:
$output

UNMET ACCEPTANCE CRITERIA:
Every criterion proven by what failed above. Re-read the acceptance criteria of the Epic's closed [impl] tasks (bd list --all).

FIX THE IMPLEMENTATION SO EVERY ACCEPTANCE CRITERION IS MET. DO NOT WEAKEN, SKIP OR DELETE TESTS." >/dev/null \
        || fallback "could not create the RETRY task"
    bd close "$TASK_ID" --reason "$heading; [impl] RETRY task created" >/dev/null 2>&1
    say "$heading: [impl] RETRY created (RETRY: $((retry + 1)))"
    exit 0
}

task=$(bd_task_json "$TASK_ID")
[ -n "$task" ] && [ "$task" != "null" ] || { say "cannot read task $TASK_ID"; exit 10; }
desc=$(jq -r '.description // ""' <<<"$task")
epic=$(jq -r '.parent // empty' <<<"$task")
[ -n "$epic" ] || fallback "task has no parent Epic"
epic_title=$(bd_task_json "$epic" | jq -r '.title // ""' | sed -E 's/^Epic:[ ]*//')

cmd=$(test_command) || fallback "AGENTS.md defines tests in a way the gate cannot run (add a 'RALPH_TEST_CMD: <command>' line to enable it)"

integrity=$("$GATES_DIR/test-integrity.sh")
if [ $? -ne 0 ]; then
    fallback "the test-integrity gate flagged changes to tests; judge them against the acceptance criteria before committing" "$integrity"
fi

bd update "$TASK_ID" --claim >/dev/null 2>&1 || fallback "could not claim $TASK_ID"

# --- static gate again: lint that survived [review] must not cost a 10-minute test run ---
if [ "${RALPH_STATIC_GATE_BEFORE_TESTS:-1}" = "1" ]; then
    lint_files=$(parse_file_list <<<"$desc" | grep -vE '^(ralph-evidence/|ACTION_PLAN|\.beads)' || true)
    if [ -n "$lint_files" ]; then
        # shellcheck disable=SC2086 # one path per word
        if ! lint_out=$(bash "$GATES_DIR/static-gate.sh" $lint_files); then
            retry_or_fallback "Static checks failed before running the tests" "$lint_out"
        fi
    fi
fi

# --- run the tests -----------------------------------------------------------
mkdir -p "$EVID"
full=$(mktemp /tmp/ralph-test-run-XXXXXX)
evidence="$EVID/${epic}-test-run.log"
say "running: $cmd (timeout ${TIMEOUT}s)"
start=$(date +%s)
if command -v timeout >/dev/null 2>&1; then
    timeout "$TIMEOUT" bash -c "$cmd" >"$full" 2>&1 &
else
    bash -c "$cmd" >"$full" 2>&1 &
fi
pid=$!
while kill -0 "$pid" 2>/dev/null; do
    sleep "${GATE_POLL_SECONDS:-30}"
    kill -0 "$pid" 2>/dev/null && say "tests running, $(($(date +%s) - start))s, $(wc -l <"$full" | tr -d ' ') log lines"
done
wait "$pid"
rc=$?
elapsed=$(($(date +%s) - start))
say "tests finished: exit $rc in ${elapsed}s"

{
    echo "# test gate: $cmd"
    echo "# task=$TASK_ID epic=$epic head=$(git rev-parse --short HEAD 2>/dev/null) exit=$rc elapsed=${elapsed}s $(date -u +%FT%TZ)"
    tail -n 300 "$full"
} >"$evidence"

if grep -Eq "$ENV_ERROR_RE" "$full"; then
    bd update "$TASK_ID" --status open >/dev/null 2>&1
    echo "$(grep -E "$ENV_ERROR_RE" "$full" | head -n 1)" >"${GATE_ENV_ERROR_FILE:-/tmp/ralph-gate-env-error}"
    say "environment error detected: $(cat "${GATE_ENV_ERROR_FILE:-/tmp/ralph-gate-env-error}")"
    exit 20
fi

# --- failure -> [impl] RETRY ---------------------------------------------------
if [ "$rc" -ne 0 ]; then
    if grep -n -m1 -E '^=+ FAILURES =+|short test summary info' "$full" >/dev/null 2>&1; then
        first=$(grep -n -m1 -E '^=+ FAILURES =+|short test summary info' "$full" | cut -d: -f1)
        excerpt=$(tail -n +"$first" "$full" | tail -n 100)
    else
        excerpt=$(tail -n 100 "$full")
    fi
    retry_or_fallback "TEST FAILURE (command: $cmd, exit $rc; full log: $evidence)" "$excerpt"
fi

# --- success -> commit + close ---------------------------------------------------
# Every test function named by a PENDING TEST row of the AC tables must exist (ids come as
# "path::Class::test_x", "path::test_x, ::test_y", with [params]... so match on the function name).
all_files=$(parse_file_list <<<"$desc" | grep -vE '^(ralph-evidence/|ACTION_PLAN|\.beads)' || true)
unproven=""
while IFS= read -r name; do
    [ -n "$name" ] || continue
    # shellcheck disable=SC2086 # one path per word
    if ! git grep -qE "def $name\b" -- '*.py' 2>/dev/null && ! { [ -n "$all_files" ] && grep -qsE "def $name\b" $all_files; }; then
        unproven="$unproven $name"
    fi
done < <(grep -E '^AC[0-9]+ \| PENDING \| TEST:' <<<"$desc" | sed -E 's/.*TEST://; s/ — .*//; s#[A-Za-z0-9_./-]+\.py##g' | grep -oE '[A-Za-z_][A-Za-z0-9_]*' | grep -E '^test_' | sort -u)
[ -z "$unproven" ] || fallback "tests passed (exit 0, evidence $evidence) but these PENDING test functions were not found in the repo:$unproven. DO NOT re-run the tests; update the AC table, then commit." ""

files=$(parse_file_list <<<"$desc" | grep -vE '^(ralph-evidence/|ACTION_PLAN|\.beads)' || true)
[ -n "$files" ] || fallback "tests passed (exit 0, evidence $evidence) but the [test] description lists no FILES to commit. DO NOT re-run the tests."
staged=()
while IFS= read -r f; do
    if [ -e "$f" ] || git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
        git add -A -- "$f" && staged+=("$f")
    fi
done <<<"$files"
if git diff --cached --quiet; then
    fallback "tests passed (exit 0, evidence $evidence) but nothing is staged for the listed files. DO NOT re-run the tests."
fi

type=test
for f in $(git diff --cached --name-only); do is_test_path "$f" || type=feat; done
tag=$(jira_tag)
desc_line=$(printf '%s' "$epic_title" | awk '{print tolower(substr($0,1,1)) substr($0,2)}' | head -c 100)
msg="${tag:+$tag }$type: $desc_line"
if ! commit_out=$(git commit -q -m "$msg" 2>&1); then
    fallback "tests passed (exit 0, evidence $evidence) but 'git commit' failed. DO NOT re-run the tests." "$commit_out"
fi
sha=$(git rev-parse --short HEAD)
leftover=$(git status --porcelain | grep -vE '^\?\?| (ACTION_PLAN|\.beads)' || true)

actable=$(grep -E '^AC[0-9]+ \|' <<<"$desc" | sed -E "s/\| PENDING \|/| MET     |/; s/TEST: ([^ ]+) — to run in \[test\]/TEST: \1 — passed in gate run (exit 0), evidence $evidence/")
bd close "$TASK_ID" --reason "Tests passed ($cmd, exit 0, ${elapsed}s). Evidence: $evidence. Commit: $sha ($msg).
AC TABLE:
$actable" >/dev/null 2>&1
open_siblings=$(bd list --all --json 2>/dev/null | jq --arg e "$epic" '[.[] | select(.parent == $e and .status != "closed")] | length')
if [ "${open_siblings:-1}" = "0" ]; then
    bd close "$epic" --reason "All tasks closed; committed as $sha" >/dev/null 2>&1
    say "Epic $epic closed"
fi
say "committed $sha: $msg"
[ -n "$leftover" ] && say "note: tracked files still modified after the commit (other in-flight work?):
$leftover"
exit 0
