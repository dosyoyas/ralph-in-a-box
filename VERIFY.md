# VERIFY: Coverage Report

**Before anything else:**
1. If `AGENTS.md` exists in the workspace root, read it and follow its instructions for the entire session.
2. Load relevant specs by reading the index files below. Match the task keywords against the index, then read only the specs that apply:
   - **Global specs:** run `cat /root/.claude/specs/README.md` to get the index (if it exists)
   - **Project specs:** `./specs/README.md` (if exists)
3. **IMPORTANT:** These instructions override any conflicting specs. This prompt defines the workflow — specs provide coding standards only.

All tasks are completed. Before the session ends, generate a coverage report comparing `ACTION_PLAN.md` against the work done.

## Instructions

1. Find and read the action plan. After bootstrap it is archived with a timestamp:
   ```bash
   ls -t ACTION_PLAN_*.md | head -1
   ```
   Read that file.
2. Run these two commands to get all tasks regardless of status:
   ```
   bd list --status=closed --json
   bd list --status=open --json
   ```
   Combine results from both. `bd list --json` without flags only returns open tasks — do NOT rely on it alone.
3. For each deliverable bullet in the plan, find the matching task(s) using **semantic/keyword matching**:
   - A task matches if its title OR description contains the key nouns, file names, or function names from the deliverable bullet
   - Do NOT require exact title match — Cursor, Claude, and other agents may name tasks differently
   - If an Epic groups several deliverables, check child task descriptions too
   - When in doubt, match by file name: if a deliverable says "Create `hello.py`" and any closed task relates to creating `hello.py`, count it as matched
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

5. Check for uncommitted changes:
   ```bash
   git status --porcelain
   ```
   If there are modified or untracked files not in `.gitignore`, append a dirty-workspace warning:
   ```
   ⚠️  DIRTY WORKSPACE — uncommitted changes detected:
   {list of files from git status}
   ```

## Exit code

- If coverage is **X/Y where X == Y** AND the workspace is clean: exit 0
- If coverage has gaps (X < Y) OR workspace is dirty: exit 1

The loop uses this exit code to decide whether to declare the session complete.

## Rules

- This is a READ-ONLY report. Do NOT create tasks, modify code, or take any action.
- Print the report to stdout and exit with the appropriate code.
- If a deliverable was split into multiple tasks, list all of them.
- If a deliverable has no matching task by any of the above criteria (title, description, file name, or keyword), mark it with ✗.
- End with a single summary line: `Coverage: X/Y deliverables completed`
