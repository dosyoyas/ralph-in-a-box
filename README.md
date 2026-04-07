# ralph-in-a-box

Autonomous software engineering in a container, because YOLO. Give it a plan, walk away, come back to committed code.

![ralph-in-a-box](ralph-in-a-box.jpg)

ralph-in-a-box is a Docker-based implementation of the [Ralph technique](https://ghuntley.com/ralph/) by Geoffrey Huntley. It runs an AI coding agent in a bash loop — one task per iteration — with structured task tracking via [beads](https://beads.sh) (a CLI task tracker, invoked as `bd`), a three-phase pipeline (implement → test → review), automatic bootstrapping from a plain-text action plan, and a verification step that checks plan coverage before pushing.

Supports three agent backends: **Claude Code**, **Cursor Agent**, and **OpenAI Codex**.

Each feature in your plan becomes an **Epic** (a group of related tasks). Each deliverable goes through three phases as individual tasks, identified by prefix: **`[impl]`** (write code), **`[test]`** (run tests), **`[review]`** (lint, simplify, commit). Claude completes one task per iteration, then exits to reset its context window — task descriptions carry context between iterations, not conversation history.

## Architecture

```
ACTION_PLAN.md (you write this)
      │
      ▼
ralph-in-a-box.sh /path/to/project
      │
┌─────┴──────────────────────────────────────────┐
│  Docker container (isolated)                    │
│  ralph-loop.sh                                   │
│                                                 │
│  ┌───────────────────────────────────────────┐  │
│  │ Iteration 0: BOOTSTRAP                    │  │
│  │   Read ACTION_PLAN.md                     │  │
│  │   → bd init                               │  │
│  │   → Create Epics + [impl] tasks           │  │
│  ├───────────────────────────────────────────┤  │
│  │ Iteration 1: [impl] Feature A → [test]    │  │
│  │ Iteration 2: [test] Feature A → [review]  │  │
│  │ Iteration 3: [review] Feature A → commit  │  │
│  │ Iteration 4: [impl] Feature B → [test]    │  │
│  │ ...                                       │  │
│  ├───────────────────────────────────────────┤  │
│  │ Final: VERIFY plan coverage (report only) │  │
│  │        → git push → exit 0                │  │
│  └───────────────────────────────────────────┘  │
└────────────────────────────────────────────────┘
```

Each iteration, Claude picks the highest-priority ready task from beads, executes one phase, creates the next phase task, and exits.

## Workflow

1. **You create** `ACTION_PLAN.md` in your project root (manually or via Claude plan mode)
2. **Bootstrap** reads the plan and creates Epics + `[impl]` tasks in beads
3. **Implement** writes production code, creates `[test]` task
4. **Test** runs the test suite, creates `[review]` task (or retries `[impl]` on failure)
5. **Review** simplifies code, runs linters, commits, closes the Epic
6. **Verify** compares completed tasks against `ACTION_PLAN.md` and prints a coverage report
7. **Landing** pushes all commits to remote

## ACTION_PLAN.md Format

Group deliverables by feature. Each group becomes an Epic, each bullet becomes an `[impl]` task.

```markdown
## Feature 1: User Authentication

- Add login endpoint with JWT token generation
- Add auth middleware for protected routes

## Feature 2: User Profile

- Create profile page with edit capability
- Depends on: auth middleware from Feature 1
```

Cross-group dependencies are supported. The bootstrap agent will use `bd dep add` to enforce ordering.

## Prerequisites

- **Docker** — containers are the only runtime dependency
- **An AI coding agent installed and authenticated on the host** — the container copies the agent's config directory at startup
- **Your project must be a git repository** — ralph-in-a-box commits and pushes code via git

## Agent Backends

ralph-in-a-box supports three AI agent backends, selected via the `RALPH_AGENT` environment variable:

| Agent | `RALPH_AGENT` | Auth | Config dir |
| --- | --- | --- | --- |
| **Claude Code** (default) | `claude` | `ANTHROPIC_API_KEY`, Bedrock, or subscription | `~/.claude` |
| **Cursor Agent** | `cursor` | `CURSOR_API_KEY` | `~/.cursor` |
| **OpenAI Codex** | `codex` | `OPENAI_API_KEY` | `~/.codex` |

All three use the same loop, prompts, beads tasks, and git workflow. The only differences are the agent binary, its CLI flags, and authentication.

### Claude Code authentication

Claude supports three auth modes:

| Mode                        | Setup                                                               | How to run                                                         |
| --------------------------- | ------------------------------------------------------------------- | ------------------------------------------------------------------ |
| **Subscription** (Max plan) | `claude login` on the host                                          | `RALPH_AGENT=claude ./ralph-in-a-box.sh /path/to/project`           |
| **API key**                 | Get key from [console.anthropic.com](https://console.anthropic.com) | `RALPH_AGENT=claude ANTHROPIC_API_KEY=sk-ant-... ./ralph-in-a-box.sh /path/to/project` |
| **AWS Bedrock**             | Configure `~/.aws` credentials                                      | `RALPH_AGENT=claude CLAUDE_CODE_USE_BEDROCK=1 ./ralph-in-a-box.sh /path/to/project`    |

### Cursor Agent authentication

```bash
RALPH_AGENT=cursor CURSOR_API_KEY=cur-... ./ralph-in-a-box.sh /path/to/project
```

### OpenAI Codex authentication

```bash
RALPH_AGENT=codex OPENAI_API_KEY=sk-... ./ralph-in-a-box.sh /path/to/project
```

## Quick Start

### 1. Build the image

Each image is built for a specific agent + language combination using the `AGENT` build arg:

```bash
# Claude (default) — Python
docker build -f python/Dockerfile.python -t ralph-claude-python:latest .

# Claude — Rust
docker build -f rust/Dockerfile.rust -t ralph-claude-rust:latest .

# Cursor — Python
docker build --build-arg AGENT=cursor -f python/Dockerfile.python -t ralph-cursor-python:latest .

# Codex — Python
docker build --build-arg AGENT=codex -f python/Dockerfile.python -t ralph-codex-python:latest .
```

### 2. Create your plan

```bash
cat > /path/to/project/ACTION_PLAN.md << 'EOF'
## Feature 1: Add input validation
- Add validation to all API endpoints
- Add error response formatting
EOF
```

### 3. Run

All agents follow the same invocation pattern:

```bash
# Claude (API key)
RALPH_AGENT=claude \
ANTHROPIC_API_KEY=sk-ant-... \
RALPH_IMAGE=ralph-claude-python:latest \
  ./ralph-in-a-box.sh /path/to/project

# Claude (Bedrock)
RALPH_AGENT=claude \
CLAUDE_CODE_USE_BEDROCK=1 \
RALPH_IMAGE=ralph-claude-python:latest \
  ./ralph-in-a-box.sh /path/to/project

# Cursor
RALPH_AGENT=cursor \
CURSOR_API_KEY=cur-... \
RALPH_IMAGE=ralph-cursor-python:latest \
  ./ralph-in-a-box.sh /path/to/project

# Codex
RALPH_AGENT=codex \
OPENAI_API_KEY=sk-... \
RALPH_IMAGE=ralph-codex-python:latest \
  ./ralph-in-a-box.sh /path/to/project
```

### Rust projects

```bash
docker build --build-arg AGENT=claude -f rust/Dockerfile.rust -t ralph-claude-rust:latest .

RALPH_AGENT=claude \
RALPH_IMAGE=ralph-claude-rust:latest \
  ./ralph-in-a-box.sh /path/to/project rust/DO_TASK_RUST.md
```

### What to expect

A typical run with 2 features (4 deliverables) takes **8-12 iterations** and **5-15 minutes** depending on project complexity. You'll see output like:

```
═══════════════════════════════════════════════════════════
ITERATION 1/50 | Cost: $0.00/$100.00 | Agent: claude
═══════════════════════════════════════════════════════════
Tasks: 2 ready, 4 total open
---
[TOOL] Bash: bd show abc123...
[TOOL] Write: src/validation.py...
[TOOL] Bash: bd close abc123...
---
[COST] This run: $0.27 | Total: $0.27
```

The loop exits automatically when all tasks are completed (exit code 0), or stops early if it hits `MAX_ITERATIONS` (exit code 3) or `MAX_COST` (exit code 4). If a task gets stuck, it exits with code 2 for manual intervention.

## Pipeline Phases

| Phase     | Prefix     | On Success                    | On Failure                 |
| --------- | ---------- | ----------------------------- | -------------------------- |
| Bootstrap | —          | Create Epics + `[impl]` tasks | Exit with error            |
| Implement | `[impl]`   | Create `[test]` task          | Report blocker             |
| Test      | `[test]`   | Create `[review]` task        | Reopen `[impl]` with error |
| Review    | `[review]` | Commit + close Epic           | Reopen `[test]` with error |
| Verify    | —          | Print coverage report         | — (informational only)     |

Failures retry up to 3 times before creating a blocker task for manual intervention.

### Verification

When all tasks are completed and `ACTION_PLAN.md` exists, ralph-in-a-box runs one final Claude invocation to compare the plan against completed tasks. The output is a coverage report:

```
ACTION_PLAN.md Coverage Report
══════════════════════════════

## User Authentication
  ✓ Add login endpoint with JWT tokens → [impl] Add login endpoint (closed)
  ✓ Add auth middleware → [impl] Add auth middleware (closed)

## User Profile
  ✓ Create profile page → [impl] Create profile page (closed)

Coverage: 3/3 deliverables completed
```

This is informational only — it never blocks the push or creates new tasks. If you see gaps, re-run manually after investigation.

## Configuration

All settings are environment variables, passed before `ralph-in-a-box.sh`:

| Variable                     | Default                 | Description                                                                       |
| ---------------------------- | ----------------------- | --------------------------------------------------------------------------------- |
| `RALPH_AGENT`                | `claude`                | Agent backend: `claude`, `cursor`, or `codex`                                     |
| `RALPH_IMAGE`                | `ralph-loop:latest`     | Docker image to use                                                               |
| `MAX_ITERATIONS`             | `50`                    | Maximum loop iterations before stopping                                           |
| `MAX_COST`                   | `100.00`                | Maximum spend in USD before stopping (Claude only — other agents don't report cost) |
| `ANTHROPIC_API_KEY`          | —                       | Claude auth — API key for direct API billing                                      |
| `CLAUDE_CODE_USE_BEDROCK`    | —                       | Claude auth — set to `1` to use AWS Bedrock (mounts `~/.aws` read-only)           |
| `CURSOR_API_KEY`             | —                       | Cursor auth — API key                                                             |
| `OPENAI_API_KEY`             | —                       | Codex auth — API key                                                              |
| `ANTHROPIC_MODEL`            | —                       | Override the Claude model (works with all Claude auth modes)                      |
| `ANTHROPIC_SMALL_FAST_MODEL` | —                       | Override the small/fast model (Claude only)                                       |
| `AWS_PROFILE`                | —                       | AWS profile to use (Bedrock mode only)                                            |
| `AWS_REGION`                 | —                       | AWS region (Bedrock mode only)                                                    |

The phase executor prompt is selected via the second positional argument to `ralph-in-a-box.sh` (defaults to `python/DO_TASK_PYTHON.md`):

```bash
RALPH_AGENT=claude MAX_ITERATIONS=20 MAX_COST=10.00 ./ralph-in-a-box.sh /path/to/project
RALPH_AGENT=cursor MAX_ITERATIONS=20 RALPH_IMAGE=ralph-cursor-rust:latest ./ralph-in-a-box.sh /path/to/project rust/DO_TASK_RUST.md
```

## Container Isolation

The Docker boundary is the security perimeter. The agent runs with permission-skipping flags inside the container — the container itself limits what it can reach.

| Mount                          | Path in Container         | Access     | Condition    |
| ------------------------------ | ------------------------- | ---------- | ------------ |
| Project workspace              | `/workspace`              | read/write | Always       |
| Agent config dir (temp copy)   | `/root/.claude`, `/root/.cursor`, or `/root/.codex` | read/write | Always |
| `~/.aws`                       | `/root/.aws`              | read-only  | Bedrock only |
| `ralph-loop.sh`                 | `/opt/ralph/ralph-loop.sh` | read-only  | Always       |
| `DO_TASK.md`                   | `/opt/ralph/DO_TASK.md`   | read-only  | Always       |
| `BOOTSTRAP.md`                 | `/opt/ralph/BOOTSTRAP.md` | read-only  | Always       |
| `VERIFY.md`                    | `/opt/ralph/VERIFY.md`    | read-only  | Always       |

## Project Conventions with CLAUDE.md

Claude Code natively reads `CLAUDE.md` files from your project root and subdirectories. Use this to set coding conventions, approved libraries, and architectural rules that apply to every iteration.

For teams building a reusable library of conventions across projects, a practical pattern:

```
# Your shared convention library (separate repo or directory)
~/coding-specs/
  python_testing.md       # "Use pytest, fixtures over mocks, ..."
  jwt_auth.md             # "Use PyJWT, RS256, rotate keys ..."
  rest_conventions.md     # "Use plural nouns, paginate with cursor ..."

# Per project: symlink or copy the relevant subset
myproject/
  CLAUDE.md               # Project-specific rules + "Read all files in specs/"
  specs/
    python_testing.md → ~/coding-specs/python_testing.md
    jwt_auth.md → ~/coding-specs/jwt_auth.md
  ACTION_PLAN.md
```

Your project's `CLAUDE.md` just needs one line to pull in the specs:

```markdown
Before starting any task, read all files in the specs/ directory if it exists.
```

This gives you composable, per-project conventions without any ralph-in-a-box code changes — it works today with standard Claude Code behavior.

## Live Monitoring

When running inside tmux, `ralph-in-a-box.sh` creates a vertical split pane that tails the JSON log stream:

```bash
tail -f /tmp/ralph_logs/<agent>_live_<project>.log | jq -R 'fromjson? // .'
```

Without tmux, monitor manually:

```bash
# Log file is named after the agent: claude_live_*, cursor_live_*, or codex_live_*
tail -f /tmp/ralph_logs/claude_live_<project>.log
```

## Exit Codes

| Code  | Meaning                                |
| ----- | -------------------------------------- |
| `0`   | All tasks completed, changes pushed    |
| `1`   | No tasks and no ACTION_PLAN.md found   |
| `2`   | Blocked — manual intervention required |
| `3`   | MAX_ITERATIONS reached                 |
| `4`   | MAX_COST exceeded (Claude only)        |
| other | Agent error                            |

## Manual Task Creation

If you prefer to skip the bootstrap phase and create tasks directly. This requires [beads](https://beads.sh) (`bd`) installed on your host machine — bootstrap handles this automatically inside the container, so most users won't need this:

```bash
cd /path/to/your/project
bd init --stealth
bd create "Epic: your feature" --type epic --priority 0
bd create "[impl] implement your feature" \
  --parent <epic-id> \
  --type task \
  --priority 0 \
  --description "What needs to be done. RETRY: 0"
```

Bootstrap is skipped when `.beads` already exists (whether tasks are open or all closed). To re-bootstrap from scratch, remove the beads directory and run again:

```bash
rm -rf /path/to/project/.beads
./ralph-in-a-box.sh /path/to/project
```

## Test Projects

`test_projects/` contains minimal standalone workspaces used to validate the pipeline:

| Directory                     | Language | What it tests                                 |
| ----------------------------- | -------- | --------------------------------------------- |
| `test_projects/test_python/`  | Python   | Stats utilities — pytest + ruff pipeline      |
| `test_projects/test_rust/`    | Rust     | Math utilities — cargo test + clippy pipeline |
| `test_projects/test_generic/` | Python   | Generic string utilities                      |
| `test_projects/test_direct/`  | Python   | Direct task execution (pre-created tasks)     |
| `test_projects/test_agents/`  | Python   | Multi-agent variant                           |

Each is an independent git repository. To run a full pipeline test from an `ACTION_PLAN.md`:

```bash
# Remove any existing beads state
rm -rf test_projects/test_python/.beads

# Run
./ralph-in-a-box.sh test_projects/test_python
```

## Credits

This project is a direct implementation of the Ralph technique described by Geoffrey Huntley:

- [Ralph Wiggum as a "software engineer"](https://ghuntley.com/ralph/) — the original technique, the loop philosophy, and prompt engineering for agentic loops
- [Everything is a ralph loop](https://ghuntley.com/loop/) — Ralph as a mindset: the loop as the fundamental unit of software construction

> _"Ralph is monolithic. Ralph works autonomously in a single repository as a single process that performs one task per loop."_
> — Geoffrey Huntley
