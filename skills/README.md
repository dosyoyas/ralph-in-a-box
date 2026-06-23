# Planning skills

Claude Code skills used **before** launching the loop, to produce a sharp,
well-aligned `ACTION_PLAN.md`. They run in a normal interactive Claude Code
session on the host — the ralph container never uses them, so no loop
configuration changes are needed.

A strong plan is the single biggest lever on output quality (see the main
[README](../README.md#recommended-plan-with-the-skills-first)). Recommended
sequence:

```text
grill-with-specs  →  action-plan  →  (review ACTION_PLAN.md)  →  ./ralph-in-a-box.sh
```

## Skills

- **[`grill-with-specs/`](grill-with-specs/)** — a relentless plan-grilling
  interview that resolves design decisions one-by-one, sharpens terminology, and
  writes/updates `specs/` (including a `specs/CONTEXT.md` glossary) inline as
  decisions crystallise.
- **[`action-plan/`](action-plan/)** — breaks the grilled plan into
  independently-grabbable, test-first vertical slices (tracer bullets) grouped
  into features with explicit dependencies, written to `ACTION_PLAN.md`.

## Installing

Expose the skills to your Claude Code session, e.g.:

```bash
# symlink each skill into your user skills dir
ln -s "$PWD/skills/grill-with-specs" ~/.claude/skills/grill-with-specs
ln -s "$PWD/skills/action-plan"      ~/.claude/skills/action-plan
```

Then invoke them with `/grill-with-specs` and `/action-plan`.

## Credits

Both skills are based on [Matt Pocock's skills](https://github.com/mattpocock/skills),
adapted here for the ralph planning workflow.
