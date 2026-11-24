#!/bin/bash
# write-result.sh EXIT_CODE | clear — machine-readable end of a ralph run.
#
# Called by ralph-loop.sh from its EXIT trap (never by the agent). Writes, into the evidence directory:
#   result.json        what happened (exit code, reason, verdict, counts, ...)
#   verify-report.md   the last acceptance report, or a note that none was produced
# `clear` removes both at startup so a stale result is never read as the current one.
#
# Inputs (environment, all optional):
#   RESULT_REASON              overrides the reason derived from the exit code (e.g. usage_limit for exit 6)
#   RALPH_VERIFY_STATE         PASS | FAIL | NONE  (NONE: the final verification did not run)
#   RALPH_VERIFY_REPORT_FILE   file holding the printed acceptance report
#   RESULT_ITERATIONS, RESULT_COST, RALPH_AGENT
#
# It never fails: a problem here must not change the loop's exit code.
GATES_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common.sh
. "$GATES_DIR/common.sh" 2>/dev/null # its last command may return 1 (RALPH_NO_EXT), so check the function instead of the status
type evidence_dir >/dev/null 2>&1 || exit 0

EVID=$(evidence_dir 2>/dev/null) || exit 0
[ -n "$EVID" ] || exit 0

if [ "${1:-}" = "clear" ]; then
    rm -f "$EVID/result.json" "$EVID/verify-report.md" 2>/dev/null
    exit 0
fi

code=${1:-}
case "$code" in '' | *[!0-9]*) exit 0 ;; esac
command -v jq >/dev/null 2>&1 || exit 0

case "$code" in
0) reason=complete ;;
1) reason=no_plan ;;
2) reason=blocked ;;
3) reason=max_iterations ;;
4) reason=max_cost ;;
5) reason=complete_with_warnings ;;
6) reason=env_error ;;
7) reason=no_progress ;;
8) reason=wrong_branch ;;
*) reason=agent_error ;;
esac
[ -n "${RESULT_REASON:-}" ] && reason=$RESULT_REASON

verify=${RALPH_VERIFY_STATE:-NONE}
case "$verify" in PASS | FAIL | NONE) ;; *) verify=NONE ;; esac

report=${RALPH_VERIFY_REPORT_FILE:-}
met="" total="" c_met="" c_unmet="" c_unproven=""
if [ -n "$report" ] && [ -s "$report" ]; then
    # VERIFY agent format: "Coverage: X/Y deliverables fully met" and "Criteria: A ✓ / B ✗ / C ?"
    # verify.sh format:    "Deliverables closed: X/Y"
    line=$(sed -nE 's/^Coverage:[[:space:]]*([0-9]+)\/([0-9]+).*/\1 \2/p' "$report" | tail -n 1)
    [ -n "$line" ] || line=$(sed -nE 's/^Deliverables closed:[[:space:]]*([0-9]+)\/([0-9]+).*/\1 \2/p' "$report" | tail -n 1)
    [ -n "$line" ] && read -r met total <<<"$line"
    line=$(sed -nE 's/^Criteria:[[:space:]]*([0-9]+)[^0-9]+([0-9]+)[^0-9]+([0-9]+).*/\1 \2 \3/p' "$report" | tail -n 1)
    [ -n "$line" ] && read -r c_met c_unmet c_unproven <<<"$line"
fi

plan=$(ls -t ACTION_PLAN_[0-9]*.md 2>/dev/null | head -n 1)
cost=""
[ "${RALPH_AGENT:-}" = "claude" ] && cost=${RESULT_COST:-}
sha=$(git rev-parse --verify -q HEAD 2>/dev/null)

mkdir -p "$EVID" 2>/dev/null || exit 0
tmp=$(mktemp "$EVID/.result-XXXXXX" 2>/dev/null) || exit 0
if jq -n \
    --argjson code "$code" --arg reason "$reason" --arg verify "$verify" \
    --arg met "$met" --arg total "$total" --arg cmet "$c_met" --arg cunmet "$c_unmet" --arg cunproven "$c_unproven" \
    --arg iterations "${RESULT_ITERATIONS:-}" --arg cost "$cost" --arg agent "${RALPH_AGENT:-}" \
    --arg sha "$sha" --arg plan "$plan" --arg finished "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    def num: if . == "" then null else (tonumber? // null) end;
    def str: if . == "" then null else . end;
    {
        schema_version: 1,
        exit_code: $code,
        reason: $reason,
        verify_result: $verify,
        deliverables_met: ($met | num),
        deliverables_total: ($total | num),
        criteria_met: ($cmet | num),
        criteria_unmet: ($cunmet | num),
        criteria_unproven: ($cunproven | num),
        iterations: ($iterations | num),
        cost_usd: ($cost | num),
        agent: ($agent | str),
        head_sha: ($sha | str),
        plan_file: ($plan | str),
        finished_at: $finished
    }' >"$tmp" 2>/dev/null; then
    mv -f "$tmp" "$EVID/result.json"
else
    rm -f "$tmp"
fi

if [ -n "$report" ] && [ -s "$report" ]; then
    cp "$report" "$EVID/verify-report.md" 2>/dev/null
else
    printf 'No acceptance report was produced in this run (exit code %s, reason %s).\n' "$code" "$reason" >"$EVID/verify-report.md" 2>/dev/null
fi
exit 0
