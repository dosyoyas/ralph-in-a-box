#!/bin/bash
# test-gate.sh TASK_ID — handle a [test] task without the agent.
#
# Runs the project's tests (background + progress), writes the evidence log, then:
#   pass -> commits the Epic's files and closes [test] and the Epic
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
EVID=$(evidence_dir)
MAX_RETRIES=${MAX_RETRIES:-2}
TIMEOUT=${TEST_GATE_TIMEOUT:-3600}
ENV_ERROR_RE='TokenRetrievalError|InvalidGrantException|ExpiredTokenException|Cannot connect to the Docker daemon|Is the docker daemon running|error: failed to (get|fetch|download)|Could not resolve host|Temporary failure in name resolution|exit code 137|Killed$|INFRA ERROR'
[ -n "$ENV_ERROR_EXTRA" ] && ENV_ERROR_RE="$ENV_ERROR_RE|$ENV_ERROR_EXTRA" # from the optional gates/ext.sh
extra_env=$(ralph_conf RALPH_ENV_ERROR_PATTERN || true) # project-specific environment errors (regex)
[ -n "$extra_env" ] && ENV_ERROR_RE="$ENV_ERROR_RE|$extra_env"

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

branch_ok || fallback "the current branch '$(git branch --show-current)' is not the required one ($(ralph_conf RALPH_REQUIRE_BRANCH)); make NO commit, record 'BLOCKED: wrong branch' in BLOCKERS.md and end the task"

cmd=$(test_command) || fallback "the gate does not know how to run this project's tests (set 'RALPH_TEST_CMD: <command>' in the project profile or AGENTS.md; 'agent' means the agent runs them)"
if [[ "$cmd" == *"{package}"* ]]; then
    # one run per package: the first path component of the task's files (monorepo layout)
    pkgs=$(parse_file_list <<<"$desc" | filter_committable | awk -F/ 'NF > 1 {print $1}' | sort -u)
    [ -n "$pkgs" ] || fallback "RALPH_TEST_CMD uses {package} but the task's files name no package directory"
    joined=""
    for pkg in $pkgs; do joined="${joined:+$joined && }${cmd//\{package\}/$pkg}"; done
    cmd="$joined"
