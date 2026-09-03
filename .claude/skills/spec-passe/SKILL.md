---
name: spec-passe
description: >
  Agent taxonomy inference for a new project. Derives agent configuration from specs.
  Reads project specs and L2 knowledge to produce preset list and project.yaml.
allowed-tools:
  - Read
  - Write
  - Glob
  - Grep
when_to_use: >
  Use after project specs are written, to derive the right agent configuration.
  Examples: '/spec-passe', 'infer agents for this project', 'configure agents from specs'.
---
# Skill: /spec-passe

Agent taxonomy inference for a new project. Derives the right agent configuration
from accumulated L2 domain knowledge. Produces the preset list and project.yaml
for fleet-init-project.sh.

Invoke when: `/spec-passe` — mandatory before any new project fleet-init.
Executed by Arch (lead or fleet). Autonomy level controlled by the user cursor.

---

## Prerequisites

Read before executing:
- `fleet/system-prompt/sources/organisation/topologie.md` — roles, scopes, taxonomy
- `docs/#6_diary/construction-v3.md` §Taxonomie — Knowledge×Tier matrix
- L2 knowledge files for the target domain if they exist

Declare state:
```bash
fleet-state.sh action=spec-passe status=in-progress
```

---

## Step 0 — Cursor and domain

Ask the user (or read from project brief if cursor=10):

1. **Domain** : what kind of project? (embedded RPi/Arduino, web app, mobile, daemon, mixed...)
2. **Stack hints** : languages, hardware constraints, target architecture
3. **Cursor** : 0 (validate every step) → 10 (full inference, summary only)

If cursor ≤ 5 OR L2(domain) is empty: proceed step by step, present each step before continuing.
If cursor ≥ 6 AND L2(domain) exists: execute steps 1–6 autonomously, present results at end.

---

## Step 1 — Real-world team

Map the domain to human roles:
- What roles exist in a real team for this type of project?
- Responsibilities, natural boundaries between roles, who talks to whom
- Domain-specific constraints (embedded: cross-compile, hardware-in-loop, datasheets /
  web: frontend, API, CI-CD / mobile: store, signing, platform...)

If cursor ≤ 5: present role list, wait for user validation before Step 2.

---

## Step 2 — Taxonomic mapping

For each human role → (Tier, Division, Knowledge):

**Tier** (lifecycle):
- Tier 1 if: permanent across the full project, strategic decisions, needs L3 access
- Tier 2a if: active throughout project, needs memory between sessions (Dev, Builder, QA)
- Tier 2b if: stateless per invocation, episodic activation (Advisor, Auditor, Researcher)

**Division**:
- 🔴 Command: decides, coordinates (has L3 access)
- 🟡 Operations: produces artifacts, writes L1
- 🔵 Sciences: validates/analyzes — reads L1, writes only reports/verdicts

**Knowledge** (what they need):
- L4: always (global rules)
- L3: only Tier 0 and Tier 1
- L2: their domain — full for Tier 1/2, declarative-only for Tier 0
- L1: all except Tier 0 and Sciences-advisory (Hard-Guru, Search-Agent)

If cursor ≤ 5: present mapping table, wait for validation before Step 3.

---

## Step 3 — Knowledge×Tier matrix for this project

Build the project-specific access matrix:

| Tier | Reads | Writes | If absent |
|------|-------|--------|-----------|
| 0 | L4+L3+L2(decl) | L3 | Fleet collapses |
| 1 framework | L4+L3 | L4 | Framework drift |
| 1 project | L4+L3+L2+L1 | L1+L3 | No coordination |
| 2a | L4+L2+L1 | L1 | Blocking (can't work) |
| 2b | L4+L2(+L1 opt) | — | Degraded quality |

Note L2 gaps: domains with no existing knowledge file → manual bootstrap required.

If cursor ≤ 5: present matrix + gap list, wait for validation before Step 4.

---

## Step 4 — Instantiation rules for this project

For each Tier present in this project:
- What is common to all agents of this Tier? (lifecycle, tooling, escalation)
- What varies? (L2 domain only for Tier 2)
- Tier 2a vs 2b decision: does the agent need memory between sessions?

Identify which existing presets apply directly vs which need explicit domain parameter.

If cursor ≤ 5: present instantiation decisions, wait for validation before Step 5.

---

## Step 5 — Derive canonical presets

From the taxonomy, not from the preset list. Then match against registry:

For each derived agent, provision via:
```
bash fleet/deploy/provision <username>   # v1 provision-users.sh retire 2026-08-06 (excommunion) ; le point d entree v2 est `provision`
```

Produce the agent list:
```
TIER 0  : StarFleet (always — do not add, already running)
TIER 1  : Lead (always for interactive projects)
           Architect fleet (if LCARS framework work involved)
TIER 2a : [derived from Step 2 — agents needing session memory]
TIER 2b : [derived from Step 2 — episodic agents]
```

Flag L2 gaps: `⚠️ L2(domain-X) empty — manual bootstrap required before fleet-init`

If cursor ≤ 5: present preset list, wait for validation before Step 6.

---

## Step 6 — Directive-driven validation

For each Tier 2 preset, verify:
- Is the expected behavior fully expressible in directives?
- Directive test: "is every token of directive useful to this role in this task?"
- If a preset requires logic that can't be expressed in directives → flag as invalid

Hard checks:
- [ ] No two presets with identical (Tier, Division, L2) — they would be the same agent
- [ ] Sciences agents do not write L1 code (only reports/verdicts — exception: Doc-Writer)
- [ ] Tier 2b agents have no Linux instance provisioned
- [ ] L2 gaps documented before proceeding to fleet-init

---

## Step 7 — Write project.yaml

```yaml
project:
  name: <project-name>
  domain: <primary-domain>
  cursor: <0-10>

agents:
  tier1:
    - lead
    - engineer  # if applicable

  tier2a:
    - preset: dev
      domain: generic-software
    - preset: builder
      arch: arm64
    - preset: qualifier
    # add derived presets...

  tier2b:
    - preset: hard-guru     # if embedded hardware questions expected
    - preset: search-agent  # if datasheets/errata research expected
    # add episodic agents...

l2_gaps:
  - domain: <domain-X>
    status: bootstrap-required
    # agent responsible for initial injection: lead
```

Write to `<project-root>/project.yaml`.

---

## Step 8 — Output and handoff

Present to user:
- Agent list with Tier/Division/L2 for each
- L2 gaps requiring manual bootstrap (with priority order)
- Estimated fleet size and token budget implications
- Next step: `fleet-init-project.sh <project-root>/project.yaml`

Write to construction log if this is a LCARS project:
```
## <date> — spec-passe: <project-name>
Presets: [list]. L2 gaps: [list]. Cursor: N.
```

Update state:
```bash
fleet-state.sh action=idle status=done
```

---

## L2 bootstrap (if gaps)

For each missing L2 domain, before fleet-init:

1. Create `domains/<domain-name>/` directory
2. Write initial knowledge file from Arch's general knowledge + user input
3. Tag as `bootstrap` version — will be enriched by harvest after first project
4. Declare in `fleet.yaml` under `domains:`

Bootstrap is manual and human-validated — never autonomous on first run for a domain.
