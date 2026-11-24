#!/usr/bin/env python3
"""Turn ACTION_PLAN.md into beads Epics + [impl] tasks + the [audit] task, without an agent.

Same structure BOOTSTRAP.md asks the agent for:
  ## Feature N: title     -> Epic
  ### deliverable         -> [impl] task (plan text verbatim, ACs numbered, dependencies from "Blocked by")
  any other ## section    -> shared context copied into every task
  plus one [audit] Epic/task depending on every [impl] task.

Exit codes:
  0  tasks created
  2  the plan cannot be parsed with certainty; NOTHING was created, run the agent BOOTSTRAP instead
  3  beads failed after creating some tasks (do not fall back: it would duplicate them)
"""
import json
import os
import re
import subprocess
import sys

PLAN = sys.argv[1] if len(sys.argv) > 1 else "ACTION_PLAN.md"
CHECKBOX = re.compile(r"^\s*-\s*\[[ xX]\]\s*(.*)$")


class Unparseable(Exception):
    pass


def parse(text):
    """Return (features, shared). features: [{title, deliverables: [{title, body, criteria, blocked_by}]}]."""
    features, shared = [], []
    overview = {"title": "Plan overview", "lines": []}  # text before the first '##' applies to every task
    shared.append(overview)
    section = ("shared", overview)  # ("feature", obj) | ("shared", block)
    deliverable = None
    for line in text.splitlines():
        if line.startswith("# "):
            continue
        if line.startswith("## "):
            heading = line[3:].strip()
            deliverable = None
            m = re.match(r"Feature\s+\d+\s*[:.\-–—]\s*(.+)", heading, re.I)
            if m:
                feat = {"title": m.group(1).strip(), "deliverables": []}
                features.append(feat)
                section = ("feature", feat)
            else:
                block = {"title": heading, "lines": []}
                shared.append(block)
                section = ("shared", block)
        elif line.startswith("### ") and section and section[0] == "feature":
            deliverable = {"title": line[4:].strip(), "lines": []}
            section[1]["deliverables"].append(deliverable)
        elif deliverable is not None:
            deliverable["lines"].append(line)
        elif section and section[0] == "shared":
            section[1]["lines"].append(line)

    for feat in features:
        for d in feat["deliverables"]:
            body, criteria, current = [], [], None
            for line in d["lines"]:
                m = CHECKBOX.match(line)
                if m:
                    current = [m.group(1).strip()]
                    criteria.append(current)
                elif current is not None and line.startswith((" ", "\t")) and line.strip():
                    current.append(line.strip())  # continuation of a checkbox
                else:
                    current = None
                    body.append(line)
            d["body"] = "\n".join(body).strip()
            d["criteria"] = [" ".join(c) for c in criteria]
            m = re.search(r"\*{0,2}Blocked by:?\*{0,2}:?\s*(.+)", d["body"])
            d["blocked_text"] = m.group(1).strip() if m else ""
            del d["lines"]
    shared_text = "\n\n".join(
        f"## {b['title']}\n" + "\n".join(b["lines"]).strip() for b in shared if "\n".join(b["lines"]).strip()
    )
    return features, shared_text


def validate(features):
    if not features:
        raise Unparseable("no '## Feature N:' headings")
    titles = []
    for feat in features:
        if not feat["deliverables"]:
            raise Unparseable(f"feature '{feat['title']}' has no '###' deliverables")
        for d in feat["deliverables"]:
            if not d["criteria"]:
                raise Unparseable(f"deliverable '{d['title']}' has no '- [ ]' acceptance criteria")
            if d["title"] in titles:
                raise Unparseable(f"duplicate deliverable title '{d['title']}'")
            titles.append(d["title"])
    # Every "Blocked by" must be "None..." or name known deliverables; anything else is ambiguous.
    for feat in features:
        for d in feat["deliverables"]:
            d["blockers"] = blockers_of(d, titles)


def blockers_of(d, titles):
    text = d["blocked_text"]
    if not text or re.match(r"none\b", text, re.I):
        return []
    found, rest = [], text
    for t in sorted(titles, key=len, reverse=True):
        if t in rest and t != d["title"]:
            found.append(t)
            rest = rest.replace(t, "")
    if not found:
        raise Unparseable(f"deliverable '{d['title']}': cannot resolve 'Blocked by: {text}'")
    return found


