#!/bin/bash
# Shared helpers for the ralph gates. Source it: . "$GATES_DIR/common.sh"

# Optional extension: if gates/ext.sh exists it is sourced at the end of this file and may redefine
# default_test_command and commit_prefix, and set ENV_ERROR_EXTRA (a regex of extra environment errors).
ENV_ERROR_EXTRA=""

# Task JSON for an id (bd show may return an object or a one-element array).
bd_task_json() {
    bd show "$1" --json 2>/dev/null | jq 'if type=="array" then .[0] else . end'
}

# File paths listed under a "FILES:" / "FILES MODIFIED:" heading, one per line.
# Reads the text on stdin. Accepts "- path", "path", backticks and comma lists.
parse_file_list() {
    awk '
        /^[[:space:]]*FILES( MODIFIED)?:/ { f = 1; sub(/^[[:space:]]*FILES( MODIFIED)?:[[:space:]]*/, ""); if (length($0)) print; next }
        f && /^[[:space:]]*$/ { f = 0 }
        f && /^[[:space:]]*[A-Z][A-Z _]*:/ { f = 0 }
        f { print }
    ' | sed -E 's/^[[:space:]]*[-*][[:space:]]*//; s/`//g' | tr -s ',[:space:]' '\n' | sed '/^$/d' | sort -u
}

# Text placed before "type: description" in the commits the gates make (e.g. a ticket key). None by default.
commit_prefix() { :; }

# Project settings come from, in order: the environment, the project's profile (RALPH_PROFILE_FILE, kept in the
# ralph repo so the project itself is not touched), then "KEY: value" lines in the project's AGENTS.md.
# Usage: ralph_conf RALPH_TEST_CMD   (prints the value; rc 1 when unset)
ralph_conf() {
    local key="$1" v f
    v="${!key:-}"
    if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
    for f in "${RALPH_PROFILE_FILE:-}" AGENTS.md; do
        [ -n "$f" ] && [ -f "$f" ] || continue
        v=$(grep -m1 -E "^[[:space:]]*${key}:" "$f" | sed -E "s/^[[:space:]]*${key}:[[:space:]]*//; s/^\`//; s/\`\$//")
        if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
    done
    return 1
}

# Where evidence logs go: RALPH_EVIDENCE_DIR, else the directory AGENTS.md names ("Evidence directory ... `x/`"), else ralph-evidence.
evidence_dir() {
    local d
    if d=$(ralph_conf RALPH_EVIDENCE_DIR); then printf '%s' "${d%/}"; return 0; fi
    d=$(grep -m1 -iE 'evidence directory' AGENTS.md 2>/dev/null | grep -oE '`[^`]+/`' | head -n 1 | tr -d '`')
    if [ -n "$d" ]; then printf '%s' "${d%/}"; return 0; fi
    printf 'ralph-evidence'
}

# Paths the gates never commit: evidence, plans, beads, BLOCKERS.md, .claude/ plus RALPH_NO_COMMIT (comma-separated
# globs; a trailing "/" means a directory). Returns 0 when the path must NOT be committed.
is_no_commit() {
    local path="$1" pat extra
    extra=$(ralph_conf RALPH_NO_COMMIT || true)
    local IFS=','
    # shellcheck disable=SC2086 # intentional word splitting on commas
    for pat in "$(evidence_dir)/" "ACTION_PLAN*" ".beads" "BLOCKERS.md" ".claude/" $extra; do
        pat="${pat#"${pat%%[![:space:]]*}"}"
        pat="${pat%"${pat##*[![:space:]]}"}"
        [ -n "$pat" ] || continue
        case "$pat" in
        */) case "$path" in "$pat"* | */"$pat"*) return 0 ;; esac ;;
        *) case "$path" in $pat | */$pat | $pat/* | */$pat/*) return 0 ;; esac ;;
        esac
    done
    return 1
}

# When the project requires a branch (RALPH_REQUIRE_BRANCH: a literal or regex), return 1 on any other branch.
branch_ok() {
    local req branch
    req=$(ralph_conf RALPH_REQUIRE_BRANCH) || return 0
    branch=$(git branch --show-current 2>/dev/null)
    printf '%s' "$branch" | grep -Eq "^(${req})\$"
}

# RALPH_STATIC_GATE: off | advisory | enforce (default). off: no lint pre-checks; advisory: run and show, never block.
static_mode() { ralph_conf RALPH_STATIC_GATE 2>/dev/null || printf 'enforce'; }

# Command that runs the project's tests, or fail (rc 1) when the agent has to run them.
# RALPH_TEST_CMD (env > profile > AGENTS.md line) wins; the value "agent" means "the agent runs the tests".
# Otherwise default_test_command decides.
test_command() {
    local line
    if line=$(ralph_conf RALPH_TEST_CMD); then
        [ "$line" = "agent" ] && return 1
        printf '%s' "$line"
        return 0
    fi
    default_test_command
}

# Language defaults: a backticked pytest / cargo test command on an AGENTS.md line about tests; else cargo test /
# python -m pytest -v by project files, unless AGENTS.md has a testing section the gate cannot interpret.
default_test_command() {
    local line
    line=$(grep -iE 'test' AGENTS.md 2>/dev/null | grep -oE '`[^`]*(pytest|cargo test)[^`]*`' | head -n 1 | tr -d '`')
    if [ -n "$line" ]; then printf '%s' "$line"; return 0; fi
    if [ -f AGENTS.md ] && grep -qiE '^#+[[:space:]].*test' AGENTS.md; then return 1; fi
    if [ -f Cargo.toml ]; then printf '%s' 'cargo test'; return 0; fi
    if [ -f pyproject.toml ] || [ -f pytest.ini ] || [ -f setup.py ] || [ -d tests ]; then
        printf '%s' 'python -m pytest -v'
        return 0
    fi
    return 1
}

# Test files by naming convention (used by the integrity gate and the commit type).
is_test_path() {
    case "$1" in
    tests/* | */tests/* | test/* | */test/* | */test_*.py | test_*.py | *_test.py | *.test.[jt]s | *.test.[jt]sx | *.spec.[jt]s | *.spec.[jt]sx) return 0 ;;
    *) return 1 ;;
    esac
}

# Reads paths on stdin, prints those the gates may commit / lint (drops evidence, plans, RALPH_NO_COMMIT, ...).
filter_committable() {
    local f
    while IFS= read -r f; do
        [ -n "$f" ] && ! is_no_commit "$f" && printf '%s\n' "$f"
    done
    return 0
}

# Optional extension (see the top of this file).
_ralph_gates_self=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
[ -z "${RALPH_NO_EXT:-}" ] && [ -f "$_ralph_gates_self/ext.sh" ] && . "$_ralph_gates_self/ext.sh" # RALPH_NO_EXT=1: core only (used by the core tests)
