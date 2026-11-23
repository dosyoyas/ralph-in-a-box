#!/bin/bash
# Tests for the ralph gates. Needs git, jq, python3 and bd (real, on temp repos); no Docker, no AWS, no agent.
# Usage: gates/tests/run-tests.sh
GATES=$(cd "$(dirname "$0")/.." && pwd)
for tool in git jq python3 bd; do
    command -v "$tool" >/dev/null || { echo "SKIP: $tool not installed"; exit 0; }
done

pass=0 fail=0 TMP=$(mktemp -d /tmp/ralph-gates-test-XXXXXX)
trap 'rm -rf "$TMP"' EXIT
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
check "creates epics, impl tasks and the audit task" eq "$(bd list --all --json | jq 'length')" 7
check "titles use [impl] prefix" eq "$(bd list --all --json | jq '[.[] | select(.title | startswith("[impl] "))] | length')" 3
desc=$(bd list --all --json | jq -r '.[] | select(.title == "[impl] Add parser") | .description')
check "copies numbered steps verbatim" grep -q '2. step two' <<<"$desc"
check "numbers acceptance criteria (with continuation)" grep -q 'AC2: parses b with continuation' <<<"$desc"
check "copies shared context into the task" grep -q 'Use pytest only' <<<"$desc"
check "copies the plan overview into the task" grep -q 'Overview constraint: no prod changes' <<<"$desc"
check "only the first impl is ready (plus epics)" eq "$(bd ready --json | jq '[.[] | select(.title | test("^\\[(impl|audit)\\]"))] | length')" 1
check "audit task is blocked until every impl is done" eq "$(bd ready --json | jq '[.[] | select(.title | startswith("[audit]"))] | length')" 0
new_repo bad
printf '# Plan\n\nJust prose, no features.\n' >ACTION_PLAN.md
python3 "$GATES/bootstrap_plan.py" >/dev/null 2>&1
check "unparseable plan exits 2" eq "$?" 2
check "unparseable plan creates nothing" eq "$(bd list --all --json | jq 'length')" 0
printf '## Feature 1: X\n### D\n**Blocked by:** Nonexistent thing\n\nbody\n\n- [ ] ok\n' >ACTION_PLAN.md
python3 "$GATES/bootstrap_plan.py" >/dev/null 2>&1
check "unresolvable Blocked by exits 2" eq "$?" 2

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
    git checkout -q -b feature/LABS-1234-x
}
setup_test_task gate_pass
RALPH_TEST_CMD='echo "3 passed"; exit 0' bash "$GATES/test-gate.sh" "$TID" >"$TMP/out.txt" 2>&1
check "passing tests exit 0" eq "$?" 0
check "commits the listed files with the JIRA prefix" grep -q '^LABS-1234 test: add parser' <(git log -1 --format=%s)
check "closes the [test] task" eq "$(bd show "$TID" --json | jq -r 'if type=="array" then .[0].status else .status end')" closed
check "closes the Epic when nothing else is open" eq "$(bd show "$EID" --json | jq -r 'if type=="array" then .[0].status else .status end')" closed
check "writes the evidence log" test -s "$RALPH_EVIDENCE_DIR/${EID}-test-run.log"

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
: >"$GATE_CONTEXT_FILE"
RALPH_TEST_CMD='echo ok' bash "$GATES/test-gate.sh" "$TID" >"$TMP/out.txt" 2>&1
check "a PENDING test that does not exist falls back (exit 10)" eq "$?" 10
check "fallback names the missing function" grep -q 'test_does_not_exist' "$GATE_CONTEXT_FILE"

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
printf 'RALPH_REQUIRE_BRANCH: OTXP-5707\n' >AGENTS.md
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
printf '# Agents\nRun tests with make magic.\n' >AGENTS.md
env -u RALPH_TEST_CMD bash "$GATES/test-gate.sh" "$TID" >"$TMP/out.txt" 2>&1
check "unknown test setup falls back to the agent (exit 10)" eq "$?" 10

