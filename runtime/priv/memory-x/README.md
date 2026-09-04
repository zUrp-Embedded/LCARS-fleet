# priv/memory-x/ — Memory-X, une feature GELÉE (à reprendre un jour de pluie)

**Date** : 2026-05-22 (prototype d'origine) · **Dernière révision** : 2026-09-04
**Statut** : GELÉ — feature complète et qui a tourné, gardée telle quelle, lue par aucun code (F-C153 dégel, F-C156 non chargé, F-C157 rosters divergents)
**Référencé par** : `runtime/CLAUDE.md` (table de `priv/`), `Fleet.Catalogue` (@moduledoc), `test/fleet/sp_builder_monk_test.exs`, `test/fleet/cap_profile/monks_*_test.exs`

## Ce que c'est

Un service de mémoire pour la fleet : un **Archivist** orchestre N **Monks**, chaque monk tient une
tranche d'un corpus documentaire et répond en JSON strict aux questions des autres agents, par une
socket exposée par l'archiviste. Aucun agent ne charge le corpus dans son contexte : il pose une
question à Memory-X.

Ça a tourné (instances `alpha` et `beta`, test live du 2026-05-17 PASS, cf. les commentaires de
`prototype/fleets/`). Ce n'est pas nécessaire pour livrer le projet, c'est un accessoire : il reste ici
en entier, pour être repris sans réinventer.

## Contenu

| dossier | forme | contenu |
|---|---|---|
| `prototype/cap-profiles/` | profils dans la forme d'origine (`invocation.systemPrompt` en chemin absolu, pas d'`interlocutor`, hors schéma courant) | `archivist.yaml`, `monk.yaml` |
| `prototype/fleets/` | `kind: MemoryInstance`, un type qu'aucun schéma courant ne connaît | `memory-alpha.yaml` (corpus moon-shot, 5 monks), `memory-beta.yaml` (corpus beyond, 10 monks) |
| `prototype/sp/` | system prompts | `archivist.md`, `monk.md`, et leur README |
| `monks/` | profils v2.5 (conformité tenue par `monks_conformance_test.exs`, un témoin `skip`) | `alpha.yaml`, `beta.yaml`, `archivist.yaml`, cinq `monk-alpha-*.yaml`, dix `monk-beta-*.yaml`, et son README |

Les deux jeux décrivent la même feature à deux époques ; leurs rosters divergent (F-C157) et c'est
attendu. `monks/` est le point de départ d'un dégel, `prototype/` la référence de ce qui a fonctionné.

## Ce qui reste câblé dans le runtime

- `Fleet.SPBuilder.Monk` résout les monks depuis le registre `cap_profile/cap-profiles/monks/` d'un
  catalogue (`Fleet.Catalogue.monk_registry_root/0`). Ce registre est ABSENT des catalogues
  embarqués : absent = monks gelés, chemin dormant par design.
- Les témoins `sp_builder_monk_test.exs`, `cap_profile/monks_frozen_test.exs`,
  `cap_profile/monks_conformance_test.exs` sont `@moduletag skip` avec le motif « Memory-X
  frozen ». Leurs fixtures pointent le registre `cap_profile/cap-profiles/monks/` du catalogue
  embarqué, qui n'existe pas : joués avec `--include skip`, ils rougissent (`registry_unreadable`).
  C'est l'état attendu d'un gel, et c'est pourquoi le dégel commence par re-pointer les fixtures.

## Pour dégeler

1. Décider où Memory-X vit : par projet, ou système (une instance par machine). C'est l'arbitrage
   qui a gelé la feature (BL), pas un défaut technique.
2. Déplacer `monks/` dans le registre du catalogue choisi (`cap_profile/cap-profiles/monks/`), re-pointer
   les fixtures des trois témoins, retirer leurs `@moduletag skip`.
3. Décider du sort de `prototype/` : les SP y sont plus complets que les profils de `monks/` (mandat par
   variables d'environnement, cycle boot/questions) ; ils se reportent dans les blocs SP du
   catalogue, ils ne se chargent pas tels quels.
