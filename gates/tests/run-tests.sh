#!/bin/bash
# Tests for the ralph gates. Needs git, jq, python3 and bd (real, on temp repos); no Docker, no AWS, no agent.
# Usage: gates/tests/run-tests.sh
GATES=$(cd "$(dirname "$0")/.." && pwd)
for tool in git jq python3 bd; do
    command -v "$tool" >/dev/null || { echo "SKIP: $tool not installed"; exit 0; }
done

pass=0 fail=0 TMP=$(mktemp -d /tmp/ralph-gates-test-XXXXXX)
trap 'rm -rf "$TMP"' EXIT
export RALPH_NO_EXT=1 # the core tests run without gates/ext.sh; the extension tests (below) turn it back on
export GATE_POLL_SECONDS=0 GATE_CONTEXT_FILE="$TMP/context.md" GATE_ENV_ERROR_FILE="$TMP/env-error"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

ok() { pass=$((pass + 1)); echo "  ok   $1"; }
ko() { fail=$((fail + 1)); echo "  FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/       /'; }
check() { # description command...
    local d="$1"
    shift
    if "$@"; then ok "$d"; else ko "$d"; fi
}
eq() { [ "$1" = "$2" ]; }

new_repo() { # name -> cd into a fresh git repo with beads
    local d="$TMP/$1"
    rm -rf "$d" && mkdir -p "$d" && cd "$d" || exit 1
    git init -q . && echo base >base.txt && git add -A && git commit -q -m base
    bd init --stealth -p t >/dev/null 2>&1
    export RALPH_EVIDENCE_DIR="$d/ralph-evidence"
}
mk() { bd create "$@" --json | jq -r 'if type=="array" then .[0].id else .id end'; }

PLAN='# Plan

Overview constraint: no prod changes.

## Shared context for every deliverable
Use pytest only.

## Feature 1: Core
### Add parser
**Blocked by:** None — can start immediately.

Parse things.
1. step one
2. step two

**Acceptance criteria:**
- [ ] parses a
- [ ] parses b
  with continuation

### Add printer
**Blocked by:** Add parser

Print things.

**Acceptance criteria:**
- [ ] prints a

## Feature 2: CLI
### Add CLI
**Blocked by:** Add printer

CLI.

**Acceptance criteria:**
- [ ] runs
'

echo "bootstrap_plan.py"
new_repo boot
printf '%s' "$PLAN" >ACTION_PLAN.md
python3 "$GATES/bootstrap_plan.py" >/dev/null 2>&1
check "creates epics and impl tasks (no audit by default)" eq "$(bd list --all --json | jq 'length')" 5
check "titles use [impl] prefix" eq "$(bd list --all --json | jq '[.[] | select(.title | startswith("[impl] "))] | length')" 3
desc=$(bd list --all --json | jq -r '.[] | select(.title == "[impl] Add parser") | .description')
check "copies numbered steps verbatim" grep -q '2. step two' <<<"$desc"
check "numbers acceptance criteria (with continuation)" grep -q 'AC2: parses b with continuation' <<<"$desc"
check "copies shared context into the task" grep -q 'Use pytest only' <<<"$desc"
check "copies the plan overview into the task" grep -q 'Overview constraint: no prod changes' <<<"$desc"
check "only the first impl is ready (plus epics)" eq "$(bd ready --json | jq '[.[] | select(.title | test("^\\[(impl|audit)\\]"))] | length')" 1
new_repo withaudit
printf '%s' "$PLAN" >ACTION_PLAN.md
RALPH_AUDIT=1 python3 "$GATES/bootstrap_plan.py" >/dev/null 2>&1
check "RALPH_AUDIT=1 adds the audit epic and task" eq "$(bd list --all --json | jq 'length')" 7
check "the audit task is blocked until every impl is done" eq "$(bd ready --json | jq '[.[] | select(.title | startswith("[audit]"))] | length')" 0
new_repo bad
printf '# Plan\n\nJust prose, no features.\n' >ACTION_PLAN.md
python3 "$GATES/bootstrap_plan.py" >/dev/null 2>&1
check "unparseable plan exits 2" eq "$?" 2
check "unparseable plan creates nothing" eq "$(bd list --all --json | jq 'length')" 0
printf '## Feature 1: X\n### D\n**Blocked by:** Nonexistent thing\n\nbody\n\n- [ ] ok\n' >ACTION_PLAN.md
python3 "$GATES/bootstrap_plan.py" >/dev/null 2>&1
check "unresolvable Blocked by exits 2" eq "$?" 2

new_repo tagged
printf '%s\n' '## Feature 1: First (ticket TK-12)' '### One' '**Blocked by:** None' '' 'x' '' '- [ ] a' '' '## Feature 2: Second' '### Two' '**Blocked by:** None' '' 'see TK-3003' '' '- [ ] b' >ACTION_PLAN.md
RALPH_FEATURE_TAG_RE='TK-[0-9]+' python3 "$GATES/bootstrap_plan.py" >/dev/null 2>&1
epic1=$(bd list --all --json | jq -r '.[] | select(.title | startswith("Epic: First")) | .description // ""')
epic2=$(bd list --all --json | jq -r '.[] | select(.title | startswith("Epic: Second")) | .description // ""')
check "RALPH_FEATURE_TAG_RE stores the tag of the Feature title on its Epic" eq "$epic1" "TAG: TK-12"
check "a Feature title without a match gets no tag" eq "$epic2" ""
new_repo untagged
printf '%s\n' '## Feature 1: First (ticket TK-12)' '### One' '**Blocked by:** None' '' 'x' '' '- [ ] a' >ACTION_PLAN.md
python3 "$GATES/bootstrap_plan.py" >/dev/null 2>&1
check "without RALPH_FEATURE_TAG_RE no tag is stored" eq "$(bd list --all --json | jq -r '.[] | select(.title | startswith("Epic: First")) | .description // ""')" ""

echo "bootstrap_plan.py --check (parse check: no beads, no git, no agent)"
BP="$GATES/bootstrap_plan.py"
PY=$(command -v python3)
CHK="$TMP/chk"; rm -rf "$CHK"; mkdir -p "$CHK" && cd "$CHK" # a plain directory: no git repo, no .beads
printf '%s' "$PLAN" >ACTION_PLAN.md
cp ACTION_PLAN.md before.md
out=$(env PATH=/nonexistent "$PY" "$BP" --check ACTION_PLAN.md 2>&1); rc=$?
check "a well-formed plan passes the check (exit 0), with no bd and no git available" eq "$rc" 0
check "the check reports what it found" grep -q '3 deliverables' <<<"$out"
check "the check creates no .beads directory" bash -c '[ ! -e .beads ]'
check "the check archives nothing and leaves the plan untouched" bash -c '[ -z "$(ls ACTION_PLAN_*.md 2>/dev/null)" ] && cmp -s ACTION_PLAN.md before.md'
env PATH=/nonexistent "$PY" "$BP" --check >/dev/null 2>&1
check "without a path the check reads ACTION_PLAN.md" eq "$?" 0
printf '## Feature 1: X\n### D\n**Blocked by:** Nonexistent thing\n\nbody\n\n- [ ] ok\n' >ACTION_PLAN.md
out=$("$PY" "$BP" --check ACTION_PLAN.md 2>&1); rc=$?
check "a Blocked by that names no deliverable fails the check" bash -c '[ "$1" -ne 0 ]' _ "$rc"
check "the message names the unknown blocker" grep -q 'Nonexistent thing' <<<"$out"
printf '## Feature 1: X\n### Lonely deliverable\n**Blocked by:** None\n\nbody without criteria\n' >ACTION_PLAN.md
out=$("$PY" "$BP" --check ACTION_PLAN.md 2>&1); rc=$?
check "a deliverable without criteria fails the check" bash -c '[ "$1" -ne 0 ]' _ "$rc"
check "the message names the deliverable" grep -q 'Lonely deliverable' <<<"$out"
printf '# Plan\n\nJust prose.\n' >ACTION_PLAN.md
"$PY" "$BP" --check ACTION_PLAN.md >/dev/null 2>&1
check "a plan with no features fails the check" bash -c '[ "$1" -ne 0 ]' _ "$?"
"$PY" "$BP" --check missing.md >/dev/null 2>&1
check "a missing file fails the check" bash -c '[ "$1" -ne 0 ]' _ "$?"
check "the check never creates a beads dir even after failures" bash -c '[ ! -e .beads ]'
new_repo chkboot
printf '%s' "$PLAN" >ACTION_PLAN.md
"$PY" "$BP" --check ACTION_PLAN.md >/dev/null 2>&1
check "check on a repo with beads creates no task" eq "$(bd list --all --json | jq 'length')" 0
python3 "$BP" ACTION_PLAN.md >/dev/null 2>&1
check "a plan the check accepts is bootstrapped by the script (exit 0, tasks created)" eq "$? $(bd list --all --json | jq 'length')" "0 5"

echo "next-task.sh"
new_repo next
printf '%s' "$PLAN" >ACTION_PLAN.md
python3 "$GATES/bootstrap_plan.py" >/dev/null 2>&1
first=$(bash "$GATES/next-task.sh" | jq -r .title)
check "picks the first ready task" eq "$first" "[impl] Add parser"
id=$(bd list --all --json | jq -r '.[] | select(.title == "[impl] Add parser") | .id')
bd close "$id" --reason done >/dev/null 2>&1
check "next task follows the dependency" eq "$(bash "$GATES/next-task.sh" | jq -r .title)" "[impl] Add printer"

echo "test-integrity.sh"
new_repo integ
mkdir tests && printf 'def test_a():\n    assert f() == 1\n' >tests/test_a.py && git add -A && git commit -q -m t
printf 'def test_a():\n    assert f() == 1\n\n\ndef test_b():\n    assert g() == 2\n' >tests/test_a.py
bash "$GATES/test-integrity.sh" >/dev/null
check "adding a test is fine" eq "$?" 0
printf 'def test_a():\n    assert f()\n' >tests/test_a.py
out=$(bash "$GATES/test-integrity.sh")
check "a changed assertion is flagged" eq "$?" 1
check "report names the file" grep -q 'tests/test_a.py' <<<"$out"
printf 'import pytest\n\n@pytest.mark.skip\ndef test_a():\n    assert f() == 1\n' >tests/test_a.py
bash "$GATES/test-integrity.sh" >/dev/null
check "an added skip is flagged" eq "$?" 1
git checkout -q -- tests/test_a.py && git rm -q tests/test_a.py
bash "$GATES/test-integrity.sh" >/dev/null
check "a deleted test file is flagged" eq "$?" 1

echo "static-gate.sh (stub linters)"
new_repo static
mkdir stubs
printf '#!/bin/bash\nexit 0\n' >stubs/ruff
printf '#!/bin/bash\nexit 0\n' >stubs/gitleaks
chmod +x stubs/*
echo 'x = 1' >a.py
out=$(PATH="$PWD/stubs:$PATH" bash "$GATES/static-gate.sh" a.py)
check "passes when every check passes" eq "$?" 0
check "reports PASS lines" grep -q 'PASS ruff check' <<<"$out"
printf '#!/bin/bash\necho "a.py:1: E999 boom"\nexit 1\n' >stubs/ruff
out=$(PATH="$PWD/stubs:$PATH" bash "$GATES/static-gate.sh" a.py)
check "fails when a check fails" eq "$?" 1
check "includes the failure output" grep -q 'E999 boom' <<<"$out"

echo "test-gate.sh"
# Linters are not under test here: stubs that pass (a failing ruff is injected in one case below).
STUBS="$TMP/stubs"
mkdir -p "$STUBS" && for t in ruff pyrefly biome gitleaks; do printf '#!/bin/bash\nexit 0\n' >"$STUBS/$t"; done
chmod +x "$STUBS"/*
export PATH="$STUBS:$PATH"
setup_test_task() { # -> sets TID EID ; one Epic with a closed [impl] and an open [test] listing tests/test_a.py
    new_repo "$1"
    mkdir tests && echo 'class TestX:
    def test_a(self): pass' >tests/test_a.py
    EID=$(mk "Epic: Add parser" --type epic --priority 0)
    IID=$(mk "[impl] Add parser" --parent "$EID" --type task --priority 0 --description x)
    bd close "$IID" --reason impl >/dev/null 2>&1
    TID=$(mk "[test] Test: Add parser" --parent "$EID" --type task --priority 0 --description "FILES:
- tests/test_a.py

SUMMARY:
parser

RETRY: ${2:-0}")
    git checkout -q -b feature/work-x
}
setup_test_task gate_pass
RALPH_TEST_CMD='echo "3 passed"; exit 0' bash "$GATES/test-gate.sh" "$TID" >"$TMP/out.txt" 2>&1
check "passing tests exit 0" eq "$?" 0
check "commits the listed files (no prefix by default)" eq "$(git log -1 --format=%s)" "test: add parser"
check "closes the [test] task" eq "$(bd show "$TID" --json | jq -r 'if type=="array" then .[0].status else .status end')" closed
check "closes the Epic when nothing else is open" eq "$(bd show "$EID" --json | jq -r 'if type=="array" then .[0].status else .status end')" closed
check "writes the evidence log" test -s "$RALPH_EVIDENCE_DIR/${EID}-test-run.log"

setup_test_task gate_feature_tag
bd update "$EID" --description "TAG: TK-5" >/dev/null 2>&1
RALPH_TEST_CMD='echo ok' bash "$GATES/test-gate.sh" "$TID" >"$TMP/out.txt" 2>&1
check "the Feature tag prefixes the commit message" eq "$(git log -1 --format=%s)" "TK-5 test: add parser"
setup_test_task gate_tag_in_title
bd update "$EID" --title "Epic: Add parser (ticket TK-6)" --description "TAG: TK-6" >/dev/null 2>&1
RALPH_TEST_CMD='echo ok' bash "$GATES/test-gate.sh" "$TID" >"$TMP/out.txt" 2>&1
check "the tag is not repeated in the message when the Feature title carries it" eq "$(git log -1 --format=%s)" "TK-6 test: add parser"

setup_test_task gate_modules
mkdir -p python/pkg/tests && echo 'x = 1' >python/pkg/m.py && printf 'class T:\n    def test_x(self): pass\n' >python/pkg/tests/test_m.py && echo 'y = 1' >other_test.py
bd update "$TID" --description "FILES:
- python/pkg/m.py
- python/pkg/tests/test_m.py
- other_test.py

RETRY: 0" >/dev/null 2>&1
RALPH_TEST_ROOT=python RALPH_TEST_CMD="echo mods={modules} files={test_files} >$TMP/mods.txt" bash "$GATES/test-gate.sh" "$TID" >"$TMP/out.txt" 2>&1
check "{modules} / {test_files} come from the task's test files under RALPH_TEST_ROOT (exit 0)" eq "$?" 0
check "dotted modules are relative to the root, files are not" eq "$(cat "$TMP/mods.txt")" "mods=pkg.tests.test_m files=python/pkg/tests/test_m.py"
setup_test_task gate_no_modules
: >"$GATE_CONTEXT_FILE"
RALPH_TEST_ROOT=python RALPH_TEST_CMD='echo {modules}' bash "$GATES/test-gate.sh" "$TID" >"$TMP/out.txt" 2>&1
check "{modules} without test files under the root hands the task to the agent (exit 10)" eq "$?" 10
setup_test_task gate_zero_tests
RALPH_TEST_FAIL_PATTERN='Ran 0 tests' RALPH_TEST_CMD='echo "Ran 0 tests"; exit 0' bash "$GATES/test-gate.sh" "$TID" >"$TMP/out.txt" 2>&1
check "RALPH_TEST_FAIL_PATTERN turns an exit-0 run into a failure (RETRY created)" eq "$(bd list --all --json | jq '[.[] | select(.title | startswith("[impl] RETRY"))] | length')" 1

setup_test_task gate_nested_ids
mkdir -p src/test/tests && git mv -f tests/test_a.py src/test/tests/test_a.py 2>/dev/null || mv tests/test_a.py src/test/tests/test_a.py
bd update "$TID" --description "FILES:
- src/test/tests/test_a.py

AC TABLE:
AC1 | PENDING | TEST: tests/test_a.py::TestX::test_a — to run in [test]

RETRY: 0" >/dev/null 2>&1
RALPH_TEST_CMD='echo ok' bash "$GATES/test-gate.sh" "$TID" >"$TMP/out.txt" 2>&1
check "PENDING test ids relative to a tests dir are resolved (exit 0)" eq "$?" 0
check "nested ids: the commit happened" eq "$(git log --oneline | wc -l | tr -d ' ')" 2

setup_test_task gate_loose_ids
printf 'def test_one(): pass\n\n\ndef test_two(): pass\n' >tests/test_a.py
bd update "$TID" --description "FILES:
- tests/test_a.py

AC TABLE:
AC1 | PENDING | TEST: tests/test_a.py::test_one, ::test_two — to run in [test]

RETRY: 0" >/dev/null 2>&1
RALPH_TEST_CMD='echo ok' bash "$GATES/test-gate.sh" "$TID" >"$TMP/out.txt" 2>&1
check "ids with commas and ::shorthand are matched by function name (exit 0)" eq "$?" 0
check "loose ids: the commit happened" eq "$(git log --oneline | wc -l | tr -d ' ')" 2
setup_test_task gate_missing_test
bd update "$TID" --description "FILES:
- tests/test_a.py

AC TABLE:
AC1 | PENDING | TEST: tests/test_a.py::test_does_not_exist — to run in [test]

RETRY: 0" >/dev/null 2>&1
RALPH_TEST_CMD='echo ok' bash "$GATES/test-gate.sh" "$TID" >"$TMP/out.txt" 2>&1
check "a PENDING test that does not exist is only a note (the green run is committed, exit 0)" eq "$?" 0
check "the commit happened" eq "$(git log --oneline | wc -l | tr -d ' ')" 2
check "the close reason names the id that could not be matched" grep -q 'test_does_not_exist' <(bd show "$TID" --json | jq -r 'if type=="array" then .[0].close_reason else .close_reason end')

setup_test_task gate_noisy_ids
printf 'class TestX:\n    def test_alpha(self): pass\n    def test_beta(self): pass\n' >tests/test_a.py
bd update "$TID" --description "FILES:
- tests/test_a.py

AC TABLE:
AC1 | PENDING | TEST: test_a (35 OK in the retry run), test_alpha; STATIC x.py:3 — to run in [test]
AC2 | PENDING | TEST: tests.test_a.TestX.test_beta;
AC3 | PENDING | TEST: same test (unchanged) / test_alpha

RETRY: 0" >/dev/null 2>&1
RALPH_TEST_CMD='echo ok' bash "$GATES/test-gate.sh" "$TID" >"$TMP/out.txt" 2>&1
check "bare module names, punctuation and prose in ids resolve (exit 0)" eq "$?" 0
check "and nothing is reported as unmatched" bash -c '! grep -q "Not matched by name" <<<"$1"' _ "$(bd show "$TID" --json | jq -r 'if type=="array" then .[0].close_reason else .close_reason end')"

setup_test_task gate_fail
RALPH_TEST_CMD='echo "FAILED test_a - assert 1 == 2"; exit 1' bash "$GATES/test-gate.sh" "$TID" >"$TMP/out.txt" 2>&1
check "failing tests are handled (exit 0)" eq "$?" 0
check "creates an [impl] RETRY task" eq "$(bd list --all --json | jq '[.[] | select(.title | startswith("[impl] RETRY"))] | length')" 1
retry_desc=$(bd list --all --json | jq -r '.[] | select(.title | startswith("[impl] RETRY")) | .description')
check "RETRY task carries RETRY: 1" grep -q '^RETRY: 1' <<<"$retry_desc"
check "RETRY task carries the failure output" grep -q '^FAILED test_a - assert 1 == 2' <<<"$retry_desc"
check "nothing is committed on failure" eq "$(git log --oneline | wc -l | tr -d ' ')" 1

setup_test_task gate_lint
echo 'x = 1' >tests/test_b.py
bd update "$TID" --description "FILES:
- tests/test_b.py

RETRY: 0" >/dev/null 2>&1
printf '#!/bin/bash\necho "tests/test_b.py:1: F401 unused"\nexit 1\n' >"$STUBS/ruff"
RALPH_TEST_CMD="touch $TMP/tests-ran" bash "$GATES/test-gate.sh" "$TID" >"$TMP/out.txt" 2>&1
check "lint failure before tests is handled (exit 0)" eq "$?" 0
check "the tests were not run" test ! -e "$TMP/tests-ran"
check "an [impl] RETRY carries the lint output" grep -q 'F401 unused' <(bd list --all --json | jq -r '.[] | select(.title | startswith("[impl] RETRY")) | .description')
printf '#!/bin/bash\nexit 0\n' >"$STUBS/ruff"

setup_test_task gate_pkg
mkdir -p pkg-a pkg-b && echo 'def test_a(): pass' >pkg-a/test_a.py && echo 'def test_b(): pass' >pkg-b/test_b.py
bd update "$TID" --description "FILES:
- pkg-a/test_a.py
- pkg-b/test_b.py

RETRY: 0" >/dev/null 2>&1
RALPH_TEST_CMD="echo run {package} >>$TMP/pkg-runs" bash "$GATES/test-gate.sh" "$TID" >"$TMP/out.txt" 2>&1
check "{package} runs the command once per package (exit 0)" eq "$?" 0
check "both packages were run" eq "$(sort "$TMP/pkg-runs" | tr '\n' ' ')" "run pkg-a run pkg-b "
rm -f "$TMP/pkg-runs"
setup_test_task gate_nocommit
mkdir -p triage-logs && echo log >triage-logs/run.log && echo 'def test_a(): pass' >tests/test_a.py
bd update "$TID" --description "FILES:
- tests/test_a.py
- triage-logs/run.log

RETRY: 0" >/dev/null 2>&1
printf 'RALPH_NO_COMMIT: triage-logs/\n' >AGENTS.md
RALPH_TEST_CMD='echo ok' bash "$GATES/test-gate.sh" "$TID" >"$TMP/out.txt" 2>&1
check "files under RALPH_NO_COMMIT are not committed" eq "$(git show --name-only --format= HEAD | tr '\n' ' ')" "tests/test_a.py "
setup_test_task gate_delete
mkdir -p src && echo 'x = 1' >src/old.py && git add -A && git commit -q -m old && rm src/old.py
bd update "$TID" --description "FILES:
- src/old.py

RETRY: 0" >/dev/null 2>&1
RALPH_TEST_CMD='echo ok' bash "$GATES/test-gate.sh" "$TID" >"$TMP/out.txt" 2>&1
check "a deleted file is committed without git add -A" eq "$(git show --name-status --format= HEAD | tr '\t' ' ')" "D src/old.py"
setup_test_task gate_dotted
printf 'class TestQ:\n    def test_hours(self): pass\n' >tests/test_queries.py
bd update "$TID" --description "FILES:
- tests/test_queries.py

AC TABLE:
AC1 | PENDING | TEST: otxapi.noc.tests.test_queries.TestQ.test_hours — to run in [test]
AC2 | PENDING | TEST: otxapi.noc.tests.test_queries — to run in [test]

RETRY: 0" >/dev/null 2>&1
RALPH_TEST_CMD='echo ok' bash "$GATES/test-gate.sh" "$TID" >"$TMP/out.txt" 2>&1
rc_dotted=$?
check "dotted unittest ids (function and whole module) are accepted" eq "$rc_dotted" 0
[ "$rc_dotted" -eq 0 ] || sed 's/^/       /' "$TMP/out.txt" | tail -5
setup_test_task gate_infra
RALPH_TEST_CMD='echo "INFRA ERROR: pip install of test requirements failed"; exit 3' bash "$GATES/test-gate.sh" "$TID" >"$TMP/out.txt" 2>&1
check "INFRA ERROR is an environment error (exit 20)" eq "$?" 20
setup_test_task gate_advisory
echo 'x = 1' >tests/test_b.py
bd update "$TID" --description "FILES:
- tests/test_b.py

RETRY: 0" >/dev/null 2>&1
printf '#!/bin/bash\necho "F401"\nexit 1\n' >"$STUBS/ruff"
RALPH_STATIC_GATE=advisory RALPH_TEST_CMD='echo ok' bash "$GATES/test-gate.sh" "$TID" >"$TMP/out.txt" 2>&1
check "RALPH_STATIC_GATE=advisory does not block (exit 0, committed)" eq "$(git log --oneline | wc -l | tr -d ' ')" 2
printf '#!/bin/bash\nexit 0\n' >"$STUBS/ruff"
setup_test_task gate_branch
printf 'RALPH_REQUIRE_BRANCH: release-[0-9]+\n' >AGENTS.md
: >"$GATE_CONTEXT_FILE"
RALPH_TEST_CMD='echo ok' bash "$GATES/test-gate.sh" "$TID" >"$TMP/out.txt" 2>&1
check "a wrong branch hands the task back to the agent (exit 10)" eq "$?" 10
check "and nothing is committed" eq "$(git log --oneline | wc -l | tr -d ' ')" 1

setup_test_task gate_maxretry 2
: >"$GATE_CONTEXT_FILE"
RALPH_TEST_CMD='echo boom; exit 1' bash "$GATES/test-gate.sh" "$TID" >"$TMP/out.txt" 2>&1
check "RETRY at the limit falls back to the agent (exit 10)" eq "$?" 10
check "fallback context says not to re-run the tests" grep -q 'DO NOT run them again' "$GATE_CONTEXT_FILE"

setup_test_task gate_env
RALPH_TEST_CMD='echo "botocore.exceptions.TokenRetrievalError: token expired"; exit 1' bash "$GATES/test-gate.sh" "$TID" >"$TMP/out.txt" 2>&1
check "environment errors exit 20" eq "$?" 20
check "the task is released" eq "$(bd show "$TID" --json | jq -r 'if type=="array" then .[0].status else .status end')" open

setup_test_task gate_unknown
printf '# Agents\n## Testing\nUse make magic.\n' >AGENTS.md
env -u RALPH_TEST_CMD bash "$GATES/test-gate.sh" "$TID" >"$TMP/out.txt" 2>&1
check "unknown test setup falls back to the agent (exit 10)" eq "$?" 10

setup_test_task gate_integrity
git checkout -q main 2>/dev/null || git checkout -q master
git checkout -q feature/work-x
printf 'def test_a():\n    assert 1 == 1\n' >tests/test_a.py && git add -A && git commit -q -m seed
printf 'def test_a():\n    pass\n' >tests/test_a.py
: >"$GATE_CONTEXT_FILE"
RALPH_TEST_CMD='exit 0' bash "$GATES/test-gate.sh" "$TID" >"$TMP/out.txt" 2>&1
check "weakened tests fall back to the agent (exit 10)" eq "$?" 10
check "context lists the finding" grep -q 'REMOVED/CHANGED assertion' "$GATE_CONTEXT_FILE"

echo "integrity gate scope and the Epic sweeper"
new_repo scope
mkdir tests && printf 'def test_a():\n    assert f() == 1\n' >tests/test_a.py && printf 'def test_b():\n    assert g() == 2\n' >tests/test_b.py && git add -A && git commit -q -m t
printf 'def test_a():\n    pass\n' >tests/test_a.py
bash "$GATES/test-integrity.sh" >/dev/null
check "without paths the whole tree is checked (a weakened test is flagged)" eq "$?" 1
bash "$GATES/test-integrity.sh" tests/test_b.py >/dev/null
check "with paths only those files are judged (another Epic's edit does not block)" eq "$?" 0
bash "$GATES/test-integrity.sh" tests/test_a.py >/dev/null
check "a listed file that was weakened is still flagged" eq "$?" 1

setup_test_task gate_scope
printf 'def test_other():\n    assert 1 == 1\n' >tests/test_other.py && git add tests/test_other.py && git commit -q -m seed
printf 'def test_other():\n    pass\n' >tests/test_other.py   # another Epic's uncommitted edit, not in this task
RALPH_TEST_CMD='echo ok' bash "$GATES/test-gate.sh" "$TID" >"$TMP/out.txt" 2>&1
check "another Epic's weakened test does not hand this task to the agent (exit 0)" eq "$?" 0
check "and it is not swept into this commit" eq "$(git show --name-only --format= HEAD | tr '\n' ' ')" "tests/test_a.py "

new_repo sweep
sw() { bash "$GATES/epic-sweep.sh" 2>&1; }
E1=$(mk "Epic: Stuck" --type epic --priority 0)
I1=$(mk "[impl] Thing" --parent "$E1" --type task --priority 0 --description x)
bd update "$I1" --notes "FILES MODIFIED: src/a.py, tests/test_a.py" >/dev/null 2>&1
bd close "$I1" --reason done >/dev/null 2>&1
R1=$(mk "[impl] RETRY: Stuck" --parent "$E1" --type task --priority 0 --description x)
bd update "$R1" --notes "FILES MODIFIED: src/a.py" >/dev/null 2>&1
bd close "$R1" --reason fixed >/dev/null 2>&1
E2=$(mk "Epic: Healthy" --type epic --priority 1)
I2=$(mk "[impl] Other" --parent "$E2" --type task --priority 0 --description x)
bd close "$I2" --reason done >/dev/null 2>&1
mk "[review] Review: Healthy" --parent "$E2" --type task --priority 0 --description x >/dev/null
E3=$(mk "Epic: Tested" --type epic --priority 2)
I3=$(mk "[impl] Done" --parent "$E3" --type task --priority 0 --description x)
bd close "$I3" --reason done >/dev/null 2>&1
T3=$(mk "[test] Test: Tested" --parent "$E3" --type task --priority 0 --description x)
bd close "$T3" --reason done >/dev/null 2>&1
out=$(sw)
check "the sweeper reports the stuck Epic" grep -q "Epic $E1" <<<"$out"
reviews=$(bd list --all --json | jq -r --arg e "$E1" '[.[] | select(.parent == $e and (.title | startswith("[review]")))] | length')
check "it creates exactly one [review] for the stuck Epic" eq "$reviews" 1
check "the new [review] lists the files of the Epic's [impl] notes" grep -q 'src/a.py' <(bd list --all --json | jq -r --arg e "$E1" '.[] | select(.parent == $e and (.title | startswith("[review]"))) | .description')
check "an Epic that already has an open [review] is left alone" eq "$(bd list --all --json | jq -r --arg e "$E2" '[.[] | select(.parent == $e)] | length')" 2
check "an Epic whose last closed task is a [test] is left alone" eq "$(bd list --all --json | jq -r --arg e "$E3" '[.[] | select(.parent == $e)] | length')" 2
sw >/dev/null
check "a second sweep creates nothing more" eq "$(bd list --all --json | jq -r --arg e "$E1" '[.[] | select(.parent == $e and (.title | startswith("[review]")))] | length')" 1

echo "static-gate.sh: secrets are scanned on the changed files only"
new_repo leaks
echo 'x = 1' >a.py && echo 'y = 2' >b.py
printf '#!/bin/bash\necho "$*" >>"$STUBS_LOG"\nexit 0\n' >"$STUBS/gitleaks"
export STUBS_LOG="$TMP/gitleaks.log"; : >"$STUBS_LOG"
out=$(bash "$GATES/static-gate.sh" a.py b.py)
check "gitleaks runs without git history (--no-git)" grep -q -- '--no-git' "$STUBS_LOG"
check "once per changed file" eq "$(wc -l <"$STUBS_LOG" | tr -d ' ')" 2
check "reported as PASS on the changed files" grep -q 'PASS gitleaks (changed files)' <<<"$out"
printf '#!/bin/bash\ncase "$*" in *b.py*) echo "Finding: generic-api-key"; exit 1;; esac\nexit 0\n' >"$STUBS/gitleaks"
out=$(bash "$GATES/static-gate.sh" a.py b.py)
check "a leak in one file fails the gate (exit 1)" eq "$?" 1
check "and names the file" grep -q 'b.py' <<<"$out"
printf '#!/bin/bash\nexit 0\n' >"$STUBS/gitleaks"

echo "build-prompt.sh"
for DT in "$GATES/../python/DO_TASK_PYTHON.md" "$GATES/../rust/DO_TASK_RUST.md" "$GATES/../DO_TASK.md"; do
    [ -f "$DT" ] || continue
    name=$(basename "$DT")
    impl_prompt=$(bash "$GATES/build-prompt.sh" impl "$DT")
    check "$name: impl prompt keeps the [impl] instructions" grep -q '^### \[impl\]' <<<"$impl_prompt"
    check "$name: impl prompt drops the [test] instructions" bash -c '! grep -q "^### \[test\]" <<<"$1"' _ "$impl_prompt"
    check "$name: impl prompt drops the discovery phase" bash -c '! grep -q "^### Phase 1: Task Discovery" <<<"$1"' _ "$impl_prompt"
    check "$name: impl prompt keeps the rules" grep -q '^## Rules' <<<"$impl_prompt"
    check "$name: test prompt keeps the [test] instructions" grep -q '^### \[test\]' <(bash "$GATES/build-prompt.sh" test "$DT")
    if grep -q '^## Commit Message Format' "$DT"; then
        check "$name: impl prompt drops the commit message section" bash -c '! grep -q "^## Commit Message Format" <<<"$1"' _ "$impl_prompt"
        check "$name: test prompt keeps the commit message section" grep -q '^## Commit Message Format' <(bash "$GATES/build-prompt.sh" test "$DT")
    fi
    check "$name: an unknown phase prints the whole file" eq "$(bash "$GATES/build-prompt.sh" other "$DT" | wc -l)" "$(wc -l <"$DT")"
    check "$name: the reduced prompt is much shorter" test "$(wc -l <<<"$impl_prompt")" -lt $(( $(wc -l <"$DT") * 8 / 10 ))
done

echo "verify.sh (audit mode)"
export RALPH_AUDIT=1
verify_repo() { # -> a bootstrapped repo where every [impl] is closed
    new_repo "$1"
    printf '%s' "$PLAN" >ACTION_PLAN.md
    python3 "$GATES/bootstrap_plan.py" >/dev/null 2>&1
    for _ in 1 2 3 4; do # bd refuses to close a blocked task: close in dependency order, in passes
        for id in $(bd list --all --json | jq -r '.[] | select((.title | startswith("[impl]")) and .status != "closed") | .id'); do
            bd close "$id" --reason done >/dev/null 2>&1
        done
    done
    AUDIT=$(bd list --all --json | jq -r '.[] | select(.title | startswith("[audit]")) | .id')
}
verify_repo ver_pass
bash "$GATES/verify.sh" >/dev/null 2>&1
check "an open audit cannot be judged (exit 10)" eq "$?" 10
bd close "$AUDIT" --reason "AC1 | MET | STATIC: a.py:1" >/dev/null 2>&1
out=$(bash "$GATES/verify.sh" 2>&1)
check "closed audit with all criteria met passes" eq "$?" 0
check "prints VERIFY_RESULT: PASS" grep -q '^VERIFY_RESULT: PASS' <<<"$out"
verify_repo ver_fail
bd close "$AUDIT" --reason "AC1 | MET | x
AC2 | NOT MET | missing" >/dev/null 2>&1
out=$(bash "$GATES/verify.sh" 2>&1)
check "an audit with NOT MET fails (exit 1)" eq "$?" 1
check "prints VERIFY_RESULT: FAIL" grep -q '^VERIFY_RESULT: FAIL' <<<"$out"
verify_repo ver_open
bd close "$AUDIT" --reason "AC1 | MET | x" >/dev/null 2>&1
mk "[impl] GAP: leftover" --type task --priority 0 --description x >/dev/null
bash "$GATES/verify.sh" >/dev/null 2>&1
check "an open GAP task fails (exit 1)" eq "$?" 1
unset RALPH_AUDIT

echo "project settings (env > profile > AGENTS.md)"
new_repo conf
tcmd() { bash -c ". '$GATES/common.sh'; test_command" 2>/dev/null; }
printf '# Agents\nRALPH_TEST_CMD: make check\n' >AGENTS.md
check "RALPH_TEST_CMD line in AGENTS.md" eq "$(tcmd)" "make check"
printf 'RALPH_TEST_CMD: ./build.sh {package}\n' >"$TMP/profile.conf"
check "a profile wins over AGENTS.md" eq "$(RALPH_PROFILE_FILE="$TMP/profile.conf" tcmd)" "./build.sh {package}"
check "the environment wins over the profile" eq "$(RALPH_TEST_CMD='env cmd' RALPH_PROFILE_FILE="$TMP/profile.conf" tcmd)" "env cmd"
printf 'RALPH_TEST_CMD: agent\n' >"$TMP/profile.conf"
check "RALPH_TEST_CMD: agent hands the tests to the agent" eq "$(RALPH_PROFILE_FILE="$TMP/profile.conf" tcmd)" ""
printf 'Evidence directory for this repo: `triage-logs/` (untracked)\n' >AGENTS.md
check "evidence_dir is read from AGENTS.md" eq "$(env -u RALPH_EVIDENCE_DIR bash -c ". '$GATES/common.sh'; evidence_dir")" "triage-logs"
printf 'RALPH_NO_COMMIT: triage-logs/,gen-*,notes.md\n' >AGENTS.md
nc() { bash -c ". '$GATES/common.sh'; is_no_commit '$1' && echo no || echo yes"; }
check "RALPH_NO_COMMIT: a directory" eq "$(nc triage-logs/a.log)" no
check "RALPH_NO_COMMIT: a glob" eq "$(nc gen-123/x)" no
check "RALPH_NO_COMMIT: a file at any depth" eq "$(nc docs/notes.md)" no
check "default: plans are never committed" eq "$(nc ACTION_PLAN_20260101.md)" no
check "ordinary source files may be committed" eq "$(nc src/app.py)" yes
printf 'RALPH_REQUIRE_BRANCH: release-[0-9]+\n' >AGENTS.md
git checkout -q -B master
check "branch_ok fails on master when another branch is required" bash -c "! (. '$GATES/common.sh'; branch_ok)"
git checkout -q -b release-7
check "branch_ok passes on a matching branch" bash -c ". '$GATES/common.sh'; branch_ok"
check "by default the gates add no commit prefix" eq "$(bash -c ". '$GATES/common.sh'; printf '%s' \"\$(commit_prefix)\"")" ""

echo "language defaults (pytest / cargo test) and the optional audit"
new_repo gen
tc() { (bash -c ". '$GATES/common.sh'; test_command"); }
check "no AGENTS.md and no project files: unknown" bash -c '! (cd "$1"; bash -c ". \"$2/common.sh\"; test_command")' _ "$PWD" "$GATES"
mkdir tests
eq "$(tc)" "python -m pytest -v"; check "python project defaults to pytest" eq "$(tc)" "python -m pytest -v"
touch Cargo.toml; rmdir tests
check "rust project defaults to cargo test" eq "$(tc)" "cargo test"
printf '# Agents\n- Run tests with: `PYTHONPATH=src python3 -m pytest -q`\n' >AGENTS.md
check "an explicit pytest command in AGENTS.md wins" eq "$(tc)" "PYTHONPATH=src python3 -m pytest -q"
printf '# Agents\n## Testing\nUse the magic runner.\n' >AGENTS.md
check "an unreadable testing section falls back to the agent" bash -c '! (cd "$1"; bash -c ". \"$2/common.sh\"; test_command")' _ "$PWD" "$GATES"
new_repo noaudit
printf '%s' "$PLAN" >ACTION_PLAN.md
python3 "$GATES/bootstrap_plan.py" >/dev/null 2>&1
check "no audit task by default" eq "$(bd list --all --json | jq '[.[] | select(.title | startswith("[audit]"))] | length')" 0
check "2 epics + 3 impl tasks and nothing else" eq "$(bd list --all --json | jq 'length')" 5
mv ACTION_PLAN.md ACTION_PLAN_20260101_000000.md
bash "$GATES/verify.sh" >/dev/null 2>&1
check "verify without audit fails while tasks are open (exit 1)" eq "$?" 1
for _ in 1 2 3 4; do for id in $(bd list --all --json | jq -r '.[] | select((.title | startswith("[impl]")) and .status != "closed") | .id'); do bd close "$id" --reason done >/dev/null 2>&1; done; done
out=$(bash "$GATES/verify.sh" 2>&1)
check "verify without audit passes when every deliverable is closed" eq "$?" 0
check "verify without audit prints PASS" grep -q 'VERIFY_RESULT: PASS' <<<"$out"
new_repo rust
printf '[package]\nname="x"\n' >Cargo.toml; mkdir src; echo 'fn main(){}' >src/main.rs
printf '#!/bin/bash\necho "cargo $*" >>"$0.log"\nexit 0\n' >"$STUBS/cargo"; chmod +x "$STUBS/cargo"
out=$(bash "$GATES/static-gate.sh" src/main.rs)
check "rust files run cargo fmt and clippy" grep -q 'PASS cargo clippy' <<<"$out"
rm -f "$STUBS/cargo" "$STUBS/cargo.log"

echo "result.json and verify-report.md (machine-readable end of a run)"
new_repo result
WR="$GATES/write-result.sh"
EV="$RALPH_EVIDENCE_DIR"
rj() { jq -r "$1" "$EV/result.json"; }
printf 'ACTION_PLAN.md Acceptance Report\n\nCoverage: 2/2 deliverables fully met\nCriteria: 5 ✓ / 0 ✗ / 0 ?\n\nVERIFY_RESULT: PASS\n' >"$TMP/report.txt"
echo p >ACTION_PLAN_20260101_000000.md
RALPH_AGENT=cursor RALPH_VERIFY_STATE=PASS RALPH_VERIFY_REPORT_FILE="$TMP/report.txt" RESULT_ITERATIONS=7 RESULT_COST=0 bash "$WR" 0
check "exit 0: result.json is valid JSON" jq -e . "$EV/result.json" >/dev/null
check "exit 0: exit_code 0, reason complete, verify PASS" eq "$(rj '"\(.exit_code) \(.reason) \(.verify_result)"')" "0 complete PASS"
check "exit 0: coverage and criteria counts come from the report" eq "$(rj '"\(.deliverables_met)/\(.deliverables_total) \(.criteria_met) \(.criteria_unmet) \(.criteria_unproven)"')" "2/2 5 0 0"
check "exit 0: iterations, agent, plan file and sha are recorded" eq "$(rj '"\(.iterations) \(.agent) \(.plan_file) \(.head_sha == "'"$(git rev-parse HEAD)"'")"')" "7 cursor ACTION_PLAN_20260101_000000.md true"
check "a non-claude agent reports no cost (null)" eq "$(rj '.cost_usd')" "null"
check "the schema version is 1 and finished_at is UTC ISO 8601" eq "$(rj '"\(.schema_version) \(.finished_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$"))"')" "1 true"
check "verify-report.md holds the printed report" grep -q 'VERIFY_RESULT: PASS' "$EV/verify-report.md"
RALPH_AGENT=claude RALPH_VERIFY_STATE=NONE RESULT_ITERATIONS=3 RESULT_COST=1.25 bash "$WR" 0
check "claude reports its cost" eq "$(rj '.cost_usd')" "1.25"
check "a run without report: counts null, verify NONE, report file says so" eq "$(rj '"\(.verify_result) \(.deliverables_total) \(.criteria_met)"')" "NONE null null"
check "a run without report: verify-report.md says none was produced" grep -qi 'no acceptance report' "$EV/verify-report.md"
for pair in "1 no_plan" "2 blocked" "3 max_iterations" "4 max_cost" "5 complete_with_warnings" "6 env_error" "7 no_progress" "8 wrong_branch" "42 agent_error"; do
    set -- $pair
    RALPH_AGENT=cursor RALPH_VERIFY_STATE=NONE bash "$WR" "$1"
    check "exit $1 is recorded with reason $2" eq "$(rj '"\(.exit_code) \(.reason)"')" "$1 $2"
done
RALPH_AGENT=cursor RALPH_VERIFY_STATE=NONE RESULT_REASON=usage_limit bash "$WR" 6
check "exit 6 with RESULT_REASON=usage_limit is told apart from env_error" eq "$(rj '.reason')" "usage_limit"
RALPH_AGENT=cursor RALPH_VERIFY_STATE=FAIL bash "$WR" 5
check "a failed verification is recorded" eq "$(rj '.verify_result')" "FAIL"
bash "$WR" clear
check "clear removes a stale result.json and verify-report.md" bash -c '[ ! -e "$1/result.json" ] && [ ! -e "$1/verify-report.md" ]' _ "$EV"
bash "$WR" 0
check "the writer never fails the loop (exit 0 even with no env at all)" eq "$?" 0
check "the evidence directory follows RALPH_EVIDENCE_DIR" bash -c '[ -f "$1/result.json" ]' _ "$EV"
check "result.json is never committable (evidence directory)" bash -c ". '$GATES/common.sh'; is_no_commit \"\$(evidence_dir)/result.json\" && is_no_commit \"\$(evidence_dir)/verify-report.md\""
git add -A . >/dev/null 2>&1
check "an untracked evidence directory leaves no tracked-file change" eq "$(git status --porcelain | grep -v '^A ' | grep -v '^??' | wc -l | tr -d ' ')" "0"

# Real loop, for the two exits that happen before any agent runs: the trap writes the result and the exit code is unchanged
LSTUB="$TMP/loopstubs"; mkdir -p "$LSTUB"
printf '#!/bin/bash\nexit 0\n' >"$LSTUB/aws"
printf '#!/bin/bash\n[ "$1" = "info" ] && [ "$2" = "--format" ] && echo 17179869184\nexit 0\n' >"$LSTUB/docker"
chmod +x "$LSTUB/aws" "$LSTUB/docker"
run_loop() { # env assignments... -> runs the real loop in the current repo
    env PATH="$LSTUB:$PATH" GATES_DIR="$GATES" RALPH_LOG_DIR="$TMP/looplogs" RALPH_PROJECT_NAME=looptest RALPH_AGENT=cursor \
        RALPH_EVIDENCE_DIR="$PWD/ralph-evidence" VERIFY_FILE="$TMP/none.md" "$@" bash "$GATES/../ralph-loop.sh" </dev/null
}
mkdir -p "$TMP/looplogs"
mkdir -p "$TMP/loop1" && cd "$TMP/loop1" && git init -q . && echo b >b && git add -A && git commit -q -m b
out=$(run_loop 2>&1); rc=$?
check "loop with no tasks and no plan still exits 1" eq "$rc" 1
check "loop console output does not mention the result file" bash -c '! grep -q "result.json" <<<"$1"' _ "$out"
check "loop exit 1 leaves result.json with reason no_plan" eq "$(jq -r '"\(.exit_code) \(.reason)"' ralph-evidence/result.json)" "1 no_plan"
out=$(run_loop RALPH_REQUIRE_BRANCH=release-only 2>&1); rc=$?
check "loop on the wrong branch still exits 8" eq "$rc" 8
check "loop exit 8 leaves result.json with reason wrong_branch" eq "$(jq -r '"\(.exit_code) \(.reason)"' ralph-evidence/result.json)" "8 wrong_branch"
echo stale >ralph-evidence/verify-report.md
out=$(run_loop 2>&1)
check "a new run clears the previous verify-report.md at start" bash -c '! grep -q stale "$1"' _ ralph-evidence/verify-report.md
check "the loop wires the usage-limit reason before its exit 6" bash -c 'awk "/RESULT_REASON=usage_limit/{f=1} f&&/exit 6/{print \"ok\"; exit}" "$1" | grep -q ok' _ "$GATES/../ralph-loop.sh"

[ -f "$GATES/tests/priority-tests.sh" ] && . "$GATES/tests/priority-tests.sh"

# Extension tests (present only where gates/ext.sh exists)
unset RALPH_NO_EXT
[ -f "$GATES/tests/ext-tests.sh" ] && . "$GATES/tests/ext-tests.sh"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
