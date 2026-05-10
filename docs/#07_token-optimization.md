# Optimisation tokens — techniques et gains

**Date** : 2026-03-21
**Dernière révision** : 2026-03-21
**Statut** : guide
**Référencé par** : CLAUDE.md par rôle

> **Quickstart** — 12 techniques, 11 implémentées. Plancher incompressible : ~23.6k tokens avant la première query. Budget effectif : ~143k/200k. Ne jamais toucher aux garde-fous de sécurité.

---

## Techniques

| # | Technique | Gain | Status |
|---|---|---|---|
| T1 | Filtrage handoffs par rôle (session-startup.sh) | 30-50% startup | ✅ |
| T2 | STATE-only pour handoffs secondaires | 400-700 tokens/session | ✅ |
| T3 | ipc-protocol.md élagué (suppression diagrammes/benchmarks) | ~800 tokens permanent | ✅ |
| T4 | Tag non-lecture DIRECTIVES.md (commentaire HTML) | ~2K prévention | ✅ |
| T5 | Progressive disclosure (sections role-specific → fichiers dédiés) | ~550 tokens permanent | ✅ |
| T6 | `context: fork` sur skills cross-arm64, push-github | ~800 tokens/invocation | ✅ |
| T7 | filter-build-output.sh (hook PreToolUse, cmake/make/ninja) | 600-800 tokens/build | ✅ |
| T8 | AUTOCOMPACT per-role (deploy.sh → .bashrc, 60% défaut, 75% architect) | Compaction optimisée | ⚠️ partiel |
| T9 | Directives concision (pas de recap, pas de status reports) | ~20% output | ✅ |
| T10 | Read-cache rule (pas de re-Read si contenu en contexte et non modifié) | 1500-8000 tokens/session | ✅ |
| T11 | fleet-state.sh remplace Edit tool pour STATE | 7× par notification | ✅ |
| T12 | Modèle par rôle + reset auto (deploy.sh --update-models, fleet-launch) | 3× prévention coût | ✅ |

**T8 détail** : AUTOCOMPACT implémenté. MAX_THINKING_TOKENS non implémenté (pas de variable d'env Claude Code pour le thinking).

---

## Matrice modèles (T12)

| Rôle | Modèle |
|---|---|
| architect, starfleet | claude-opus-4-6 |
| tous les autres | claude-sonnet-4-6 |

Escalade manuelle Opus via `/model`, reset garanti au prochain `fleet-launch`.

---

## Plancher incompressible

Mesuré fresh launch architect (2026-03-08) :

| Catégorie | Tokens | % de 200k |
|---|---|---|
| System prompt | ~3.5k | 1.7% |
| System tools | ~9.2k | 4.6% |
| Memory (CLAUDE.md + imports) | ~10.5k | 5.3% |
| Skills | ~0.4k | 0.2% |
| **Total baseline** | **~23.6k** | **11.8%** |

Autocompact buffer : 33k (16.5%). **Budget effectif : ~143k (71.7%)**.

Anomalie non résolue : qualifier system tools = 18.6k vs architect 9.2k. Cause probable : répertoire de lancement ou deferred tools.
