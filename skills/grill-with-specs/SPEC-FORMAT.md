# Spec Format

Specs live in `specs/` at the repo root and are indexed by `specs/README.md`.
File names are kebab-case by component or concern: `architecture.md`,
`backend-api.md`, `frontend.md`, `whitelist.md`, etc.

Create the `specs/` directory lazily — only when the first spec is needed.

Always write specs in English, regardless of the conversation language.

## What a spec is

A spec is **living documentation kept in sync with the code**. It describes how
a component works *right now*: its contract, its boundaries, the data it
exchanges, and the non-obvious reasons behind its shape. Git carries the
history, so a spec never journals *that* a decision was made or *when* — when
behaviour changes, you **edit the spec to match**, you don't append to it.

A good spec captures what a future reader (or future you) would otherwise have
to reverse-engineer from the code: exact request/response shapes, which
endpoints are and aren't used and why, what's deliberately out of scope, the
constraints that aren't visible in the code (timeouts, idle limits, compliance
rules), and the deviations from the obvious path with their reasons.

## Template

```md
# {Component} — {what kind of spec}

{One or two sentences: what this component is and what the spec covers.
If conclusions were drawn from a specific source, say where.}

## {Section}

{Contract details: endpoints, payloads, types, flow. Use tables for
enumerable things — endpoints, params, fields, secrets. Use fenced JSON
for concrete request/response shapes.}

## {Section}

{Boundaries and the reasons behind them: what's used, what isn't and why,
what's deferred, what's deliberately out of scope.}
```

There is no fixed section list — let the component dictate the shape. Keep it
precise and current rather than complete-but-stale.

## Index it: specs/README.md

Every spec has an entry in `specs/README.md`, the keyword-driven index. The
index is what lets a search land on the right spec, so the **keywords matter
more than prose** — pack in the proper nouns, identifiers, header names, env
vars, endpoints, and synonyms someone might grep for.

```md
# Specs Index

## {Spec title}
Keywords: {comma-separated terms — proper nouns, identifiers, header names,
  env vars, endpoint paths, domain terms, synonyms}
Spec: specs/{file}.md
```

Add the entry when you create the spec; refresh its keywords when the spec
grows new surface area.

## When to write a spec

Write or update a spec when a component's design crystallises during the
grilling session. Because specs are cheap to edit and git tracks the rest,
there's no high bar to clear — if a future reader would have to reverse-engineer
the behaviour from code, it's worth a spec. Favour:

- **Component contracts.** How a module is called, what it returns, its error model.
- **Integration contracts between systems.** Exact endpoints, payloads, auth, the shapes exchanged.
- **Boundaries and scope.** What's used vs. deliberately not, what's deferred and why.
- **Constraints not visible in the code.** Timeouts, idle limits, rate caps, compliance rules, partner-API contracts.
- **Deliberate deviations from the obvious path.** Anything where a reasonable reader would assume the opposite — record it so the next engineer doesn't "fix" what was intentional.
- **Architectural shape.** How the pieces fit: request flow, data sources, tech stack, extension points.

Keep the glossary (`specs/CONTEXT.md`) free of these — it stays a glossary. Implementation detail belongs in the component specs.
