#!/bin/bash
# Sourced by run-tests.sh (uses its helpers: new_repo, check, eq, GATES). bd only accepts priorities 0-4, so a plan
# with more than 5 deliverables in a Feature, or more than 5 Features, must still bootstrap, and the loop must still
# run the deliverables in the order of the plan.

echo "bootstrap_plan.py: plans larger than bd's 0-4 priorities"
new_repo many
{
    printf '# Plan\n\nOverview.\n\n## Feature 1: Big\n'
    for d in 1 2 3 4 5 6 7; do printf '### F1D%s\n**Blocked by:** None\n\nbody\n\n- [ ] c%s\n\n' "$d" "$d"; done
    for f in 2 3 4 5 6; do printf '## Feature %s: Small%s\n### G%s\n**Blocked by:** None\n\nbody\n\n- [ ] c\n\n' "$f" "$f" "$f"; done
} >ACTION_PLAN.md
python3 "$GATES/bootstrap_plan.py" >/dev/null 2>&1
check "a Feature with 7 deliverables and a plan with 6 Features bootstrap (exit 0)" eq "$?" 0
check "all 12 deliverables and 6 epics are created" eq "$(bd list --all --json | jq 'length')" 18
check "every priority stays within bd's 0-4" eq "$(bd list --all --json | jq 'all(.[]; .priority >= 0 and .priority <= 4)')" true
order=""
for _ in $(seq 14); do
    t=$(bash "$GATES/next-task.sh" | jq -r '.title // empty')
    [ -n "$t" ] || break # next-task.sh exits 1 when nothing is left; the pipe hides that status, so test the output
    order="$order|${t#\[impl\] }"
    id=$(bd list --all --json | jq -r --arg t "$t" '.[] | select(.title == $t) | .id')
    bd close "$id" --reason done >/dev/null 2>&1
done
check "the loop runs the deliverables in the order of the plan" eq "$order" "|F1D1|F1D2|F1D3|F1D4|F1D5|F1D6|F1D7|G2|G3|G4|G5|G6"
