---
name: handoff
description: >
  Genere ou met a jour le fichier handoff de fin de session pour continuite.
  Reserve a la fin de session — reecriture complete STATE+ACTIONS+DONE.
allowed-tools:
  - Read
  - Write
  - Bash(git:*)
  - Bash(date:*)
  - Bash(fleet-state.sh:*)
  - Bash(fleet-scrub.sh:*)
when_to_use: >
  Use when the user says 'SeeU', 'seeu', 'end session', or asks to close/save
  the session. Also invoked by /handoff directly. Triggers complete handoff
  generation with STATE, ACTIONS, and DONE sections.
---
# Skill: /handoff

**Date** : 2026-03-22
**Dernière révision** : 2026-03-22
**Statut** : active — tous les agents avec continuité de session
**Référencé par** : .claude/commands/handoff.md

Wrapper skill pour `/handoff`. Délègue à la commande handoff.md.

---

<instructions>
Before invoking /handoff:
1. Run `fleet-scrub.sh scratchpad` to triage the scratchpad into backlog. Wait for completion. If it fails, warn but continue.
2. Then invoke the `/handoff` command. Follow all instructions in the command definition.
</instructions>
