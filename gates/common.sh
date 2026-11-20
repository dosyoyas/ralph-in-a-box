#!/bin/bash
# Shared helpers for the ralph gates. Source it: . "$GATES_DIR/common.sh"

# Flavor of the loop: "otxb" (tests via otxb_build.py, JIRA-prefixed commits) or "generic" (pytest / cargo test).
# Set by ralph-loop.sh.
RALPH_FLAVOR="${RALPH_FLAVOR:-otxb}"

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

# JIRA tag for commit messages: the branch's ticket (unless main/master), else AGENTS.md.
jira_tag() {
    [ "$RALPH_FLAVOR" = "otxb" ] || return 0 # JIRA prefixes are an otxb convention ("UTF-8" would match the pattern)
    local branch tag=""
    branch=$(git branch --show-current 2>/dev/null)
    if [ -n "$branch" ] && [ "$branch" != "main" ] && [ "$branch" != "master" ]; then
        tag=$(printf '%s' "$branch" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -n 1)
    fi
    [ -z "$tag" ] && tag=$(grep -oE '[A-Z][A-Z0-9]+-[0-9]+' AGENTS.md 2>/dev/null | head -n 1)
    printf '%s' "$tag"
}

# Command that runs the project's tests, or fail (rc 1) when it cannot be told.
# Order: $RALPH_TEST_CMD, a "RALPH_TEST_CMD: <cmd>" line in AGENTS.md, then per flavor:
#   otxb:    `otxb_build.py --test` when AGENTS.md is absent or names it
#   generic: a backticked pytest / cargo test command on an AGENTS.md line about tests; else the
#            language default (cargo test / python -m pytest -v), unless AGENTS.md has a testing
#            section the gate cannot interpret
# Anything else is unknown: the agent runs the tests.
test_command() {
    if [ -n "${RALPH_TEST_CMD:-}" ]; then printf '%s' "$RALPH_TEST_CMD"; return 0; fi
    local line
    line=$(grep -m1 -E '^[[:space:]]*RALPH_TEST_CMD:' AGENTS.md 2>/dev/null | sed -E 's/^[[:space:]]*RALPH_TEST_CMD:[[:space:]]*//; s/^`//; s/`$//')
    if [ -n "$line" ]; then printf '%s' "$line"; return 0; fi
    if [ "$RALPH_FLAVOR" = "otxb" ]; then
        if [ ! -f AGENTS.md ] || grep -q 'otxb_build.py --test' AGENTS.md; then
            printf '%s' 'otxb_build.py --test'
            return 0
        fi
        return 1
    fi
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
