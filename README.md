# ralph-in-a-box

Autonomous software engineering in a container, because YOLO. Give it a plan, walk away, come back to committed code.

ralph-in-a-box is a Docker-based implementation of the [Ralph technique](https://ghuntley.com/ralph/) by Geoffrey Huntley. It runs [Claude Code](https://docs.anthropic.com/en/docs/claude-code) in a bash loop — one task per iteration — with structured task tracking via [beads](https://beads.sh) (a CLI task tracker, invoked as `bd`), a three-phase pipeline (implement → test → review), automatic bootstrapping from a plain-text action plan, and a verification step that checks plan coverage before pushing.

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
- **[Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated on the host** — the container copies `~/.claude` at startup
- **Your project must be a git repository** — ralph-in-a-box commits and pushes code via git

ralph-in-a-box supports three authentication modes:

| Mode                        | Setup                                                               | How to run                                                         |
| --------------------------- | ------------------------------------------------------------------- | ------------------------------------------------------------------ |
| **Subscription** (Max plan) | `claude login` on the host                                          | `./ralph-in-a-box.sh /path/to/project`                              |
| **API key**                 | Get key from [console.anthropic.com](https://console.anthropic.com) | `ANTHROPIC_API_KEY=sk-ant-... ./ralph-in-a-box.sh /path/to/project` |
| **AWS Bedrock**             | Configure `~/.aws` credentials                                      | `CLAUDE_CODE_USE_BEDROCK=1 ./ralph-in-a-box.sh /path/to/project`    |

The default (no env vars) uses the OAuth session from `~/.claude/`, which is what you get with a Claude Code subscription (Max plan). Just run `claude login` once before using ralph-in-a-box.

## Quick Start

### Python projects

```bash
# 1. Build the image (once)
docker build -f Dockerfile.python -t ralph-in-a-box:latest .

# 2. Create your plan in the project root
cat > /path/to/project/ACTION_PLAN.md << 'EOF'
## Feature 1: Add input validation
- Add validation to all API endpoints
- Add error response formatting
EOF

# 3. Run
./ralph-in-a-box.sh /path/to/project
```

For API key or Bedrock auth, prefix with the relevant env var (see [Prerequisites](#prerequisites)).

### Rust projects

```bash
docker build -f Dockerfile.rust -t ralph-in-a-box-rust:latest .
RALPH_IMAGE=ralph-in-a-box-rust:latest ./ralph-in-a-box.sh /path/to/project DO_TASK_RUST.md
```

### What to expect

A typical run with 2 features (4 deliverables) takes **8-12 iterations** and **5-15 minutes** depending on project complexity. You'll see output like:

```
═══════════════════════════════════════════════════════════
ITERATION 1/50 | Cost: $0.00/$100.00
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
| `MAX_ITERATIONS`             | `50`                    | Maximum loop iterations before stopping                                           |
| `MAX_COST`                   | `100.00`                | Maximum spend in USD before stopping (API/Bedrock only — subscription reports $0) |
| `RALPH_IMAGE`                | `ralph-in-a-box:latest` | Docker image to use                                                               |
| `CLAUDE_CODE_USE_BEDROCK`    | —                       | Set to `1` to use AWS Bedrock (mounts `~/.aws` read-only)                         |
| `ANTHROPIC_API_KEY`          | —                       | API key for direct API billing                                                    |
| `ANTHROPIC_MODEL`            | —                       | Override the Claude model (works with all auth modes)                             |
| `ANTHROPIC_SMALL_FAST_MODEL` | —                       | Override the small/fast model                                                     |
| `AWS_PROFILE`                | —                       | AWS profile to use (Bedrock mode only)                                            |
| `AWS_REGION`                 | —                       | AWS region (Bedrock mode only)                                                    |

The phase executor prompt is selected via the second positional argument to `ralph-in-a-box.sh` (defaults to `DO_TASK_PYTHON.md`):

```bash
MAX_ITERATIONS=20 MAX_COST=10.00 ./ralph-in-a-box.sh /path/to/project
MAX_ITERATIONS=20 MAX_COST=10.00 RALPH_IMAGE=ralph-in-a-box-rust:latest ./ralph-in-a-box.sh /path/to/project DO_TASK_RUST.md
```

## Container Isolation

The Docker boundary is the security perimeter. Claude runs with `--dangerously-skip-permissions` inside the container — the container itself limits what it can reach.

| Mount                   | Path in Container         | Access     | Condition    |
| ----------------------- | ------------------------- | ---------- | ------------ |
| Project workspace       | `/workspace`              | read/write | Always       |
| `~/.claude` (temp copy) | `/root/.claude`           | read/write | Always       |
| `~/.aws`                | `/root/.aws`              | read-only  | Bedrock only |
| `ralph-loop.sh`          | `/opt/ralph/ralph-loop.sh` | read-only  | Always       |
| `DO_TASK.md`            | `/opt/ralph/DO_TASK.md`   | read-only  | Always       |
| `BOOTSTRAP.md`          | `/opt/ralph/BOOTSTRAP.md` | read-only  | Always       |
| `VERIFY.md`             | `/opt/ralph/VERIFY.md`    | read-only  | Always       |

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
tail -f /tmp/ralph_logs/claude_live_<project>.log | jq -R 'fromjson? // .'
```

Without tmux, monitor manually:

```bash
tail -f /tmp/ralph_logs/claude_live_<project>.log
```

## Exit Codes

| Code  | Meaning                                |
| ----- | -------------------------------------- |
| `0`   | All tasks completed, changes pushed    |
| `1`   | No tasks and no ACTION_PLAN.md found   |
| `2`   | Blocked — manual intervention required |
| `3`   | MAX_ITERATIONS reached                 |
| `4`   | MAX_COST exceeded                      |
| other | Claude error                           |

## Manual Task Creation

If you prefer to skip the bootstrap phase and create tasks directly. This requires [beads](https://beads.sh) (`bd`) installed on your host machine — bootstrap handles this automatically inside the container, so most users won't need this:

```bash
cd /path/to/your/project
bd init
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
