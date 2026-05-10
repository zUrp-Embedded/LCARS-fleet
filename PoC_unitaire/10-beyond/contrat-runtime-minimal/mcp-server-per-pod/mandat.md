# mcp-server-per-pod

**Source** : `work/moon-shot/10-beyond/beyond-contrat-runtime-minimal.md` §2 "Enregistrement des MCP tools"
**Date** : 2026-04-20
**Dernière révision** : 2026-04-20
**Statut** : PROVEN via PoC-03
**Référencé par** : `contrat-runtime-minimal/README.md`

## Contrat

Fleet-pilot, au spawn d'un pod, crée un serveur MCP in-process via
`createSdkMcpServer` du SDK Claude Code. Les outils exposés au pod
sont **la projection du champ `mcpServers`** du CapabilityProfile —
pas tous les outils, seulement ceux listés.

Observable :
- Le tool MCP est invocable par l'agent
- Le tool s'exécute dans le PID du host Python (pas de fork MCP dédié)
- La latence du transport est faible (ordre sous-millimétrique pour un tool trivial)
- Le payload JSON roundtrip de l'agent vers le tool puis vers la
  réponse finale est intact

## Pourquoi c'est critique

C'est le transport de tous les `fleet_*` tools. Sans transport
in-process fonctionnel, le design (fleet_spawn, fleet_state,
fleet_resolve, fleet_metrics, fleet_escalate_system) tombe.

## Ce que le test vérifie

`test.sh` relance la harness `PoC/PoC-03-mcp-in-process/test_mcp_in_process.py`
et vérifie que les 5 assertions passent (T1 tool-invoked, T2 same-pid,
T3 no-mcp-fork, T4 tool-latency, T5 payload-roundtrip).
