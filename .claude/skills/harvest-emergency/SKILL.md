---
name: harvest-emergency
description: >
  Emergency context harvest before compaction. Invoke when context < 20% remaining.
allowed-tools:
  - Read
  - Write
  - Bash(fleet-state.sh:*)
  - Bash(fleet-done.sh:*)
  - Bash(cat:*)
when_to_use: >
  Use when context is running low (< 20% remaining), before auto-compact kicks in.
  Also triggered by GO-8 (compact discipline). Examples: '/harvest-emergency',
  'context is low', 'compact approaching'. Do NOT wait for the 70% auto-compact.
---
# Skill: /harvest-emergency

**Date** : 2026-03-08
**Dernière révision** : 2026-03-08
**Statut** : Phase 2 — mechanism (Phase 1 bench: empirical, ongoing)
**Référencé par** : backlog #31

Emergency harvest before context compaction. Invoke when context < 20% remaining.

Threshold: **< 20%** (empirical — dérive détectée à ~14% restant, auto-compact warning à 12%).
Don't wait for the auto-compact warning — at 12% it's already too late to harvest cleanly.

---

## When to invoke

- You notice context is getting low (visible at /cost or estimated from session length)
- User says "compact approaching" or equivalent
- You are about to start a complex multi-step task and context is borderline
- **Do NOT wait** for the 70% auto-compact trigger (that compacts, doesn't harvest)

---

## Step 0 — Signal in-progress

```bash
fleet-state.sh action=idle status=in-progress
```

---

## Step 1 — Write harvest document

Write to `/tmp/fleet-snippet-<instance>.md` (no Read needed — overwrite):

```
Harvest YYYY-MM-DD HH:MM — <current task title>

## Current task
<1-2 sentences: what we are doing, where we are in it>

## Code changes this session
<files modified, what changed, commit hashes if any>

## Decisions made
<architectural choices, trade-offs accepted, things NOT to redo>

## Pending actions
<what must happen next — specific, actionable>

## Key file paths
<non-obvious paths needed to resume>

## Blockers / waiting
<if any — otherwise omit>
```

---

## Step 2 — Inject into handoff DONE

```bash
fleet-done.sh "Harvest — context pressure" "$(cat /tmp/fleet-snippet-${INSTANCE:-unknown}.md 2>/dev/null)"
```

---

## Step 3 — Compact

Run `/compact` nu — JAMAIS de guidance retain/discard (GO-8).

---

## Notes

- Phase 1 bench (backlog #31): reroll 5+ times to confirm <20% threshold empirically.
  Data point: 2026-03-08 — dérive à ~14%, warning at 12%, seuil conservateur retenu : **20%**.
- This skill does NOT automate detection — call it manually when you sense context pressure.
- After compact: re-read harvest from handoff DONE + spool inbox before resuming.
