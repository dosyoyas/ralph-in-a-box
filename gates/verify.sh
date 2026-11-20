#!/bin/bash
# verify.sh — final acceptance report from beads state, without an agent.
# The [audit] task is the one independent LLM check of the plan; this only reports its verdict
# and the plan coverage. Exit: 0 PASS, 1 FAIL, 10 = cannot judge (run the VERIFY agent).
tmp=$(mktemp -d /tmp/ralph-verify-XXXXXX)
trap 'rm -rf "$tmp"' EXIT
bd list --all --json >"$tmp/all" 2>/dev/null || exit 10
[ -s "$tmp/all" ] || exit 10

if [ "${RALPH_AUDIT:-1}" = "0" ]; then
    # No [audit] phase in this loop: the plan was turned into tasks 1:1, so check coverage by counting.
    read -r total closed open_work blocked < <(jq -r '
        [.[] | select(.title | test("^\\[impl\\]")) | select(.title | test("RETRY|GAP") | not)] as $d
        | [.[] | select(.title | test("^\\[(impl|review|test)\\]")) | select(.status != "closed")] as $o
        | [.[] | select(.title | startswith("BLOCKED:"))] as $b
        | "\($d | length) \([$d[] | select(.status == "closed")] | length) \($o | length) \($b | length)"' "$tmp/all")
    plan=$(ls -t ACTION_PLAN_*.md 2>/dev/null | head -n 1)
    in_plan=""
    [ -n "$plan" ] && in_plan=$(awk '/^## /{f = ($0 ~ /^## Feature/)} f && /^### /{n++} END{print n+0}' "$plan")
    echo "Acceptance Report (loop gate, no audit phase)"
    echo "════════════════════════════════════════════"
    echo "Deliverables closed: $closed/$total (plan ${plan:-?}: ${in_plan:-?} deliverables) | open plan tasks: $open_work | BLOCKED tasks: $blocked"
    git log --oneline -n 5 | sed 's/^/  /'
    ls "${RALPH_EVIDENCE_DIR:-ralph-evidence}"/*test-run*.log 2>/dev/null | sed 's/^/Evidence: /'
    if [ "$closed" != "$total" ] || [ "$open_work" != "0" ] || [ "$blocked" != "0" ] || { [ -n "$in_plan" ] && [ "$in_plan" != "$total" ]; }; then
        echo "VERIFY_RESULT: FAIL — plan tasks are open, blocked or do not match the plan"
        exit 1
    fi
    echo "VERIFY_RESULT: PASS"
    exit 0
fi

audit=$(jq -c '[.[] | select(.title | startswith("[audit]"))] | sort_by(.created_at) | .[-1] // empty' "$tmp/all")
[ -n "$audit" ] || exit 10
[ "$(jq -r .status <<<"$audit")" = "closed" ] || exit 10
reason=$(jq -r '.close_reason // ""' <<<"$audit")
grep -q 'MET' <<<"$reason" || exit 10   # no per-criterion table: not enough to judge
base=$(jq -r '.description // ""' <<<"$audit" | sed -n 's/^BASE_SHA:[[:space:]]*//p' | head -n 1)

read -r total closed open_work open_gap < <(jq -r '
    [.[] | select(.title | test("^\\[impl\\]")) | select(.title | test("RETRY|GAP") | not)] as $d
    | [.[] | select(.title | test("^\\[(impl|review|test)\\]")) | select(.status != "closed")] as $o
    | [.[] | select(.title | test("^\\[impl\\] GAP")) | select(.status != "closed")] as $g
    | "\($d | length) \([$d[] | select(.status == "closed")] | length) \($o | length) \($g | length)"' "$tmp/all")

echo "ACTION_PLAN.md Acceptance Report (loop gate)"
echo "════════════════════════════════════════════"
echo "Audit task: $(jq -r .id <<<"$audit") closed"
printf '%s\n' "$reason" | sed 's/^/  /'
echo
echo "Deliverables closed: $closed/$total | open plan tasks: $open_work | open GAP tasks: $open_gap"
if [ -n "$base" ] && git rev-parse -q --verify "$base^{commit}" >/dev/null 2>&1; then
    echo "Commits since $base:"
    git log --oneline "$base..HEAD" | sed 's/^/  /'
fi
ls "${RALPH_EVIDENCE_DIR:-ralph-evidence}"/*test-run*.log 2>/dev/null | sed 's/^/Evidence: /'

if grep -Eq 'NOT MET|UNPROVEN|BLOCKED' <<<"$reason" || [ "$open_work" != "0" ] || [ "$open_gap" != "0" ] || [ "$closed" != "$total" ]; then
    echo "VERIFY_RESULT: FAIL — audit reported gaps or plan tasks are still open"
    exit 1
fi
echo "VERIFY_RESULT: PASS"
exit 0
