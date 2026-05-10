# PoC-03 — MCP in-process via SdkControlTransport

**Date** : 2026-04-20
**Dernière révision** : 2026-04-20
**Statut** : done — 5/5 PASS, hypothèse validée
**Référencé par** : `work/beyond/poc-plan.md §PoC-03`
**Version claude testée** : 2.1.114
**SDK** : `claude-agent-sdk` 0.1.63 (Python)
**Branche** : `feature/poc-03-mcp-in-process`

## Hypothèse

Le transport MCP in-process `SdkControlTransport` (décrit dans le reverse engineering Claude Code §5b) existe, marche, et distribue un MCP tool LCARS au modèle sans fork process séparé. Latence d'invocation < 50ms, payload JSON correct.

Criticité : **la plus élevée du plan PoC**. Si ça ne marche pas, tout le design `fleet_spawn`, `fleet_state`, `fleet_metrics`, `fleet_resolve` (tools fleet exposés aux agents) tombe.

## Méthode

Script Python `test_mcp_in_process.py` qui :
- définit un tool `lcars_ping` via `@tool` (claude_agent_sdk)
- crée un serveur MCP SDK in-process via `create_sdk_mcp_server`
- enregistre son PID + le marker dans une var globale quand le tool est appelé
- lance une `query()` demandant à l'agent d'invoquer le tool et d'echo le marker
- parse les events pour capturer `tool_use` / `tool_result`, mesurer latences
- extrait `ResultMessage.result` pour confirmer que le marker a transité jusqu'au texte final

## Résultats

| Test | Ce qu'on vérifie | PASS |
|---|---|---|
| T1 | tool `lcars_ping` effectivement appelé par l'agent | PASS |
| T2 | tool exécuté dans le PID python hôte (pas de fork MCP) | PASS |
| T3 | pas de sous-process MCP dédié (claude CLI seul enfant, le tool tourne in-process) | PASS |
| T4 | latence interne du tool < 50ms | PASS — 0.01ms |
| T5 | payload JSON (marker unique) relayé par l'agent dans sa réponse finale | PASS |

**Durée totale** d'un `query()` (incluant appel API LLM haiku + 2 tours + invocation tool) : ~5.8s. Le tool lui-même ajoute du bruit négligeable.

## Conclusion

Hypothèse validée empiriquement. Le transport in-process décrit dans le reverse 2.1.88 (`services/mcp/SdkControlTransport.ts`) est effectivement exposé par `claude-agent-sdk` Python 0.1.63 et fonctionne sur claude-code 2.1.114. Le design LCARS qui fait dépendre `fleet_spawn` et consorts de ce transport est **techniquement viable**.

Pas de finding nécessaire. Le chemin pour B1 est libre sur ce front.

## Notes d'implémentation B1

- L'API Python est `from claude_agent_sdk import tool, create_sdk_mcp_server, query, ClaudeAgentOptions`. `allowed_tools=["mcp__<server>__<tool>"]` syntaxe exacte.
- Le SDK spawn `claude-code` CLI comme subprocess, mais les tools SDK registered restent dans le PID python.
- `permission_mode="bypassPermissions"` dans le PoC pour éviter le workflow de confirmation — en B1 il faudra `default` + allowlist explicite par rôle.
- Le subprocess `claude` est lifetime = durée de la `query()`, nettoyé proprement au `async for` end.

## Livrables

- `test_mcp_in_process.py` — harness reproductible
- `.venv/` — venv Python avec claude-agent-sdk 0.1.63 (non versionné, gitignore)

## Hors scope

- Concurrence : N calls parallèles sur le même serveur in-process. À tester dans PoC-06/07 (spawn cycle).
- Dispatch inverse : agent reçoit un SDKUserMessage injecté par fleet-pilot via le même canal. À tester dans PoC-08 (control protocol interrupt).
- Latence agent-side (roundtrip `tool_use` → `tool_result` côté agent) inclut l'LLM ; non normative pour le test `< 50ms` qui concerne le transport seul.