setup_test_task gate_integrity
git checkout -q main 2>/dev/null || git checkout -q master
git checkout -q feature/LABS-1234-x
printf 'def test_a():\n    assert 1 == 1\n' >tests/test_a.py && git add -A && git commit -q -m seed
printf 'def test_a():\n    pass\n' >tests/test_a.py
: >"$GATE_CONTEXT_FILE"
RALPH_TEST_CMD='exit 0' bash "$GATES/test-gate.sh" "$TID" >"$TMP/out.txt" 2>&1
check "weakened tests fall back to the agent (exit 10)" eq "$?" 10
check "context lists the finding" grep -q 'REMOVED/CHANGED assertion' "$GATE_CONTEXT_FILE"

echo "build-prompt.sh"
for DT in "$GATES/../DO_TASK_PYTHON_OTXB.md" "$GATES/../python/DO_TASK_PYTHON.md" "$GATES/../rust/DO_TASK_RUST.md"; do
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

echo "verify.sh"
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

echo "project settings (env > profile > AGENTS.md) and the otxb test command guard"
new_repo conf
otx() { (cd "$PWD" && bash -c ". '$GATES/common.sh'; test_command") 2>/dev/null; }
check "no AGENTS.md: otxb default" eq "$(otx)" "otxb_build.py --test"
printf '# Agents\nBe concise.\n' >AGENTS.md
check "AGENTS.md silent about tests: otxb default" eq "$(otx)" "otxb_build.py --test"
printf '# Agents\nRun `otxb_build.py --test` from the repo root.\n' >AGENTS.md
check "AGENTS.md recommending it: otxb default" eq "$(otx)" "otxb_build.py --test"
printf '**Do NOT use `otxb_build.py`** (not `otxb_build.py --test`, not any other subcommand).\n' >AGENTS.md
check "AGENTS.md forbidding it: the agent runs the tests" eq "$(otx)" ""
printf 'JIRA: LABS-1\n\n\\_\\*\\* TESTING: use ./build.sh otxb-core-aws to run the tests for otxb-core-aws\n' >AGENTS.md
check "AGENTS.md documenting another procedure: the agent runs the tests" eq "$(otx)" ""
printf '# Agents\nRALPH_TEST_CMD: make check\n' >AGENTS.md
check "RALPH_TEST_CMD line in AGENTS.md" eq "$(otx)" "make check"
printf 'RALPH_TEST_CMD: ./build.sh {package}\n' >"$TMP/profile.conf"
check "a profile wins over AGENTS.md" eq "$(RALPH_PROFILE_FILE="$TMP/profile.conf" otx)" "./build.sh {package}"
check "the environment wins over the profile" eq "$(RALPH_TEST_CMD='env cmd' RALPH_PROFILE_FILE="$TMP/profile.conf" otx)" "env cmd"
printf 'RALPH_TEST_CMD: agent\n' >"$TMP/profile.conf"
check "RALPH_TEST_CMD: agent hands the tests to the agent" eq "$(RALPH_PROFILE_FILE="$TMP/profile.conf" otx)" ""
printf 'Evidence directory for this repo: `triage-logs/` (untracked)\n' >AGENTS.md
check "evidence_dir is read from AGENTS.md" eq "$(env -u RALPH_EVIDENCE_DIR bash -c ". '$GATES/common.sh'; evidence_dir")" "triage-logs"
printf 'RALPH_NO_COMMIT: triage-logs/,gen-otx-*,notes.md\n' >AGENTS.md
nc() { bash -c ". '$GATES/common.sh'; is_no_commit '$1' && echo no || echo yes"; }
check "RALPH_NO_COMMIT: a directory" eq "$(nc triage-logs/a.log)" no
check "RALPH_NO_COMMIT: a glob" eq "$(nc gen-otx-123/x)" no
check "RALPH_NO_COMMIT: a file at any depth" eq "$(nc docs/notes.md)" no
check "default: plans are never committed" eq "$(nc ACTION_PLAN_20260101.md)" no
check "ordinary source files may be committed" eq "$(nc src/app.py)" yes
printf 'RALPH_REQUIRE_BRANCH: OTXP-5707\n' >AGENTS.md
git checkout -q -B master
check "branch_ok fails on master when another branch is required" bash -c "! (. '$GATES/common.sh'; branch_ok)"
git checkout -q -b OTXP-5707
check "branch_ok passes on the required branch" bash -c ". '$GATES/common.sh'; branch_ok"

