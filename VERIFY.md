# VERIFY: Coverage Report

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
