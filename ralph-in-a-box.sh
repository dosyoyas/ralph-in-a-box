#!/bin/bash

# Run ralph loop inside Docker container with host-side tmux monitoring
# Usage: ./ralph-in-a-box.sh /path/to/workspace [do_task_file]
#
#   do_task_file  Path to the DO_TASK prompt file to use.
#                 Relative paths are resolved from the ralph-loop directory.
#                 Defaults to DO_TASK_PYTHON.md.
#                 Example: ./ralph-in-a-box.sh /path/to/project DO_TASK_AGENTS.md
#
#   RALPH_IMAGE   Docker image to use (env var). Defaults to ralph-loop:latest.
#                 Example: RALPH_IMAGE=ralph-loop-rust:latest ./ralph-in-a-box.sh ...

set -e

WORKSPACE="${1:?Usage: $0 /path/to/workspace [do_task_file]}"
WORKSPACE=$(cd "$WORKSPACE" && pwd)
PROJECT_NAME=$(basename "$WORKSPACE")

if [ ! -d "$WORKSPACE" ]; then
    echo "Error: Workspace directory does not exist: $WORKSPACE"
    exit 1
fi

# Resolve DO_TASK file path (absolute or relative to this script)
RALPH_DIR="$(cd "$(dirname "$0")" && pwd)"
DO_TASK_ARG="${2:-python/DO_TASK_PYTHON.md}"
if [[ "$DO_TASK_ARG" == /* ]]; then
    DO_TASK_SOURCE="$DO_TASK_ARG"
else
    DO_TASK_SOURCE="$RALPH_DIR/$DO_TASK_ARG"
fi

if [ ! -f "$DO_TASK_SOURCE" ]; then
    echo "Error: DO_TASK file not found: $DO_TASK_SOURCE"
    exit 1
fi

# Agent selection
RALPH_AGENT="${RALPH_AGENT:-claude}"

# Shared log directory between host and container
LOG_DIR="/tmp/ralph_logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/${RALPH_AGENT}_live_${PROJECT_NAME}.log"

# Create writable temp copy of agent config directory
case "$RALPH_AGENT" in
claude)
    AGENT_CONFIG_TMP=$(mktemp -d /tmp/ralph-claude-XXXXXX)
    # Auth: OAuth credentials + session metadata
    [ -f "$HOME/.claude/.credentials.json" ] && cp -L "$HOME/.claude/.credentials.json" "$AGENT_CONFIG_TMP/" 2>/dev/null || true
    [ -f "$HOME/.claude.json" ] && cp "$HOME/.claude.json" "$AGENT_CONFIG_TMP/.claude.json" 2>/dev/null || true
    # Config: settings and user specs (resolved from symlinks)
    [ -f "$HOME/.claude/settings.json" ] && cp -L "$HOME/.claude/settings.json" "$AGENT_CONFIG_TMP/" 2>/dev/null || true
    [ -d "$HOME/.claude/specs" ] && cp -rL "$HOME/.claude/specs" "$AGENT_CONFIG_TMP/specs" 2>/dev/null || true
    AGENT_CONFIG_DST="/root/.claude"
    ;;
cursor)
    AGENT_CONFIG_TMP=$(mktemp -d /tmp/ralph-cursor-XXXXXX)
    cp -rLp "$HOME/.cursor/." "$AGENT_CONFIG_TMP/" 2>/dev/null || true
    AGENT_CONFIG_DST="/root/.cursor"
    ;;
codex)
    AGENT_CONFIG_TMP=$(mktemp -d /tmp/ralph-codex-XXXXXX)
    cp -rLp "$HOME/.codex/." "$AGENT_CONFIG_TMP/" 2>/dev/null || true
    AGENT_CONFIG_DST="/root/.codex"
    ;;
esac

# Cleanup on exit
MONITOR_PANE=""
cleanup() {
    [ -n "$MONITOR_PANE" ] && tmux kill-pane -t "$MONITOR_PANE" 2>/dev/null || true
    rm -rf "$AGENT_CONFIG_TMP"
}
trap cleanup EXIT

# Setup tmux monitor pane when running interactively
if [ -n "$TMUX" ] && [ -t 1 ]; then
    >"$LOG_FILE"
    MONITOR_PANE=$(tmux split-window -h -P -F "#{pane_id}" \
        "tail -f $LOG_FILE | jq -R --unbuffered 'fromjson? // .'")
    tmux select-pane -L
    echo "Monitor pane created: $MONITOR_PANE"
else
    echo "Warning: Not running in tmux, no live monitor available"
    echo "You can monitor logs manually with: tail -f $LOG_FILE"
fi

# Build auth arguments based on agent and environment
RALPH_AUTH_ARGS=()
case "$RALPH_AGENT" in
claude)
    if [ "${CLAUDE_CODE_USE_BEDROCK}" = "1" ]; then
        RALPH_AUTH_ARGS+=(-v "$HOME/.aws:/root/.aws:ro")
        RALPH_AUTH_ARGS+=(
            -e "AWS_REGION=${AWS_REGION}"
            -e "AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION}"
            -e "AWS_PROFILE=${AWS_PROFILE}"
            -e "CLAUDE_CODE_USE_BEDROCK=1"
        )
        AUTH_MODE="Bedrock"
    elif [ -n "$ANTHROPIC_API_KEY" ]; then
        RALPH_AUTH_ARGS+=(-e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
        AUTH_MODE="API key"
    else
        AUTH_MODE="Subscription (OAuth)"
    fi
    [ -n "$ANTHROPIC_MODEL" ] && RALPH_AUTH_ARGS+=(-e "ANTHROPIC_MODEL=$ANTHROPIC_MODEL")
    [ -n "$ANTHROPIC_SMALL_FAST_MODEL" ] && RALPH_AUTH_ARGS+=(-e "ANTHROPIC_SMALL_FAST_MODEL=$ANTHROPIC_SMALL_FAST_MODEL")
    ;;
cursor)
    RALPH_AUTH_ARGS+=(-e "CURSOR_API_KEY=$CURSOR_API_KEY")
    AUTH_MODE="Cursor API key"
    ;;
codex)
    RALPH_AUTH_ARGS+=(-e "OPENAI_API_KEY=$OPENAI_API_KEY")
    AUTH_MODE="OpenAI API key"
    ;;
esac

echo "=== Ralph Container Launch ==="
echo "Agent:      $RALPH_AGENT"
echo "Workspace:  $WORKSPACE"
echo "DO_TASK:    $DO_TASK_SOURCE"
echo "Auth:       $AUTH_MODE"
echo "Log dir:    $LOG_DIR"
echo ""

# Set Docker TTY flags based on terminal availability
DOCKER_TTY_FLAGS="-i"
[ -t 0 ] && DOCKER_TTY_FLAGS="-it"

docker run $DOCKER_TTY_FLAGS --rm \
    -w "$WORKSPACE" \
    \
    `# Workspace - same-path mount (so directory name is preserved for beads prefix)` \
    -v "$WORKSPACE:$WORKSPACE" \
    \
    `# Agent config directory (writable temp copy — host config is never modified)` \
    -v "$AGENT_CONFIG_TMP:$AGENT_CONFIG_DST" \
    \
    `# Git config and SSH keys for push (read-only)` \
    -v "$HOME/.gitconfig:/root/.gitconfig:ro" \
    -v "$HOME/.ssh:/root/.ssh:ro" \
    \
    `# Shared log directory for host monitoring` \
    -v "$LOG_DIR:$LOG_DIR" \
    \
    `# Auth config (built dynamically based on environment)` \
    "${RALPH_AUTH_ARGS[@]}" \
    \
    `# Ralph script config paths (inside container)` \
    -e "RALPH_AGENT=$RALPH_AGENT" \
    -e "AGENT_CONFIG_DIR=$AGENT_CONFIG_DST" \
    -e "DO_TASK_FILE=/opt/ralph/DO_TASK.md" \
    -e "BOOTSTRAP_FILE=/opt/ralph/BOOTSTRAP.md" \
    -e "VERIFY_FILE=/opt/ralph/VERIFY.md" \
    -e "IS_SANDBOX=1" \
    -e "RALPH_LOG_DIR=$LOG_DIR" \
    -e "RALPH_PROJECT_NAME=$PROJECT_NAME" \
    -e "OTX_KEY_CI=$OTX_KEY_CI" \
    \
    `# Script and task definition - read-only` \
    -v "$RALPH_DIR/ralph-loop.sh:/opt/ralph/ralph-loop.sh:ro" \
    -v "$DO_TASK_SOURCE:/opt/ralph/DO_TASK.md:ro" \
    -v "$RALPH_DIR/BOOTSTRAP.md:/opt/ralph/BOOTSTRAP.md:ro" \
    -v "$RALPH_DIR/VERIFY.md:/opt/ralph/VERIFY.md:ro" \
    \
    "${RALPH_IMAGE:-ralph-loop:latest}"
