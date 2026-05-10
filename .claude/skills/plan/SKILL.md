---
name: plan
description: >
  Plan lifecycle and work/ maintenance wrapper.
  Routes to fleet-plan.sh (new, start, done, check, list, append, audit)
  and fleet-scrub.sh (scrub scratchpad, scrub backlog, init).
  Resolves project context and passes arguments.
allowed-tools:
  - Bash(fleet-plan.sh:*)
  - Bash(fleet-scrub.sh:*)
  - Bash(ls:*)
  - Read
when_to_use: >
  Use when the user wants to manage plans or work/ lifecycle.
  Examples: '/plan new', '/plan list', '/plan start', '/plan done',
  '/plan scrub scratchpad', '/plan scrub backlog'.
argument-hint: "<subcommand> [args]"
arguments:
  - subcommand
---
# Skill: /plan

**Date** : 2026-03-21
**Dernière révision** : 2026-03-21
**Statut** : active — all agents (per matrice agent×commande)
**Référencé par** : work/doing/fleet-plan-lifecycle.md (étape 3)
**Dérivé de** : —

Wrapper conversationnel pour fleet-plan.sh et fleet-scrub.sh.
Résout le projet courant et dispatche la commande au bon script.

---

## Syntaxe

Plan lifecycle:
- `/plan new <slug>` — create plan in TODO/
- `/plan start <slug>` — move TODO/ → doing/
- `/plan done <slug> [step N]` — validate + move doing/ → done/
- `/plan check <slug> [step N]` — dry-run validation (no move)
- `/plan list [TODO|doing|done]` — show all plans
- `/plan append <slug>` — append context to existing plan
- `/plan audit` — check all plans for conformity

Work maintenance:
- `/plan scrub scratchpad` — triage scratchpad → now | backlog | caduc
- `/plan scrub backlog` — triage backlog → now | plan | caduc
- `/plan init` — bootstrap index.md from current state

---

## Exécution

<instructions>
Parse the user's `/plan` arguments. Route to the correct fleet script.

1. Determine PROJECT_ROOT: walk up from $PWD looking for a `work/` directory. If not found, ask the user which project.

2. Route the command:

   For `scrub scratchpad`, `scrub backlog`, `init`:
   ```bash
   cd "$PROJECT_ROOT" && "$HOME/.local/bin/fleet-scrub.sh" <command>
   ```

   For all other commands (`new`, `start`, `done`, `check`, `list`, `append`, `audit`):
   ```bash
   cd "$PROJECT_ROOT" && "$HOME/.local/bin/fleet-plan.sh" <command> [args]
   ```

3. For `/plan done <slug> step N`: pass as `fleet-plan.sh done <slug> --step N`
4. For `/plan check <slug> step N`: pass as `fleet-plan.sh check <slug> --step N`
5. For `/plan append <slug>`: if the user provided content after the slug in the conversation, pipe it to stdin. If no content provided, ask what to append.
6. For `/plan list` with no filter: show all states.

Display the script output verbatim. Do not summarize or reformat.

If the command fails, show the error and suggest the fix.

Agent access matrix (enforce):
| Agent | new | start | done | check | list | append | audit | scrub |
|---|---|---|---|---|---|---|---|---|
| Architect | yes | — | — | yes | yes | — | — | — |
| Engineer | — | yes | — | yes | yes | — | — | yes |
| Dev | — | — | yes (step) | yes | yes | yes | — | — |
| StarFleet | yes | yes | yes | yes | yes | yes | yes | yes |

If the calling agent is not authorized for the command, refuse with: "ERROR: <role> is not authorized for /plan <command>. See matrice agent×commande."
</instructions>
