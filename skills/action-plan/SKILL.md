---
name: action-plan
description: Break a plan, spec, or PRD into an ACTION_PLAN.md of independently-grabbable deliverables using tracer-bullet vertical slices. Use when user wants to turn a plan into an action plan, break work into deliverables, or produce an implementation plan.
---

# Action Plan

Break a plan into independently-grabbable deliverables using vertical slices
(tracer bullets), and write them to `ACTION_PLAN.md` at the workspace root.

**Always write `ACTION_PLAN.md` in English**, regardless of the language used in
the source plan, the conversation, or the user's prompt.

The output is a single self-contained artifact: a human reviews it, git versions
it, and a downstream process turns it into whatever task structure it needs. The
command is agnostic about that downstream — its only contract is the
`ACTION_PLAN.md` format below.

## Process

### 1. Gather context

Work from whatever is already in the conversation context. If the user passes a
reference (a file path, an issue URL, a doc) as an argument, read its full
contents first.

### 2. Explore the codebase (optional)

If you have not already explored the codebase, do so to understand the current
state of the code. Deliverable titles and descriptions should use the project's
domain vocabulary from `specs/CONTEXT.md`, and respect the specs under `specs/`
in the area you're touching. If a spec contradicts the plan, surface it before
drafting.

### 3. Draft vertical slices

Break the plan into **tracer bullet** deliverables. Each deliverable is a thin
vertical slice that cuts through ALL integration layers end-to-end, NOT a
horizontal slice of one layer.

Slices may be 'HITL' or 'AFK'. HITL slices require human interaction, such as an
architectural decision or a design review. AFK slices can be implemented and
merged without human interaction. Prefer AFK over HITL where possible.

<vertical-slice-rules>
- Each slice delivers a narrow but COMPLETE path through every layer (schema, API, UI, tests)
- A completed slice is demoable or verifiable on its own
- Each slice is test-first: it is defined by an end-to-end test that fails before any implementation and passes once the slice is done. This test IS what makes the slice "verifiable on its own".
- Prefer many thin slices over few thick ones
</vertical-slice-rules>

Group related slices into **features** — a logical cluster of deliverables
(e.g., "Authentication", "API endpoints", "Database schema").

### 4. Quiz the user

Present the proposed breakdown as a numbered list. For each slice, show:

- **Title**: short descriptive name
- **Type**: HITL / AFK
- **Blocked by**: which other slices (if any) must complete first
- **User stories covered**: which user stories this addresses (if the source material has them)

Ask the user:

- Does the granularity feel right? (too coarse / too fine)
- Are the dependency relationships correct?
- Should any slices be merged or split further?
- Are the correct slices marked as HITL and AFK?

Iterate until the user approves the breakdown.

### 5. Write ACTION_PLAN.md

Once approved, write the breakdown to `ACTION_PLAN.md` at the workspace root
using the format below. If the file already exists, ask before overwriting.

Order features so that a feature appears after anything it depends on. Within a
feature, order deliverables so blockers come first. Reference a blocker by its
exact deliverable title so the dependency can be resolved by name.

<action-plan-format>
```md
# Action Plan: {plan title}

{One or two sentences on the overall goal of this plan.}

## Feature 1: {feature title}

### {Deliverable title}

**Type:** AFK | HITL
**Blocked by:** None — can start immediately. | {exact title of the blocking deliverable}

{A concise description of this vertical slice. Describe the end-to-end behavior,
not layer-by-layer implementation.}

{Avoid specific file paths or code snippets — they go stale fast. Exception: if a
prototype produced a snippet that encodes a decision more precisely than prose can
(state machine, reducer, schema, type shape), inline it here and note briefly that
it came from a prototype. Trim to the decision-rich parts.}

**Acceptance criteria:**
- [ ] Given {context}, when {action}, then {observable end-to-end outcome}
- [ ] Given {context}, when {action}, then {observable end-to-end outcome}
- [ ] Given {context}, when {action}, then {observable end-to-end outcome}

### {Next deliverable title}

...

## Feature 2: {feature title}

...
```
</action-plan-format>

<format-rules>
- **`## Feature N:` per feature group.** One heading per logical cluster.
- **`### Title` per deliverable.** Each deliverable is one `###` sub-heading under its feature. This is the unit a downstream process counts — keep one slice per heading.
- **Acceptance criteria are `- [ ]` checkboxes** expressed as testable end-to-end behaviors (given/when/then), so each one maps directly to a failing test the implementer writes first. Describe observable outcomes, not implementation tasks. Stay at the end-to-end/acceptance level — do not enumerate unit tests; those are the implementer's call. Derive criteria from the plan's language; if the plan is too vague to derive concrete behaviors, copy the deliverable verbatim as a single criterion rather than inventing specifics.
- **Self-contained deliverables.** Each `###` block must carry enough context to be implemented without re-reading the source plan.
- **Preserve plan language.** Copy requirements verbatim into descriptions and criteria where possible.
- **File paths as hints, not constraints.** Mention existing files as starting points only; don't invent paths.
</format-rules>

After writing the file, print a short confirmation: the number of features and
deliverables written, and the path to `ACTION_PLAN.md`.
