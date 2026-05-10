# Contrat runtime minimal — PoC_unitaire

**Source corpus** : `work/moon-shot/10-beyond/beyond-contrat-runtime-minimal.md`
**Date** : 2026-04-20
**Dernière révision** : 2026-04-20
**Statut** : arbre initialise, unites en cours de remplissage
**Référencé par** : `PoC_unitaire/README.md`

## Unités

| Unité | Source corpus | État |
|---|---|---|
| schemas-authority | §1 Noyau minimal | mandat |
| spec-status-event-frontiere | §1 Frontière | mandat |
| boot-startup-probes | §2 BOOT | mandat |
| main-loop-event-driven | §2 BOUCLE PRINCIPALE | mandat |
| spawn-cycle | §2 Cycle spawn | mandat (ref PoC-T2-06) |
| mcp-server-per-pod | §2 Enregistrement MCP | **PROVEN via PoC-03** |
| can-use-tool-deny | §2 Règle permission | **PROVEN via B1b** |
| pod-phase-transitions | §3.1 | mandat |
| job-phase-transitions | §3.2 | mandat |
| attempt-phase-transitions | §3.3 | mandat |
| ready-conjunction-of-probes | §3.4 Système READY | mandat |
| no-deploy-ok-flag | §3.4 | mandat |
| gate-data-contract | §4 Contrat gate_data | mandat |
| qualifier-double-verification | §4 FG-01 | mandat |
| event-log-ndjson | §4 Schéma event | **PROVEN via PoC-04** (partiel) |
| no-resume-workers-critiques | §5 Arbitrage V2.16 | **PROVEN via PoC-01** (partiel) |
| recovery-orphan-handling | §5 Procédure restart | mandat |
| extract-atomicity | §5 AC-01 | mandat |
| work-ops-single-writer | §5 AC-03 | mandat |
| cleanup-boot | §5 Cleanup boot | mandat |

PROVEN = un `test.sh` runnable existe et observe quelque chose d'attendu.
mandat = contrat écrit, test.sh DRAFT.
