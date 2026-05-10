# can-use-tool-deny

**Source** : `work/moon-shot/10-beyond/beyond-contrat-runtime-minimal.md` §2 "Règle de permission"
**Date** : 2026-04-20
**Dernière révision** : 2026-04-20
**Statut** : PROVEN via B1b
**Référencé par** : `contrat-runtime-minimal/README.md`

## Contrat

Un pod qui appelle un MCP tool non déclaré dans son profile →
`can_use_tool` callback retourne `deny` → event `tool_denied` →
pas d'exécution. Le gatekeeper LCARS s'appuie sur ce hook pour tout
pont permission dynamique.

## Finding adjacent (B1b)

Si `allowed_tools=[...]` pré-autorise le tool, `can_use_tool` n'est
**pas** invoqué — le callback n'intercepte que les tools non-allowed.
Conséquence pour B1 : le gatekeeper doit s'appuyer sur `can_use_tool`
(pas sur `allowed_tools` pour la décision), sinon il est bypassé.

Ce point est à inclure dans `fleet-pilot-architecture.md` quand on
le miroir.

## Observable

- Appel benin (payload neutre) → callback tire avec `Allow` → tool run → marker renvoyé
- Appel bloqué (payload tagged `BLOCKME`) → callback tire avec `Deny` → `tool_result is_error=true` → agent reçoit erreur → session continue

## Ce que le test vérifie

`test.sh` relance la harness `PoC/PoC-B1-readiness/probe_can_use_tool.py`
et vérifie : allow-path OK + deny-path produit is_error visible côté agent.
