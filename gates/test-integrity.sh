#!/bin/bash
# test-integrity.sh — flag changes to tests that could hide broken code, in the
# uncommitted work (diff against HEAD): removed/changed assertions, removed test
# functions, deleted test files, added skip/xfail. New test files are always fine.
# Prints the findings; exit 1 when there is any, 0 otherwise.
GATES_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common.sh
. "$GATES_DIR/common.sh"

ASSERT_RE='(^|[^A-Za-z_])(assert([^A-Za-z_]|$)|self\.assert[A-Za-z]*\(|assert_[a-z_]+\(|pytest\.raises|expect\()'
TESTDEF_RE='^[[:space:]]*(async[[:space:]]+)?def[[:space:]]+test_|^[[:space:]]*(it|test|describe)\('
SKIP_RE='(skip|xfail|xit\(|xdescribe\()'
findings=0

while IFS=$'\t' read -r status path _; do
    is_test_path "$path" || continue
    case "$status" in
    D*)
        echo "DELETED test file: $path"
        findings=1
        ;;
    M* | R*)
        diff=$(git diff HEAD --unified=0 --no-color -- "$path" | grep -E '^[-+][^-+]|^[-+]$')
        while IFS= read -r line; do
            body="${line:1}"
            case "$line" in
            -*)
                if printf '%s' "$body" | grep -Eq "$ASSERT_RE"; then
                    echo "REMOVED/CHANGED assertion in $path: ${body#"${body%%[![:space:]]*}"}"
                    findings=1
                elif printf '%s' "$body" | grep -Eq "$TESTDEF_RE"; then
                    echo "REMOVED/CHANGED test definition in $path: ${body#"${body%%[![:space:]]*}"}"
                    findings=1
                fi
                ;;
            +*)
                if printf '%s' "$body" | grep -Eqi "$SKIP_RE"; then
                    echo "ADDED skip/xfail in $path: ${body#"${body%%[![:space:]]*}"}"
                    findings=1
                fi
                ;;
            esac
        done <<<"$diff"
        ;;
    esac
done < <(git diff HEAD --name-status -M)

[ "$findings" -eq 0 ] && echo "OK no suspicious test changes"
exit "$findings"