def bd(*args):
    r = subprocess.run(["bd", *args], capture_output=True, text=True, stdin=subprocess.DEVNULL)  # never wait for a TTY
    if r.returncode:
        raise RuntimeError(f"bd {' '.join(args[:2])} failed: {r.stderr.strip() or r.stdout.strip()}")
    return r.stdout


MAX_PRIORITY = 4  # bd accepts only 0-4; later deliverables/Features share 4 and `Blocked by` still fixes the real order


def create(title, *, parent=None, kind="task", priority=0, description=None):
    args = ["create", title, "--type", kind, "--priority", str(min(priority, MAX_PRIORITY)), "--json"]
    if parent:
        args += ["--parent", parent]
    if description:
        args += ["--description", description]
    out = json.loads(bd(*args))
    return (out[0] if isinstance(out, list) else out)["id"]


def task_description(d, shared):
    acs = "\n".join(f"AC{i}: {c}" for i, c in enumerate(d["criteria"], 1))
    parts = [
        f"What: {d['title']}",
        "Plan text (verbatim — every paragraph, numbered step, constraint, file hint and mutation/evidence requirement of the\n"
        "deliverable, exactly as written in ACTION_PLAN.md):\n" + d["body"],
    ]
    if shared:
        parts.append("Shared context (verbatim, from the plan's shared section):\n" + shared)
    parts.append("Acceptance criteria (verbatim, numbered):\n" + acs)
    if d["blockers"]:
        parts.append("BLOCKED_BY: " + "; ".join(d["blockers"]))
    parts.append("RETRY: 0")
    return "\n\n".join(parts)


def main():
    try:
        text = open(PLAN, encoding="utf-8").read()
        features, shared = parse(text)
        validate(features)
    except (Unparseable, OSError) as e:
        print(f"[bootstrap_plan] cannot parse {PLAN}: {e}", file=sys.stderr)
        return 2

    base_sha = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    try:
        if not os.path.isdir(".beads"):
            bd("init", "--stealth", "-p", os.path.basename(os.getcwd()))
        ids = {}
        tag_re = os.environ.get("RALPH_FEATURE_TAG_RE", "")  # e.g. a ticket pattern; searched in each Feature title
        for ei, feat in enumerate(features):
            found = re.search(tag_re, feat["title"]) if tag_re else None
            epic = create(
                f"Epic: {feat['title']}", kind="epic", priority=ei,
                description=f"TAG: {found.group(0)}" if found else None,
            )
            for ti, d in enumerate(feat["deliverables"]):
                ids[d["title"]] = create(
                    f"[impl] {d['title']}", parent=epic, priority=ti, description=task_description(d, shared)
                )
        for feat in features:
            for d in feat["deliverables"]:
                for b in d["blockers"]:
                    bd("dep", "add", ids[d["title"]], ids[b])
        if os.environ.get("RALPH_AUDIT", "0") == "1":  # only loops with an [audit] phase set RALPH_AUDIT=1
            audit_epic = create("Epic: Acceptance audit", kind="epic", priority=len(features))
            audit = create(
                "[audit] Acceptance audit of the action plan",
                parent=audit_epic,
                description=f"BASE_SHA: {base_sha}\nPLAN: the archived ACTION_PLAN_*.md (latest) — audit every deliverable and "
                "every acceptance criterion.\nRETRY: 0",
            )
            for impl in ids.values():
                bd("dep", "add", audit, impl)
    except (RuntimeError, json.JSONDecodeError, KeyError) as e:
        print(f"[bootstrap_plan] beads error after partial creation: {e}", file=sys.stderr)
        return 3

    n_crit = sum(len(d["criteria"]) for f in features for d in f["deliverables"])
    print(f"[bootstrap_plan] Pre-flight coverage: {len(ids)}/{len(ids)} deliverables have matching tasks "
          f"({len(features)} epics, {n_crit} acceptance criteria, BASE_SHA {base_sha[:8]})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
