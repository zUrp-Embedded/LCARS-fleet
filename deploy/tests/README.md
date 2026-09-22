# deploy/tests — les témoins de l'installeur

**Date** : 2026-08-30
**Dernière révision** : 2026-09-14
**Statut** : actif — pointeurs, pas un contrat
**Référencé par** : `runtime/test/README.md`

`deploy` est un programme distinct du runtime : il doit pouvoir vivre sans lui. Son corpus vit
donc ici, et **le chemin d'un témoin est celui de sa cible sous `deploy/`** —
`modules.d/61-forge-structure.sh` se teste dans `modules.d/`. Chaque dossier se qualifie par
l'existence de son jumeau, et `tests.dirs_mirror_source` (`mix lcars.contracts.check`) le refuse
sinon. `install.sh` est le seul fichier de l'installeur hors de `deploy/` (il vit à la racine du
dépôt pour le `curl | bash`) : son témoin, `install.bats`, vit à la racine de ce corpus.

Les témoins sans cible unique vivent à la racine du corpus (invariants d'idiomes, de variables,
d'adminité, poseurs…) ou sous `transverse/` quand ils traversent plusieurs zones. Quand une
cible porte plusieurs témoins, le nom du fichier est `<cible>_<sujet>` ; `gate.sh` fait
exception avec `installer_gate.bats`.

## Trois couches

Chaque témoin déclare sa couche en deuxième ligne, sous son shebang, `# bats file_tags=<couche>` ;
`gate.sh` refuse un témoin qui n'en a pas, ou qui n'a pas de shebang.

| couche | ce qu'elle mesure | entrée |
|---|---|---|
| `unit` | les fonctions d'une lib, sourcées et jouées avec des doublures | `deploy/gate.sh unit` |
| `integration` | un script ou un module joué entier sous un décor (`unshare -Ur` pour les chemins root) | `deploy/gate.sh integration` |
| `structure` | ce que les sources doivent porter, lu sans les jouer : invariants d'idiomes, manifestes, composes, Dockerfile | `deploy/gate.sh structure` |

La couche est celle du fichier. Un fichier qui mêle des cas joués et des lectures de source porte
la couche de ses cas joués ; le partage en deux fichiers se fait quand le fichier est repris.
Chaque lecture de source d'un tel fichier porte, juste au-dessus de son `@test`,
`# bats test_tags=structure` : un marqueur de tri, que `gate.sh` ne lit pas (ses entrées suivent la
couche du fichier). `bats --filter-tags structure -r deploy/tests` joue les fichiers de structure
et ces cas marqués ; `bats --filter-tags '!structure' -r deploy/tests`, les cas joués seuls.

`deploy/gate.sh` sans argument joue tout, après le plancher shellcheck et les en-têtes
déclaratifs ; c'est ce que `pack.sh` joue avant d'empaqueter. `runtime/test/shell_gate.sh` ne joue
rien d'ici.

La porte demande `bats` et `shellcheck`, et refuse de passer sans eux. Les cas qui rendent un compose
par `docker compose config` (sans daemon) demandent la CLI docker et son plugin compose : sans eux,
`support/compose.bash` (`compose_requis`) les saute en le disant. Un cas sauté n'est pas joué : le
verdict de la porte les compte, et une porte verte qui en compte n'a pas vérifié les composes.

## Écrire un témoin

Un cas mesure une chose observable : ce qu'un script affiche, rend ou pose. Un `grep` sur la
source n'est pas un témoin du comportement ; il n'a sa place que dans la couche `structure`, pour
un invariant que le code ne peut pas tenir seul. Une assertion par ligne : dans un cas bats, `a &&
b` n'échoue que si `b` échoue (invariant I22 de `idiom_walls.bats`). Les doublures notent leur argv dans
un fichier et rendent vite ; un secret ne passe jamais en argv. `refute.bash` est à la racine du
corpus, et un témoin le charge par son chemin relatif (`load refute`, `load ../refute`,
`load ../../refute`).

Un témoin ne lit jamais les fichiers de la machine qui joue la porte : il pose `LCARS_DECOR_ROOT`,
sous lequel la lib lit tout chemin de `deploy/installer-constants.env` et tout chemin système
(`prov_decor`), et il double les binaires par un PATH de décor. `support/decor.bash` pose ce décor
(`decor_pose`), lance une forge HTTP locale (`forge_double_start`, `support/forge_double.py`) pour
les gestes qui parlent à l'API, et note l'argv et l'environnement des commandes qu'un secret pourrait
traverser (`espion_enfants`) ; `support/` porte l'outillage, pas des témoins.
