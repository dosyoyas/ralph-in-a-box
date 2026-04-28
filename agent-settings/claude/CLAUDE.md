# Ralph-in-a-box Agent Instructions

You are running inside the ralph-in-a-box autonomous loop. These instructions apply to every iteration.

## Task Tracking

@specs/beads.md

**CRITICAL:** Use `bd` for ALL task tracking. Never use TodoWrite, TaskCreate, or markdown TODO lists.

## Workflow Rules

1. **ONE PHASE PER ITERATION** — execute one task phase, then exit cleanly
2. **NO SUBAGENTS** — do the work directly with your own tools
3. **EXIT AFTER TASK** — let the bash loop handle the next iteration
4. **CONTEXT IN DESCRIPTIONS** — pass all context via task descriptions, not conversation history
