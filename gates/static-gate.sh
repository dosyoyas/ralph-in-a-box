#!/bin/bash
# static-gate.sh FILE... — ruff, pyrefly, biome and gitleaks on the given files.
# Prints one PASS/FAIL/SKIP line per check (failures with their first lines of output).
# Exit 0 when nothing failed, 1 otherwise. Missing tools are skipped, not failed.
GATES_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common.sh
. "$GATES_DIR/common.sh"

py=() js=() rs=()
for f in "$@"; do
    [ -f "$f" ] || continue
    case "$f" in
    *.py) py+=("$f") ;;
    *.js | *.jsx | *.ts | *.tsx) js+=("$f") ;;
    *.rs) rs+=("$f") ;;
    esac
done

failed=0
check() { # name cmd...
    local name="$1" out rc
    shift
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "SKIP $name (not installed)"
        return 0
    fi
    out=$("$@" 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "PASS $name"
    else
        failed=1
        echo "FAIL $name (exit $rc)"
        printf '%s\n' "$out" | head -n 40 | head -c 4000 | sed 's/^/    /'
    fi
}

if [ "${#py[@]}" -gt 0 ]; then
    check "ruff format --check" ruff format --check "${py[@]}"
    check "ruff check" ruff check "${py[@]}"
    if [ -f pyrefly.toml ] || grep -q '^\[tool\.pyrefly' pyproject.toml 2>/dev/null; then
        check "pyrefly check" pyrefly check "${py[@]}"
    else
        echo "SKIP pyrefly check (not configured)"
    fi
fi
[ "${#js[@]}" -gt 0 ] && check "biome ci" biome ci "${js[@]}"
if [ "${#rs[@]}" -gt 0 ] && [ -f Cargo.toml ]; then
    check "cargo fmt --check" cargo fmt --all --check
    check "cargo clippy" cargo clippy --all-targets --all-features -- -D warnings -W clippy::cargo -A clippy::multiple_crate_versions
fi
# Secrets: only the files under check. A repo-wide scan of the whole history reports the same old findings on every
# run, which says nothing about this change.
if [ -z "${RALPH_SKIP_GITLEAKS:-}" ] && [ "$#" -gt 0 ]; then
    if command -v gitleaks >/dev/null 2>&1; then
        leaks=""
        for f in "$@"; do
            [ -f "$f" ] || continue
            out=$(gitleaks detect --no-git --source "$f" --no-banner --redact 2>&1) || leaks="$leaks
    $f: $(printf '%s' "$out" | head -n 3 | tr '\n' ' ' | head -c 300)"
        done
        if [ -z "$leaks" ]; then
            echo "PASS gitleaks (changed files)"
        else
            failed=1
            echo "FAIL gitleaks (changed files)$leaks"
        fi
    else
        echo "SKIP gitleaks (not installed)"
    fi
fi
[ "${#py[@]}" -eq 0 ] && [ "${#js[@]}" -eq 0 ] && [ "${#rs[@]}" -eq 0 ] && echo "NOTE no python/js/rust files among the changed files"
exit "$failed"
