# deploy/tests — les témoins de l'installeur

**Date** : 2026-08-30
**Dernière révision** : 2026-08-31
**Statut** : actif — pointeurs, pas un contrat
**Référencé par** : `fleet/test/README.md`

`deploy` est un programme distinct du runtime : il doit pouvoir vivre sans lui. Son corpus vit
donc ici, et **le chemin d'un témoin est celui de sa cible sous `deploy/`** — `modules.d/61-forge-structure.sh`
se teste dans `modules.d/`, pas ailleurs. Rien à retenir : chaque dossier se qualifie par l'existence
de son jumeau, et `tests.dirs_mirror_source` (`mix lcars.contracts.check`) le refuse sinon.

`transverse/` est la seule zone sans jumeau : les témoins qui n'ont pas de cible unique — conformité
sur plusieurs modules à la fois, ou sujet hors de `deploy/`. Elle est nommée dans `@test_zones`, pas
déduite d'un tiret bas.

Quand une cible porte plusieurs témoins, le nom du fichier est `<cible>_<sujet>` : `docker/entrypoint.sh`
a `docker/entrypoint_seat.bats` et `docker/entrypoint_humans.bats`. Un témoin suit sa cible quand
elle change de logiciel : ceux de `63-forge-tokens` sont partis avec le geste dans
`fleet/test/services/forge.d/` (lot 6), et l'appelant mince qui reste n'a pas de témoin propre.

Joué par `deploy/gate.sh`, la porte de l'installeur (⚖ user 2026-09-04, Q4 : « chacun joue son
gate, on les split »), qui découvre récursivement tous les `.bats` d'ici ; `fleet/test/shell_gate.sh`
ne les joue plus. `refute.bash` est à la racine ; les sous-dossiers font `load ../refute`.
