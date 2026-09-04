# fleet/services — les services de la MACHINE

**Date** : 2026-08-25
**Dernière révision** : 2026-09-04 (lot 6 : les modules du produit — human.d, forge.d, lib)
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
  → fleet/bin/lcars-toolchain-converge  root  (binaire de PATH, pas un service)
```

## Qui pose quoi

| | posé où | tenu par |
|---|---|---|
| `catalogue-executor.py` | `/opt/lcars/` | systemd `lcars-catalogue` |
| `human-converger.sh` | `/opt/lcars/` | systemd `lcars-converger` |
| `console-landing.sh` + `console-deck.py` | `/opt/lcars/` | systemd `lcars-landing` |
| `console.sh` · `console-humans.sh` · `console-status.sh` · `console-pod.sh` | `/opt/lcars/` | piloté par `lcars-converger` |
| `forge-gestures.sh` | `/opt/lcars/` | le boot de la boîte **et** l'exécuteur |
| `provision-role-tokens.sh` | `/opt/lcars/` | le minteur de jetons de rôle — `63-forge-tokens` sur un poste, l'init de la boîte |
| `forge.d/` · `human.d/` · `lib/` | `/opt/lcars/fleet/services/` | les MODULES du produit et leur protocole (voir ci-dessous) |
| `console.tmux.conf` · `skel.bashrc` | données du même rail | — |

Deux rails, une source : le `COPY` du Dockerfile côté boîte, `62-runtime-helpers` côté poste. Le
miroir entre les deux est tenu dans les deux sens par `deploy/tests/runtime_helpers.bats`.

## Les modules du produit — `human.d/`, `forge.d/`, `lib/`

⚖ user 2026-09-04 (chantier deploy-independance, Q3) : « la frontière, c'est : joué uniquement à
l'install, ou utilisé en prod ? ». Trois familles de modules sont **utilisées en prod** et vivent
donc ici, dans le dialecte des modules (`p_*`, `verdict_*`, `LCARS_*`), sur le protocole de
`lib/module-protocol.sh` (`lib/human-protocol.sh` y ajoute la personne) :

- `human.d/` — les modules per-humain, joués par `human-converger.sh` à chaque humain que la
  forge inscrit, sous l'identité de l'humain ;
- `forge.d/` — les gestes de forge (jetons de rôle, cache des catalogues, branche ops, client
  OAuth2 du deck), joués par la boîte à l'init de son instance et à chaque boot, et par
  l'installeur à l'install (`deploy/modules.d/45-catalogues`, `63-forge-tokens`, `65-ops-branch`,
  `66-deck-oidc` sont des appelants minces).

L'installeur APPELLE ces modules ; il ne leur prête rien, et ils ne lui empruntent rien — c'est
la frontière. Chaque dossier porte son README, qui instruit le protocole `<module> check|apply`.

⚠ **CE RÉPERTOIRE NE PORTE QUE DES SERVICES ET LES MODULES QUE CES SERVICES JOUENT**, c'est-à-dire
ce que systemd, le convergeur ou le boot de la boîte démarre ou joue. Deux binaires y ont vécu et n'en étaient pas : `lcars-toolchain-converge` et
`lcars-authority-ask`, que le BEAM et `fleet/bin/lcars` INVOQUENT. Rien ne les démarrait, ils
n'étaient dans aucune unité, dans aucun `STARTERS` — et ils arrivaient sur le `PATH` sous un nom
différent du leur, parce que la convention d'ici est `*.sh`/`*.py`. Ils vivent depuis le
2026-08-27 sous `fleet/bin/`, avec leur nom définitif, comme `lcars` et `fleet_v2`. Le renommage
à la pose a disparu avec le rangement : il ne codait rien, il traduisait l'erreur de répertoire.

## La règle, et le témoin qui la tient

**Tout fichier d'ici est POSÉ quelque part** — dans `HELPERS=()` du module, ou dans un `COPY`.
`deploy/tests/services_dir.bats` le vérifie, et vérifie aussi que `deploy/docker/` n'en reprend
aucun.

⚠ Ce n'est pas une redondance avec le miroir : celui-ci croise **deux listes**, celui-là croise le
**répertoire** avec elles. Un fichier présent et déclaré nulle part est invisible au premier. C'était
l'état d'une exploration de 1211 lignes restée trois semaines dans l'arbre sans que rien ne s'en
aperçoive — ni copiée, ni posée, ni appelée.

**Un fichier rangé est un fichier dont plus personne ne se demande s'il sert.**