fi
if [[ "$cmd" == *"{modules}"* || "$cmd" == *"{test_files}"* ]]; then
    # {test_files}: the task's test files (.py) under RALPH_TEST_ROOT; {modules}: the same as dotted module names
    # relative to that root (what a unittest-style runner takes). Without any, the agent runs the tests: the whole
    # suite would be the only alternative and it is too slow to run unasked.
    root=$(ralph_conf RALPH_TEST_ROOT || true)
    root=${root%/}
    tfiles="" mods=""
    while IFS= read -r f; do
        is_test_path "$f" || continue
        case "$f" in *.py) ;; *) continue ;; esac
        if [ -n "$root" ]; then
            [[ "$f" == "$root"/* ]] || continue
            rel=${f#"$root"/}
        else
            rel=$f
        fi
        tfiles="$tfiles $f"
        rel=${rel%.py}
        mods="$mods ${rel//\//.}"
    done < <(parse_file_list <<<"$desc" | filter_committable)
    [ -n "$tfiles" ] || fallback "RALPH_TEST_CMD needs test files but the task lists none${root:+ under $root/}"
    cmd=${cmd//\{test_files\}/${tfiles# }}
    cmd=${cmd//\{modules\}/${mods# }}
fi

integrity=$("$GATES_DIR/test-integrity.sh")
if [ $? -ne 0 ]; then
    fallback "the test-integrity gate flagged changes to tests; judge them against the acceptance criteria before committing" "$integrity"
fi

bd update "$TASK_ID" --claim >/dev/null 2>&1 || fallback "could not claim $TASK_ID"

# --- static gate again: lint that survived [review] must not cost a 10-minute test run ---
static=$(static_mode)
if [ "$static" != "off" ] && [ "${RALPH_STATIC_GATE_BEFORE_TESTS:-1}" = "1" ]; then
    lint_files=$(parse_file_list <<<"$desc" | filter_committable)
    if [ -n "$lint_files" ]; then
        # shellcheck disable=SC2086 # one path per word
        if ! lint_out=$(bash "$GATES_DIR/static-gate.sh" $lint_files); then
            if [ "$static" = "advisory" ]; then
                say "static checks reported findings (RALPH_STATIC_GATE=advisory, not blocking)"
            else
                retry_or_fallback "Static checks failed before running the tests" "$lint_out"
            fi
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
# Some runners exit 0 when nothing ran ("Ran 0 tests"): RALPH_TEST_FAIL_PATTERN marks such output as a failure.
fail_re=$(ralph_conf RALPH_TEST_FAIL_PATTERN || true)
if [ "$rc" -eq 0 ] && [ -n "$fail_re" ] && grep -Eq "$fail_re" "$full"; then
    say "the output matches RALPH_TEST_FAIL_PATTERN ($fail_re): the run counts as failed"
    rc=1
fi

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
# Every test named by a PENDING TEST row of the AC tables must exist. Ids come in many shapes
# ("path::Class::test_x", "path::test_x, ::test_y", "pkg.mod.TestX.test_y", "pkg.mod.test_mod" for a whole module,
# "test_x[param]"), so look at the last segment: a module name is checked as a file, anything else as `def name`.
all_files=$(parse_file_list <<<"$desc" | filter_committable)
unproven=""
while IFS= read -r tok; do
    tok=${tok%%\[*}
    last=${tok##*[.:]}
    case "$last" in test_*) ;; *) continue ;; esac
    if [[ "$tok" != *::* && "$tok" == *.* ]] \
        && [ -n "$(git ls-files -co --exclude-standard -- "*/$last.py" "$last.py" 2>/dev/null | head -n 1)" ]; then
        continue # a dotted module id, e.g. otxapi.noc.tests.test_queries
    fi
    # shellcheck disable=SC2086 # one path per word
    if ! git grep -qE "def $last\b" -- '*.py' 2>/dev/null && ! { [ -n "$all_files" ] && grep -qsE "def $last\b" $all_files; }; then
        unproven="$unproven $last"
    fi
done < <(grep -E '^AC[0-9]+ \| PENDING \| TEST:' <<<"$desc" | sed -E 's/.*TEST://; s/ — .*//' | tr -s ', ' '\n\n' | sed '/^$/d')
[ -z "$unproven" ] || fallback "tests passed (exit 0, evidence $evidence) but these PENDING test functions were not found in the repo:$unproven. DO NOT re-run the tests; update the AC table, then commit." ""

files=$(parse_file_list <<<"$desc" | filter_committable)
skipped=$(parse_file_list <<<"$desc" | while IFS= read -r f; do is_no_commit "$f" && echo "$f"; done)
[ -z "$skipped" ] || say "never committed (evidence / plans / RALPH_NO_COMMIT): $(echo $skipped)"
[ -n "$files" ] || fallback "tests passed (exit 0, evidence $evidence) but the [test] description lists no FILES to commit. DO NOT re-run the tests."
staged=()
while IFS= read -r f; do
    if [ -e "$f" ] || git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
        git add -- "$f" && staged+=("$f")
    fi
done <<<"$files"
if git diff --cached --quiet; then
    fallback "tests passed (exit 0, evidence $evidence) but nothing is staged for the listed files. DO NOT re-run the tests."
fi

type=test
for f in $(git diff --cached --name-only); do is_test_path "$f" || type=feat; done
RALPH_FEATURE_TAG=$(epic_tag "$epic")
export RALPH_FEATURE_TAG
tag=$(commit_prefix)
title_for_msg=$epic_title
# the plan title often carries the tag in a suffix ("... (ticket X)"): it is already the prefix, do not repeat it
[ -n "$RALPH_FEATURE_TAG" ] && title_for_msg=${title_for_msg%%' ('*"$RALPH_FEATURE_TAG"*')'}
desc_line=$(printf '%s' "$title_for_msg" | awk '{print tolower(substr($0,1,1)) substr($0,2)}' | head -c 100)
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
