# fleet/services — les services de la MACHINE

**Date** : 2026-08-25
**Dernière révision** : 2026-08-25
**Statut** : EN SERVICE — source canonique de ce qui est posé en `/opt/lcars`
**Référencé par** : `deploy/modules.d/62-runtime-helpers.sh` (les pose) · `deploy/modules.d/64-services.sh`
(les démarre) · `deploy/docker/Dockerfile` (les copie dans l'image)

## Ce que ce répertoire est

Le code qui tourne **après** l'install, hors du checkout, la plupart du temps en root. Ce n'est ni
du provisionnement (`deploy/`) ni le runtime BEAM (`lib/`) : ce sont les **services de la machine**.

Il porte les deux chaînes d'escalade de la boîte, et c'est ce qui justifie qu'on puisse les trouver :

```
lcars catalogue install                 l'humain
  → socket unix, SO_PEERCRED            le noyau enonce l'appelant
  → catalogue-executor.py               root, demande `is_admin` a la forge
  → forge-gestures.sh

Fleet.Admiral.ToolchainReconciler       le BEAM, sous l'humain
  → sudoers etroit (%fleet, UN binaire nomme, jamais un shell)
  → toolchain-converger.sh              root
```

## Qui pose quoi

| | posé où | tenu par |
|---|---|---|
| `catalogue-executor.py` | `/opt/lcars/` | systemd `lcars-catalogue` |
| `human-converger.sh` | `/opt/lcars/` | systemd `lcars-converger` |
| `console-landing.sh` + `console-deck.py` | `/opt/lcars/` | systemd `lcars-landing` |
| `console.sh` · `console-humans.sh` · `console-status.sh` · `console-pod.sh` | `/opt/lcars/` | piloté par `lcars-converger` |
| `forge-gestures.sh` | `/opt/lcars/` | l'entrypoint **et** l'exécuteur |
| `toolchain-converger.sh` | `/usr/local/bin/lcars-toolchain-converge` | le BEAM, via sudo |
| `console.tmux.conf` · `skel.bashrc` | données du même rail | — |

Deux rails, une source : le `COPY` du Dockerfile côté boîte, `62-runtime-helpers` côté poste. Le
miroir entre les deux est tenu dans les deux sens par `deploy/tests/runtime_helpers.bats`.

## La règle, et le témoin qui la tient

**Tout fichier d'ici est POSÉ quelque part** — dans `HELPERS=()` du module, ou dans un `COPY`.
`deploy/tests/services_dir.bats` le vérifie, et vérifie aussi que `deploy/docker/` n'en reprend
aucun.

⚠ Ce n'est pas une redondance avec le miroir : celui-ci croise **deux listes**, celui-là croise le
**répertoire** avec elles. Un fichier présent et déclaré nulle part est invisible au premier. C'était
l'état d'une exploration de 1211 lignes restée trois semaines dans l'arbre sans que rien ne s'en
aperçoive — ni copiée, ni posée, ni appelée.

**Un fichier rangé est un fichier dont plus personne ne se demande s'il sert.**
