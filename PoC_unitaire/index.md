# PoC_unitaire — index courant

**Date** : 2026-04-20
**Dernière révision** : 2026-04-20
**Statut** : premier miroir `beyond-contrat-runtime-minimal.md` posé
**Référencé par** : `PoC_unitaire/README.md`

Regeneration : `bash run-all.sh` (skip LLM-heavy) ou `bash run-all-full.sh` (tout).

## 10-beyond/contrat-runtime-minimal/

Source corpus : `work/moon-shot/10-beyond/beyond-contrat-runtime-minimal.md`

| Unité | État | Source corpus |
|---|---|---|
| schemas-authority | DRAFT | §1 Noyau schémas |
| spec-status-event-frontiere | DRAFT | §1 Frontière |
| boot-startup-probes | DRAFT | §2 BOOT |
| main-loop-event-driven | DRAFT | §2 BOUCLE |
| spawn-cycle | DRAFT | §2 Cycle spawn (Tier 2) |
| mcp-server-per-pod | **PROVEN** | §2 Enregistrement MCP |
| can-use-tool-deny | **PROVEN** | §2 Règle permission |
| pod-phase-transitions | **PROVEN** | §3.1 |
| job-phase-transitions | **PROVEN** | §3.2 |
| attempt-phase-transitions | **PROVEN** | §3.3 |
| ready-conjunction-of-probes | **PROVEN** | §3 READY |
| no-deploy-ok-flag | DRAFT | §3 READY |
| gate-data-contract | **PROVEN** | §4 Gate |
| qualifier-double-verification | DRAFT | §4 FG-01 |
| event-log-ndjson | **PROVEN** (atomicité + rotation) | §4 Event |
| no-resume-workers-critiques | **PROVEN** (partiel) | §5 Arbitrage |
| recovery-orphan-handling | DRAFT | §5 Procédure restart |
| extract-atomicity | **PROVEN** (primitives FS) | §5 AC-01 |
| work-ops-single-writer | **PROVEN** (flock) | §5 AC-03 |
| cleanup-boot | DRAFT | §5 Cleanup boot |

Totaux : **10 PROVEN / 20 unités** (50% de couverture sur ce doc). 10 DRAFT avec mandat posé, test.sh GAP clairement documenté.

## PoCs Tier 1 rapatriés

Les 5 PoCs Tier 1 existants (/home/projects/LCARS/PoC/PoC-0*) sont référencés comme harness par les unités appropriées. Ils ne sont pas déplacés — conservés sous leur nom historique, mais pointés depuis `PoC_unitaire/`.

| PoC original | Unité(s) qui l'utilisent |
|---|---|
| PoC-01 (recette canonique) | no-resume-workers-critiques |
| PoC-02 (OAuth WSL) | — (pas de miroir contrat-runtime) |
| PoC-03 (MCP in-process) | mcp-server-per-pod |
| PoC-04 (NDJSON + logrotate) | event-log-ndjson |
| PoC-05 (systemd ConditionPathExists) | — (miroir dans `deployment/` quand on y arrive) |
| B1a (multi-agent concurrent) | — (à raccrocher quand on miroire fleet-pilot-architecture) |
| B1b (can_use_tool) | can-use-tool-deny |

## Docs corpus à miroir ensuite

Par ordre de densité normative descendante :
1. `10-beyond/beyond-objets-runtime-v2.md` (Pod, CapabilityProfile, Job, Attempt, Delivery, Pipeline, Probes)
2. `10-beyond/beyond-spawn-pod-v2.md` (cycle 8 étapes détaillé — croise `spawn-cycle/`)
3. `04-phase-1-core/fleet-pilot-architecture.md` (daemon)
4. `04-phase-1-core/ipc-native-structuredio.md` (7 canaux)
5. `04-phase-1-core/doctrine-runtime-workers-critiques.md` (recette — croise PoC-01)
