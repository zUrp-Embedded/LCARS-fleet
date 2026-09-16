# `_ops` — le dépôt du système

Ce dépôt appartient au système LCARS, pas à un projet. Il est posé par la recette de la forge
(`forge-gestures apply`) et vérifié à chaque démarrage par le geste `forge.d/ops-repo.sh`. Le
runtime n'y crée aucune branche hors `tool_request-<demande>`, et il les supprime après traitement.

| branche | ce qu'elle porte | qui écrit |
|---|---|---|
| `main` | ce fichier | la recette |
| `tool_request` | les manifestes d'outillage signés (`ops/toolchains.d/`) — **protégée** : une PR, une approbation du siège | les PR mergées |
| `tool_request-<demande>` | une demande d'outillage en attente de signature — supprimée au drain | le système, pour un pod |
| `incidents` | le registre des incidents du pilote (`work/system-incidents.json`) | le système |

Les escalades du système (`error_system`) sont les issues de ce dépôt : le skill `system-issues`
du siège les liste.
