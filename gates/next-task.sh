#!/bin/bash
# next-task.sh — print (as JSON) the task the loop should run next, or exit 1 if none.
# Same rule as DO_TASK Phase 1: finish the Epic in flight first (it has a closed
# [impl]); otherwise lowest Epic priority, then lowest task priority.
RE="${ACTIONABLE_TITLE_RE:-^\\[(impl|test|review|audit)\\]}"
# Pass the JSON by file: a big beads database exceeds the argv size limit.
tmp=$(mktemp -d /tmp/ralph-next-XXXXXX)
trap 'rm -rf "$tmp"' EXIT
bd ready --json >"$tmp/ready" 2>/dev/null || exit 1
bd list --all --json >"$tmp/all" 2>/dev/null || exit 1
out=$(jq -n --slurpfile r "$tmp/ready" --slurpfile a "$tmp/all" --arg re "$RE" '
    $r[0] as $ready | $a[0] as $all |
    ([$all[] | select((.title | test("^\\[impl\\]")) and .status == "closed") | .parent]) as $done
    | ([$all[] | select(.issue_type == "epic" and .status != "closed" and (.id as $i | $done | index($i))) | .id]) as $inflight
    | (reduce ($all[] | select(.issue_type == "epic")) as $e ({}; .[$e.id] = ($e.priority // 0))) as $ep
    | [$ready[] | select(.title | test($re))]
    | to_entries
    | map(. + { k: (if (.value.parent as $p | $inflight | index($p)) then 0 else 1 end),
                e: ($ep[.value.parent // ""] // 0) })
    | sort_by([.k, .e, (.value.priority // 0), .key])
    | (.[0].value // empty)
    | {id, title, parent, priority}')
[ -n "$out" ] || exit 1
printf '%s\n' "$out"
