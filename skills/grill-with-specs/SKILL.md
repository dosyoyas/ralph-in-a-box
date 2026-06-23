---
name: grill-with-specs
description: Grilling session that challenges your plan against the existing domain model, sharpens terminology, and updates documentation (specs/CONTEXT.md, specs/) inline as decisions crystallise. Use when user wants to stress-test a plan against their project's language and documented specs.
---

<what-to-do>

Interview me relentlessly about every aspect of this plan until we reach a shared understanding. Walk down each branch of the design tree, resolving dependencies between decisions one-by-one. For each question, provide your recommended answer.

Ask the questions one at a time, waiting for feedback on each question before continuing.

If a question can be answered by exploring the codebase, explore the codebase instead.

</what-to-do>

<supporting-info>

**Always write all documentation (`specs/`, `specs/CONTEXT.md`, `specs/README.md`) in English**, regardless of the language used in the conversation or the user's prompt.

## Domain awareness

During codebase exploration, also look for existing documentation under `specs/`:

### File structure

Specs live in a single `specs/` directory at the repo root, indexed by a keyword-driven `README.md`:

```
/
├── specs/
│   ├── README.md          ← keyword index pointing at each spec
│   ├── CONTEXT.md          ← glossary (the project's language)
│   ├── architecture.md
│   ├── backend-api.md
│   └── frontend.md
└── src/
```

Specs are living documentation kept **in sync with the code**. Git carries their history, so there is no need to record *that* a decision was made or *when* — the spec describes how the component works **right now**.

Create files lazily — only when you have something to write. If no `specs/` exists, create it (with `README.md` and `CONTEXT.md`) when the first term is resolved or the first spec is needed.

## During the session

### Challenge against the glossary

When the user uses a term that conflicts with the existing language in `specs/CONTEXT.md`, call it out immediately. "Your glossary defines 'cancellation' as X, but you seem to mean Y — which is it?"

### Sharpen fuzzy language

When the user uses vague or overloaded terms, propose a precise canonical term. "You're saying 'account' — do you mean the Customer or the User? Those are different things."

### Discuss concrete scenarios

When domain relationships are being discussed, stress-test them with specific scenarios. Invent scenarios that probe edge cases and force the user to be precise about the boundaries between concepts.

### Cross-reference with code

When the user states how something works, check whether the code agrees. If you find a contradiction, surface it: "Your code cancels entire Orders, but you just said partial cancellation is possible — which is right?"

Specs must agree with the code. If a spec under `specs/` contradicts the current code, surface it — either the spec is stale and should be updated, or the code drifted from intent.

### Update specs/CONTEXT.md inline

When a term is resolved, update `specs/CONTEXT.md` right there. Don't batch these up — capture them as they happen. Use the format in [CONTEXT-FORMAT.md](./CONTEXT-FORMAT.md).

`CONTEXT.md` should be totally devoid of implementation details. Do not treat `CONTEXT.md` as a spec, a scratch pad, or a repository for implementation decisions. It is a glossary and nothing else.

### Update specs inline

When the design of a component crystallises, write or update its spec under `specs/` right there, and add or refresh its entry in `specs/README.md`. Use the format in [SPEC-FORMAT.md](./SPEC-FORMAT.md).

A spec describes how a component works today: its contract, its boundaries, and the non-obvious reasons behind its shape. Because the spec lives in the repo alongside the code, keep it current rather than append-only — when behaviour changes, edit the spec to match, don't journal the change.

</supporting-info>
