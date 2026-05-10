# Runtime — hooks, skills, subagents

**Date** : 2026-03-21
**Dernière révision** : 2026-03-30
**Statut** : référence active
**Référencé par** : #00_index.md

Catalogue unifié du runtime agent. Détail de chaque script : `script --help`.
En cas d'écart, `fleet/hooks.yaml`, `.claude/skills/` et `.claude/agents/` font foi.

---

## Hooks (10 déployés)

Déployés par `deploy.sh` dans `~/.claude/hooks/`. Câblés via `fleet/hooks.yaml` → `settings.local.json`.

| Hook | Type | Matcher | Bloquant | Fait quoi |
|---|---|---|---|---|
| `session-startup.sh` | `UserPromptSubmit` | — | Oui | Gates sécurité, init état, inject handoff, crash recovery, scratchpad scrub |
| `on-prompt.sh` | `UserPromptSubmit` | — | Oui (exit 2) | Transition `thinking`, context check, drain inbox |
| `pre-scope-check.sh` | `PreToolUse` | `Edit\|Write` | Oui | Vérifie écriture dans le périmètre du rôle |
| `work-guard.sh` | `PreToolUse` | `Edit\|Write\|Bash` | Oui | Bloque accès direct à work/ — force fleet-plan.sh/fleet-scrub.sh |
| `agent-guard.sh` | `PreToolUse` | `Agent` | Oui | Bloque forks Agent hors fleet-dispatch (autorise Explore/Plan) |
| `runtime-guard.sh` | `PreToolUse` | `Edit\|Write\|Bash` | Oui | Bloque écritures /local/LCARS/, ~/.claude/, ~/.local/bin/ |
| `on-stop.sh` | `Stop` | — | Non | État shutdown/done, worktree commit+push work/ops |
| `check-secrets.sh` | `PostToolUse` | `Edit\|Write` | Oui | Scanne patterns secrets (`sk-`, `ghp_`, `AKIA`, passwords) |
| `post-directional-handoff-reminder.sh` | `PostToolUse` | `Edit\|Write` | Non | Rappel de mettre à jour son propre handoff |
| `pre-compact-harvest.sh` | `PreCompact` | `auto` | Non | Snapshot git state → handoff DONE |

**Source de vérité unique** : `fleet/hooks.yaml`. Le tableau ci-dessus en dérive.

Validation QA obligatoire pour tout hook nouveau ou modifié.

---

## Skills (18 actifs + 1 alias legacy)

Invoqués par `/nom` en session interactive. Déployés dans `~/.claude/skills/`.

### Fleet ops

| Skill | Rôle | Ce qu'il fait |
|---|---|---|
| `/lcars-fix` | StarFleet | Quick-fix LCARS (≤8 fichiers, topologie stable). Auto commit+push+merge+deploy. |
| `/lcars-feature` | StarFleet→Dev | Feature LCARS. Clone séparé, dev implémente, PR, merge+deploy. |
| `/push-github` | StarFleet | Pre-push : headers STARDATE, README check, QA gate, push+merge. |
| `/drift-audit` | StarFleet | 5 agents Explore parallèles. Détection drift directives vs réalité. |
| `/onboard_v2` | StarFleet | Onboarding fresh install. 3 barrières sécurité, deploy, `.deploy_ok`. |
| `/fleet-init` | StarFleet | Accueil post-onboarding. Tour dashboard, PoC, config fork. |

### Projet

| Skill | Rôle | Ce qu'il fait |
|---|---|---|
| `/new-project` | Architect | Bootstrap interactif (9 questions). Structure+git+GitHub+Engineer dispatch. |
| `/adopt-project` | Architect | Intègre un projet existant. Ajoute structure fleet manquante. |
| `/plan` | Tous (matrice) | Wrapper `fleet-plan.sh` + `fleet-scrub.sh`. Voir `fleet-plan.sh --help`. |
| `/spec-passe` | Architect | Inférence taxonomie agents depuis L2. Produit `project.yaml`. |

### Opérationnel

| Skill | Rôle | Ce qu'il fait |
|---|---|---|
| `/handoff` | Tous (stateful) | Clôture session. Réécriture handoff STATE+ACTIONS+DONE. |
| `/harvest-emergency` | Tous | Harvest d'urgence avant compaction (<20% contexte). |
| `/project-audit` | Architect, Engineer | Audit code : 4-6 agents parallèles. `--lcars` pour GO compliance. |
| `/cross-arm64` | Dev, Builder | Cross-compilation ARM64. Toolchain, CMake, deploy RPi. `context:fork`. |

### Rapport fichier

| Skill | Rôle | Ce qu'il fait |
|---|---|---|
| `/ponce` | Architect, Consultant | Brief réputation + pertinence sur repo externe (URL). |
| `/reverse` | Architect, Consultant | Reverse engineering archi + comportement sur repo/dossier local. |
| `/audit` | Architect, Consultant | Audit conformité + dette technique sur dossier code. |

### Onboarding user

| Skill | Rôle | Ce qu'il fait |
|---|---|---|
| `/onboarding` | Architect | Guide interactif day-1. S'adapte au profil et niveau de l'user. |

### Legacy — ne pas utiliser

`/lcars-patch` (alias de compatibilité → `/lcars-fix`).

---

## Subagents (2)

Invoqués via l'outil `Agent`, pas par commande `/`. Headless, stateless.

| Agent | Scope | Usage |
|---|---|---|
| `qualifier` | test | QA avant push. Rapport PASS/FAIL structuré. Read L1, write rapports. |
| `reviewer` | analysis | Review indépendante. Cohérence, complétude, edge cases. Read-only. |

---

**Note** : le catalogue documente les hooks effectivement déclarés dans `fleet/hooks.yaml`, les skills présents dans `.claude/skills/` et les subagents présents dans `.claude/agents/`. Les détails d'interface restent dans les man-pages et les `SKILL.md`.
