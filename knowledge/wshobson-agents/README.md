# Knowledge — wshobson/agents plugin library

**Date** : 2026-03-28
**Dernière révision** : 2026-03-28
**Statut** : import externe (MIT)
**Référencé par** : knowledge/embedded/README.md, ponce-7repos/wshobson-agents-brief.md
**Dérivé de** : https://github.com/wshobson/agents (MIT License)

## Attribution

All files in this directory are from [wshobson/agents](https://github.com/wshobson/agents),
licensed under the MIT License. Copyright (c) wshobson contributors.

## Plugins imported (10/74)

| Plugin | Agents | Usage LCARS |
|---|---|---|
| shell-scripting | bash-pro, posix-shell-pro | L2 bash patterns — notre langage principal |
| comprehensive-review | architect-review, code-reviewer, security-auditor | Patterns review pour qualifier/reviewer |
| systems-programming | c-pro, cpp-pro, rust-pro, golang-pro | L2 embedded C/C++/Rust |
| security-compliance | security-auditor | Checklist sécurité pour audits |
| tdd-workflows | code-reviewer, tdd-orchestrator | Patterns TDD pour la qualification |
| reverse-engineering | firmware-analyst, malware-analyst, reverse-engineer | Patterns pour le mot-clé `reverse` |
| agent-orchestration | context-manager | Patterns context management |
| conductor | conductor-validator | Patterns orchestration/validation |
| cicd-automation | cloud-architect, devops-troubleshooter | Patterns CI/CD |
| debugging-toolkit | debugger, dx-optimizer | Patterns debug |

## Usage

Ces fichiers sont des références — pas des agents LCARS. Ils alimentent le Knowledge L2
par domaine. L'intégration se fait par extraction de patterns pertinents dans les
fichiers L2 dédiés (knowledge/embedded/, knowledge/audit-quality/, etc.).
