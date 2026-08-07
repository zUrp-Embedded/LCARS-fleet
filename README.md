<!-- Date: 2026-03-30 · Dernière révision: 2026-03-30 · Statut: v6.5 validé · Référencé par: — -->

<div align="center">

# LCARS-fleet

### Firmware-as-a-Service.
*Pas mal non ? C'est français.*

**A governed system for producing code with LLM agents inside a bounded, legible, redeployable framework.**

[![Release](https://img.shields.io/badge/release-v6.0--beta-4A90D9?style=flat-square)](https://github.com/lordzurp/LCARS-fleet/releases)
[![Platform](https://img.shields.io/badge/platform-WSL2%20%7C%20Docker-informational?style=flat-square)]()
[![Runtime](https://img.shields.io/badge/runtime-self--hosted-informational?style=flat-square)]()
[![License](https://img.shields.io/badge/license-AGPL--v3-blue?style=flat-square)](LICENSE)
[![Third-party](https://img.shields.io/badge/third--party-notices-lightgrey?style=flat-square)](THIRD_PARTY_NOTICES.md)

**Jump to** — [Quick Start](#quick-start) · [Why LCARS](#why-lcars) · [In Numbers](#in-numbers) · [What You Get](#what-you-get) · [Architecture](#architecture) · [Who It's For](#who-its-for)

</div>

---

## 🚀 Why LCARS

LCARS starts from a simple premise: an LLM remains a probabilistic component. The real engineering problem is therefore not how to make it "magical," but how to build a surrounding system that is bounded, legible, inspectable, and redeployable.

LCARS is built around a simple requirement: **nothing implicit, clean boundaries, and a runtime that can be rebuilt cleanly**.

LCARS is not trying to be the smoothest wrapper around chat. It is trying to be a usable machine in which specialized agents produce work through a process that is visible, replayable, and governable.

The target is not impressive generation. The target is **output you can actually use**.

The agents are not the system. They are the unstable engine inside the system. LCARS is the enclosure around that engine.

That is the whole project.

---

<a id="quick-start"></a>

## ⚡ Quick Start

LCARS is primarily built for **Ubuntu LTS on WSL2**, with Docker support as a secondary deployment path.

### WSL2

```powershell
wsl --install Ubuntu-24.04 --name fleet
```

```bash
wget -O /tmp/install.sh https://raw.githubusercontent.com/lordzurp/LCARS-fleet/main/install.sh
sudo bash /tmp/install.sh
```

### Docker

```bash
git clone https://github.com/lordzurp/LCARS-fleet.git
cd LCARS-fleet
./docker.sh up
```

### Launch the fleet

```bash
~/start
~/start --template executive
~/start --template panoptique
```

Within minutes, you get a live dashboard, a role-bound fleet, Linux-native message routing, persistent handoff state, and a runtime designed to be rebuilt cleanly rather than maintained by drift.

---

<a id="in-numbers"></a>

## 📏 In Numbers

| | LCARS |
|---|---|
| Active runtime | **1.8 MB** |
| Shell + Python | **12K lines** |
| Directive corpus | **1,405 lines** |
| Test coverage | **20K lines** (ratio **1.7×**) |
| Agents governed | **6 roles**, tiered |

The point is not that LCARS is "small." The point is that it stays **compact enough to inspect** while still carrying a real runtime, a real coordination layer, and a non-trivial behavioral control surface.

For context: many frameworks in this space use **100K-225K lines of Go or TypeScript** for the same general class of agent coordination problem.

If you know embedded, firmware, or systems work, you already know why this matters: when the machine lies, size alone does not save you. Legibility does.

---

<a id="what-you-get"></a>

## 🧰 What You Get

### 🛰️ A real fleet

LCARS ships a topology with explicit responsibilities. Each agent has a role, a scope, a user, a home, and a directive surface.

| Role | Function |
|---|---|
| `architect` | user-facing boundary: architecture, arbitration, prioritization |
| `starfleet` | system boundary: deployment, provisioning, maintenance, hotfixes |
| `engineer` | internal coordination and dispatch |
| `dev` | code production |
| `qualifier` | validation and PASS/FAIL testing |
| `reviewer` | independent read-only review |

This matters because most multi-agent setups fail exactly where ownership, escalation, state, and authority become vague.

### 📜 Versioned behavioral control

LCARS does not rely on repeated prompt rituals. Behavior is shaped through versioned artifacts: directive sources, role bindings, protocol files, hooks, and deployment logic. The point is not to "prompt better." The point is to make behavioral control inspectable and deployable.

### 📡 Linux-native coordination

The core coordination layer stays intentionally plain:

- one AF_UNIX MCP socket **per pod**, under the human's own `~/.lcars/run/`
- a git forge as the durable substrate: issues, PRs, labels — the truth outlives every process
- shell launchers for the sandbox, and a tmux session you can attach to

This makes the fleet readable with ordinary Linux reflexes. No hidden broker. No mystery service. If something drifts, there is a file, a path, a process, a user, or a permission behind it.

*(Until 2026-08-07 this section named `/var/spool/fleet/inbox/<role>/` and `$FLEET_HANDOFFS` — the
v1 file spool. It is gone: measured at zero references before removal. A README that describes a
coordination layer the product no longer has is worse than one that describes none.)*

### ♻️ A disposable runtime

LCARS assumes the runtime is consumable. Durable truth is expected to live in versioned source, deployment logic, and explicit persistence surfaces rather than in a machine slowly drifting out of spec.

That is one of the central design choices in the whole project.

---

<a id="architecture"></a>

## 🏗️ Architecture

LCARS is built as a small tiered runtime:

- **Tier 0** — the boundaries
  - `starfleet` for the OS and deployment boundary
  - `architect` for the user and decision boundary
- **Tier 1** — internal coordination
  - `engineer` for dispatch and organization
- **Tier 2** — specialized workers
  - `dev`, `qualifier`, `reviewer`, builders, and domain-specific roles

The key architectural choice is simple:

> keep the model flexible inside the box, but make the box itself more legible and more governable

LCARS does not pretend to make reasoning deterministic. It tries to clean up the operational surface:

- who can act
- how work is routed
- how state is handed off
- how sessions resume
- how the runtime is restarted
- where truth actually lives

This is the point: not to make the model pure, but to make the surrounding machine less likely to lie.

---

## 🧭 Positioning

LCARS is not trying to compete with generic agent orchestration frameworks on "more features" or "more autonomy."

If you know tools like CrewAI, Goose, or the broader ecosystem of agent wrappers, the difference is not subtle:

- LCARS is less interested in orchestration theater
- less interested in abstract agent graphs
- less interested in hiding the machine behind convenience

It is more interested in:

- explicit boundaries
- visible state
- restartability
- handoff discipline
- redeployable runtime
- output quality under real constraints

In short: LCARS is closer to a governed runtime than to a generic agent framework.

---

## 🪞 Built Inside The Box

LCARS is not only a runtime for real projects. It is also the first real project built and maintained inside that runtime.

This repository is itself a product of the LCARS workflow: role-bound agents, explicit handoffs, bounded authority, review surfaces, and repeated redeploy.

That does not prove perfection. It proves something more useful: the system is already capable of producing, evolving, and maintaining a non-trivial codebase under its own operating model.

The recursive part is not a gimmick. It is one of the strongest pieces of evidence the project can offer.

---

<a id="who-its-for"></a>

## 🎯 Who It's For

LCARS is for people who want more than a coding assistant and less than a theatrical agent narrative.

It is a good fit if you care about:

- governed agent collaboration
- self-hosted systems
- explicit roles and boundaries
- replayability and auditability
- firmware, embedded, infrastructure, systems, or technical project work where "close enough" is not a serious standard

It is a bad fit if you want:

- instant cloud convenience
- the smallest possible setup
- a lightweight wrapper around chat
- a workflow where nobody cares how the output was produced as long as it looks plausible

LCARS is not optimized for minimal friction. It is optimized for the path where the machine becomes more useful over time instead of less trustworthy.

---

## 🔥 The Promise

LCARS does **not** promise perfect agents, zero bugs, or autonomous magic.

It promises something more grounded:

- a bounded environment
- visible coordination
- cleaner process
- rebuildable runtime
- better odds of outputs you can actually use

The standard is not "interesting demo."

The standard is:

> install the box, start the fleet, give it real work, and get back something clean enough to rely on without immediately needing to tear the whole thing open

---

## 🗂️ Repository Map

```text
LCARS-fleet/
├── .claude/          # hooks, CLAUDE surfaces, settings
├── .gitea/           # the live CI
├── .github/          # Pages publication of the showcase site only
├── assets/           # brand marks, charter, and the showcase site (github.io)
├── fleet/            # THE product — fleet/ is the Mix root
│   ├── lib/          # the single OTP app, domains under lib/fleet/<domain>/
│   ├── priv/         # runtime assets, and priv/catalogue/ = the business data
│   ├── test/         # the suite, plus test/shell_gate.sh for the out-of-mix nets
│   ├── bin/          # the launchers: bwrap (sanctuary), host, vendor
│   ├── config/       # compile-time, per-env, and boot config
│   ├── etc/          # deploy and run procedure
│   ├── deploy/       # provisioning: bare machine -> working fleet, one idempotent gesture
│   ├── vendor/       # vendored bricks (token-saver) + our integration layer
│   ├── git-hooks/    # the GO-7 wall, force-push block, hook installer
│   └── system-prompt/sources/user/   # the interactive protocol's two personalisation files
├── docs/#_Archived/  # the pre-v2 documentation, kept READABLE rather than only reachable by git
├── knowledge/        # reusable domain knowledge
├── install.sh        # WSL bootstrap entrypoint
├── docker.sh         # Docker bootstrap entrypoint
└── THIRD_PARTY_NOTICES.md   # what we borrowed, from whom, under which licence
```

The v1 tree (`fleet/v1/`, `fleet/provisioning/`, `fleet/tests/`, the 24-file directive corpus and
six more directories) left this map on 2026-08-07. It is archived, not deleted: the tag
`v1-excommunication-base` holds it, and `git show v1-excommunication-base:<path>` returns any file.

LCARS stands on other people's work. [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) lists every borrowing — copied code, reimplemented code, and borrowed method alike — with its licence and its place in the tree. It deliberately covers more than the licences require.

---

## 🧪 Try It If...

You should probably try LCARS if your target sounds like this:

- "I want a real multi-agent environment, not a prompt toy."
- "I want something self-hosted and inspectable."
- "I want roles, scopes, handoffs, and process."
- "I want a runtime I can rebuild instead of fear."
- "I care whether the code works, not just whether the generation looks clever."

If what you really want is just "make the model type faster," LCARS is almost certainly too much machine for the job.
