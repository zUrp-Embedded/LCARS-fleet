# deploy/tests — les témoins de l'installeur

**Date** : 2026-08-30
**Dernière révision** : 2026-08-31
**Statut** : actif — pointeurs, pas un contrat
**Référencé par** : `fleet/test/README.md`

`deploy` est un programme distinct du runtime : il doit pouvoir vivre sans lui. Son corpus vit
donc ici, et **le chemin d'un témoin est celui de sa cible sous `deploy/`** — `modules.d/50-forge.sh`
se teste dans `modules.d/`, pas ailleurs. Rien à retenir : chaque dossier se qualifie par l'existence
de son jumeau, et `tests.dirs_mirror_source` (`mix lcars.contracts.check`) le refuse sinon.

`transverse/` est la seule zone sans jumeau : les témoins qui n'ont pas de cible unique — conformité
sur plusieurs modules à la fois, ou sujet hors de `deploy/`. Elle est nommée dans `@test_zones`, pas
déduite d'un tiret bas.

Quand une cible porte plusieurs témoins, le nom du fichier est `<cible>_<sujet>` : `50-forge.sh` a
`50-forge_ci_runner.bats` et `50-forge_probes.bats`.

Joué par `fleet/test/shell_gate.sh`, câblé dans `mix gate`, qui découvre récursivement tous les
`.bats` d'ici. `refute.bash` est à la racine ; les sous-dossiers font `load ../refute`.
