#!/bin/bash
# build-prompt.sh PHASE DO_TASK_FILE — print the DO_TASK prompt reduced to what one phase needs.
# PHASE is impl, review, test or audit (anything else prints the whole file).
# Dropped: the other phases' instructions and templates, the discovery/claim steps (the loop
# does them and passes the result in its LOOP CONTEXT), and the commit-message section unless
# the phase commits (test).
phase="$1" file="$2"
case "$phase" in impl | review | test | audit) ;; *) cat "$file"; exit 0 ;; esac
awk -v phase="$phase" '
    function keep_template(h) {
        if (phase == "impl")   return h ~ /^### After \[impl\] success/
        if (phase == "review") return h ~ /^### After \[review\] (success|failure)/
        if (phase == "test")   return h ~ /^### (After \[test\] failure|Blocker)/
        return h ~ /^### Blocker/
    }
    /^```/ { fence = !fence }
    !fence && /^## / { top = $0; sub_ = ""; show = 1
        if (top ~ /^## Commit Message Format/ && phase != "test") show = 0
        print_line = show; if (show) print; next }
    !fence && /^### / { sub_ = $0; show = 1
        if (top ~ /^## Workflow/ && (sub_ ~ /^### Phase 1:/ || sub_ ~ /^### Phase 2:/)) show = 0
        if (top ~ /^## Phase Instructions/ && sub_ !~ "^### \\[" phase "\\]") show = 0
        if (top ~ /^## Task Creation Templates/ && !keep_template(sub_)) show = 0
        if (show) print; next }
    !fence && /^## / { next }
    { if (show == "" || show) print }
' "$file" 2>/dev/null
