# test/ — map

**Date**: 2026-07-18
**Last revised**: 2026-09-05
**Status**: active — index of the test tree (a map, not a contract)
**Referenced by**: —

**This file is a map, not the contract.** Each test file owns its intent in its own
`@moduledoc`/describes. Nothing here is restated, only pointed at.

## Où est le témoin d'un fichier

**Le chemin le dit.** `lib/<x>/<y>.ex` → ses témoins vivent dans `test/<x>/`, et ils commencent
tous par `<y>` :

    lib/fleet/event_router/bus.ex
    ├── test/fleet/event_router/bus_test.exs                 ← canonique
    ├── test/fleet/event_router/bus_registry_empty_test.exs  ← satellite : préfixe + sujet
    └── test/fleet/event_router/bus_safe_emit_test.exs       ← satellite

`ls test/fleet/api/` répond à la question ; il n'y a rien à deviner et rien à grepper. Un témoin
nommé d'après le CONTRAT qu'il épingle (`bus_safe_emit`, `application_boot_knob`) porte plus
d'information qu'un `<module>_test.exs` muet — le préfixe le rend trouvable sans lui coûter ce nom.

## Lire un témoin sans sa prose

Un quart des lignes de la suite est de la prose (commentaires, `@moduledoc`, noms), coupée en
blocs de une à trois lignes qui interrompent le code toutes les quelques lignes : un `grep` y
touche autant de commentaires que de code (mesuré : `refute` 130 fois sur 1460, `async: false`
80 fois sur 218). `mix lcars.test.view` projette un fichier sans perte, numérotation conservée :

    mix lcars.test.view code  test/fleet/layout_test.exs    # le code seul, prose blanchie
    mix lcars.test.view plan  test/fleet/layout_test.exs    # describe / test / property, boucles `for` marquées
    mix lcars.test.view prose test/fleet/layout_test.exs    # chaque commentaire, rattaché au témoin le plus proche
    mix lcars.test.view check test/**/*_test.exs            # la projection est sans perte sur tout l'arbre

L'autorité sur « ceci est un commentaire » est le tokenizer d'Elixir, jamais une regex (un `#`
dans un heredoc n'est pas un commentaire). `test/mix/test_view_test.exs` tient la perte à zéro sur
tout l'arbre ; le jour où une forme nouvelle le fait rougir, c'est l'outil qu'on répare, pas le
témoin qu'on exclut.

## Compter et chronométrer la suite

La ligne de bilan d'ExUnit ne compte pas pareil d'une version à l'autre (1.20 retranche les
skippés de chaque compteur, 1.18 les laisse) et ne dit rien de qui prend le temps. Le manifeste
des témoins exécutés est la seule source de vérité pour compter et comparer deux runs :

    TIME_OUT=/tmp/times.tsv mix test --formatter Fleet.Test.TimeFormatter --formatter ExUnit.CLIFormatter

