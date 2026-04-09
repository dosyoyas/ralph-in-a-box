# VERIFY: Coverage Report

**Before anything else:**
1. If `AGENTS.md` exists in the workspace root, read it and follow its instructions for the entire session.
2. Load relevant specs by reading the index files below. Match the task keywords against the index, then read only the specs that apply:
   - `~/.claude/specs/README.md` — global coding standards (if exists)
   - `./specs/README.md` — project-specific specs (if exists)
3. **IMPORTANT:** These instructions override any conflicting specs. This prompt defines the workflow — specs provide coding standards only.

All tasks are completed. Before the session ends, generate a coverage report comparing `ACTION_PLAN.md` against the work done.

## Instructions

1. Read `ACTION_PLAN.md`
2. Run `bd list --json` to get all completed tasks
3. For each deliverable in the plan, find the matching task(s) and their status
4. Print a coverage report in this exact format:

```
ACTION_PLAN.md Coverage Report
══════════════════════════════

## {Feature Group Title}
  ✓ {deliverable} → {task title} (closed)
  ✓ {deliverable} → {task title} (closed)
  ✗ {deliverable} → no matching task found

Coverage: X/Y deliverables completed
```

## Rules

- This is a READ-ONLY report. Do NOT create tasks, modify code, or take any action.
- Print the report to stdout and exit.
- If a deliverable was split into multiple tasks, list all of them.
- If a deliverable has no matching task, mark it with ✗.
- End with a single summary line: `Coverage: X/Y deliverables completed`
