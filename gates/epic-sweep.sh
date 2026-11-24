#!/bin/bash
# epic-sweep.sh — give an Epic the [review] task it is missing.
#
# An Epic whose tasks are all closed, with an [impl] as the most recently closed one, is stuck: nothing will ever run
# [review] and [test] for it (typically an [impl] RETRY that was closed without creating its [review]), and its work
# stays uncommitted until some other Epic's commit sweeps it up. This creates the missing [review] task.
# The audit Epic (the one holding an [audit] task and its GAP tasks) is left alone.
GATES_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common.sh
. "$GATES_DIR/common.sh"

tmp=$(mktemp -d /tmp/ralph-sweep-XXXXXX)
trap 'rm -rf "$tmp"' EXIT
bd list --all --json >"$tmp/all" 2>/dev/null || exit 0

jq -r '
    . as $all
    | [ $all[] | select(.issue_type == "epic" and .status != "closed") ][] | .id as $e | .title as $t
    | [ $all[] | select(.parent == $e) ] as $kids
    | select(($kids | length) > 0)
    | select([ $kids[] | select(.status != "closed") ] | length == 0)
    | select([ $kids[] | select(.title | startswith("[audit]")) ] | length == 0)
    | ($kids | max_by(.closed_at // .updated_at // "")) as $last
    | select($last.title | startswith("[impl]"))
    | "\($e)\t\($t)"' "$tmp/all" | while IFS=$'\t' read -r epic title; do
    # files of the Epic: the "FILES MODIFIED" notes of its closed [impl] tasks
    files=$(jq -r --arg e "$epic" '.[] | select(.parent == $e and (.title | startswith("[impl]"))) | .notes // ""' "$tmp/all" | parse_file_list)
    name=${title#Epic: }
    if bd create "[review] Review: $name" --parent "$epic" --type task --priority 0 --json \
        --description "FILES MODIFIED:
$files

IMPLEMENTATION SUMMARY:
Created by the loop: every task of this Epic was closed and the last one was an [impl] (a RETRY or a fix) that left no [review] behind.

RETRY: 0" </dev/null >/dev/null 2>&1; then
        echo "[SWEEP] Epic $epic had no [review] after its last [impl]: created one"
    else
        echo "[SWEEP] could not create the missing [review] for Epic $epic"
    fi
done
exit 0
