# Audit P1 — Dialyzer (« les @spec mentent ? »)

**Date** : 2026-07-09
**Dernière révision** : 2026-07-09
**Statut** : CLOS — baseline dialyzer propre établie
**Référencé par** : `_plan-integrite-2.md`

## Verdict

**Les @spec NE mentent PAS.** Umbrella 14 apps, dialyzer (draft PLT + analyse) → **7 errors dont 2 pré-skippés**,
soit **5 actionnables, tous BÉNINS** (aucun bug de type/contrat, aucun pattern impossible, aucune contract-violation).
Le codebase est bien typé — c'est cohérent avec la campagne finition. Nettoyés pour établir une **baseline 0-warning**
(→ toute dérive future ressort comme régression).

## Les 5 (tous convergent avec P2 = discards de retour élargi)

| Site | Type | Verdict | Fix |
|---|---|---|---|
| `event_router/signals_os.ex:30` | `no_return` | INTENTIONNEL (init/1 raise toujours — SignalsOS pas implémenté, activer = misconfig → refus de boot) | `@dialyzer {:nowarn_function, init: 1}` |
| `mcp/pod_tools/delegation.ex:176` | `unmatched_return` | bénin (`Code.ensure_loaded` = side-effect, check réel = `function_exported?` après) | `_ = Code.ensure_loaded` |
| `spawner/pod/mcp_provision.ex:53` | `unmatched_return` | idem | `_ = Code.ensure_loaded` |
| `mcp/pod_socket_supervisor.ex:86` | `unmatched_return` | bénin (retour `:ok\|{:error}` de rmdir, spec `:: :ok`) | `:ok` explicite en fin de branche |
| `spawner/pod/state_fs.ex:112` | `unmatched_return` | bénin (valeur du `if` droppée par le `:ok` suivant) | `:ok` dans les 2 branches |

Gate : `mix dialyzer` **passed successfully** (0 nouveau warning), mcp 52/0, spawner 212/0, event_router 73/0.