Une ligne par témoin, `module`, `nom`, `état`, `async`, `temps_us`, `fichier`
(`test/support/time_formatter.ex`). Deux manifestes se diffent sur les deux premières colonnes.
Mesuré le 2026-09-06 : 138 modules `async: false` font 266 s de mur sur 317 (320 aujourd'hui), et vingt d'entre eux
en font 84 %.

Cette forme est **vérifiée à l'échelle du dossier** par `tests.dirs_mirror_source`
(`mix lcars.contracts.check`) : un témoin sous un dossier qui n'existe pas sous `lib/` fait rougir
le gate.

⚠ **Le gate ne réclame PAS un témoin par source.** Cette moitié-là n'est pas décidable sans un
plancher enregistré. Mesure du 2026-08-30 : 130 sources sur 247 n'ont pas de témoin canonique — 26
ont au moins un satellite qui porte leur nom, et pour les 104 autres le nom de fichier ne permet pas
de trancher, parce qu'un témoin nommé d'après le contrat qu'il épingle ne nomme pas sa cible.
Réclamer le canonique ici fabriquerait 104 coquilles « pas de test » dont personne n'aurait vérifié
la vérité. Le préfixe est la convention, le dossier est le mur, le reste est un chantier.

## Layout

Sous `test/`, un dossier est soit le miroir d'un dossier de `lib/`, soit l'une des zones nommées
ci-dessous. Il n'y a pas de troisième cas — et la racine de `test/` ne porte aucun témoin.

| chemin | contenu | joué par |
|---|---|---|
| `test/fleet/**`, `test/mix/**` | ExUnit, miroir de `lib/` | `mix test` |
| `test/bin/`, `test/services/` | bats et python des scripts de `runtime/bin`, `runtime/services` (`etc/` ne porte plus de script : ses outils vivent dans `deploy/lib/`, testés par `deploy/tests/lib/`` | `shell_gate` |
| `test/crosscutting/` | témoins sans cible unique (scan du dépôt entier) | `shell_gate` |
| `test/integration/` | multi-cible, hors-mix | manuel |
| `test/probes/` | sondes manuelles (`gate-r*.sh`), hors `mix gate` — leurs en-têtes le disent | manuel |
| `test/support/` | stubs, doubles, TestEnv — compilés par `elixirc_paths(:test)` ; les BANCS d'un rail (`support/<domaine>/*_bench.ex`, module `Fleet.<Domaine>.<Rail>Bench` — absorbé par la boundary du domaine, comme `Fleet.Pilot.ForgeStubs` ; ses stubs et ses starters, partagés par les fichiers qui découpent ce rail par sujet) | — |
| `test/fixtures/` | données | — |

Les bats et python suivent la même règle de préfixe que l'ExUnit : `bin/publish-transform.sh` →
`test/bin/publish-transform.bats` + `publish-transform_boundary.bats`, `_history`, `_identity`.
Le nom du script, tirets compris, est le préfixe — ce qui se cherche est ce qui se lit dans `bin/`.

## La frontière avec `deploy/tests/`

`deploy` est un autre programme — l'installeur — et il a son propre arbre de témoins, en
miroir de `deploy/` : voir `deploy/tests/README.md`. Les deux arbres n'échangent rien, pas
même leur helper : `refute.bash` existe de chaque côté et `tests.refute_copies_agree` refuse qu'ils
divergent.

⚠ **`lib` est élidé ici et pas là-bas**, et c'est la seule chose de tout le dispositif qui ne se lit
pas dans l'arbre. `runtime/lib/` contient TOUT le code Elixir : préfixe qui ne discrimine rien, élidé
comme dans tout projet Elixir. `deploy/lib/` est un dossier à côté de `modules.d/` et `docker/` :
il discrimine, il reste. Le motif est dans `tests.dirs_mirror_source`, qui porte les deux racines —
pas dans cette phrase, qui ne fait que la répéter.


## Deux faux-verts que le gate ferme

- `tests.witness_naming` — `mix test` ne ramasse que `*_test.exs` (`test_pattern`) et ne dit
  RIEN de ce qu'il laisse. Un `foo_spec.exs` ou un `foo_tests.exs` est une suite entière qui compte
  pour zéro en silence. La faute est une lettre, la conséquence est un corpus fantôme. Le mur tient
  la même règle de nommage pour les `.bats` et les `.py`.
- `tests.corpora_on_record` — tout corpus bats/python du dépôt est déclaré `:gated` ou
  `{:out, motif}`. Un corpus que personne ne joue ne pourrit pas bruyamment : il rapporte une
  couverture qu'il ne fournit pas.

## Hors-mix

`shell_gate.sh` (câblé dans `mix gate`) est le point d'entrée des tests que `mix test` ne voit pas :
les quatre suites python, nommées une par une dans son registre `PYTESTS`, et tous les `.bats`
trouvés récursivement sous `test/`, `.claude/skills/` et `runtime/git-hooks/tests/` —
`deploy/tests/` se joue par `deploy/gate.sh`. `bats` absent n'échoue pas — le compte des suites manquées est ANNONCÉ,
et `BATS_MISSING_FATAL=1` durcit le jour où `bats-core` est un prérequis posé partout.