echo "jira_tag (branch first, AGENTS.md only on main/master)"
new_repo jira
jt() { bash -c ". '$GATES/common.sh'; printf '%s' \"\$(jira_tag)\""; }
printf 'JIRA: LABS-9307\n\nUTF-8 is used.\n' >AGENTS.md
git checkout -q -B master
check "master reads the JIRA: line of AGENTS.md" eq "$(jt)" "LABS-9307"
git checkout -q -b feature/LABS-77-thing
check "a branch with a ticket wins over AGENTS.md" eq "$(jt)" "LABS-77"
git checkout -q -b ralph-metrics-test
check "a branch without a ticket gets NO tag (not the stale AGENTS.md one)" eq "$(jt)" ""
git checkout -q master
printf 'UTF-8 first\nJIRA: LABS-5\n' >AGENTS.md
check "the JIRA: line is preferred over an earlier ticket-looking token" eq "$(jt)" "LABS-5"
printf 'no ticket labels, see LABS-12 once\n' >AGENTS.md
check "without a JIRA: line the first ticket-like token is used" eq "$(jt)" "LABS-12"
git checkout -q --detach
printf 'JIRA: LABS-9\n' >AGENTS.md
check "detached HEAD (no branch) falls back to AGENTS.md" eq "$(jt)" "LABS-9"

echo "generic flavor (pytest / cargo test, no audit)"
new_repo gen
tc() { (RALPH_FLAVOR=generic bash -c ". '$GATES/common.sh'; test_command"); }
check "no AGENTS.md and no project files: unknown" bash -c '! (cd "$1"; RALPH_FLAVOR=generic bash -c ". \"$2/common.sh\"; test_command")' _ "$PWD" "$GATES"
mkdir tests
eq "$(tc)" "python -m pytest -v"; check "python project defaults to pytest" eq "$(tc)" "python -m pytest -v"
touch Cargo.toml; rmdir tests
check "rust project defaults to cargo test" eq "$(tc)" "cargo test"
printf '# Agents\n- Run tests with: `PYTHONPATH=src python3 -m pytest -q`\n' >AGENTS.md
check "an explicit pytest command in AGENTS.md wins" eq "$(tc)" "PYTHONPATH=src python3 -m pytest -q"
printf '# Agents\n## Testing\nUse the magic runner.\n' >AGENTS.md
check "an unreadable testing section falls back to the agent" bash -c '! (cd "$1"; RALPH_FLAVOR=generic bash -c ". \"$2/common.sh\"; test_command")' _ "$PWD" "$GATES"
new_repo noaudit
printf '%s' "$PLAN" >ACTION_PLAN.md
RALPH_AUDIT=0 python3 "$GATES/bootstrap_plan.py" >/dev/null 2>&1
check "RALPH_AUDIT=0 creates no audit task" eq "$(bd list --all --json | jq '[.[] | select(.title | startswith("[audit]"))] | length')" 0
check "RALPH_AUDIT=0 creates 3 epics-less impl tasks (2 epics + 3 impl)" eq "$(bd list --all --json | jq 'length')" 5
mv ACTION_PLAN.md ACTION_PLAN_20260101_000000.md
RALPH_AUDIT=0 bash "$GATES/verify.sh" >/dev/null 2>&1
check "verify without audit fails while tasks are open (exit 1)" eq "$?" 1
for _ in 1 2 3 4; do for id in $(bd list --all --json | jq -r '.[] | select((.title | startswith("[impl]")) and .status != "closed") | .id'); do bd close "$id" --reason done >/dev/null 2>&1; done; done
out=$(RALPH_AUDIT=0 bash "$GATES/verify.sh" 2>&1)
check "verify without audit passes when every deliverable is closed" eq "$?" 0
check "verify without audit prints PASS" grep -q 'VERIFY_RESULT: PASS' <<<"$out"
new_repo rust
printf '[package]\nname="x"\n' >Cargo.toml; mkdir src; echo 'fn main(){}' >src/main.rs
printf '#!/bin/bash\necho "cargo $*" >>"$0.log"\nexit 0\n' >"$STUBS/cargo"; chmod +x "$STUBS/cargo"
out=$(bash "$GATES/static-gate.sh" src/main.rs)
check "rust files run cargo fmt and clippy" grep -q 'PASS cargo clippy' <<<"$out"
rm -f "$STUBS/cargo" "$STUBS/cargo.log"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
