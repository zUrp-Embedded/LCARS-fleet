# runtime/services — les services de la MACHINE

**Date** : 2026-08-25
**Dernière révision** : 2026-09-04
**Statut** : EN SERVICE — source canonique de ce qui est posé en `/opt/lcars`
**Référencé par** : `deploy/modules.d/62-runtime-helpers.sh` (les pose) · `deploy/modules.d/64-services.sh`
(les démarre) · `deploy/docker/Dockerfile` (les copie dans l'image)

## Ce que ce répertoire est

Le code qui tourne **après** l'install, hors du checkout, la plupart du temps en root. Ce n'est ni
du provisionnement (`deploy/`) ni le runtime BEAM (`lib/`) : ce sont les **services de la machine**.

Il porte les deux chaînes d'escalade de la boîte, et c'est ce qui justifie qu'on puisse les trouver :

```
lcars catalogue install                 l'humain
  → catalogue.sock, SO_PEERCRED         le noyau enonce l'appelant
  → catalogue-executor.py               lcars-authority, demande `is_admin` a la forge
  → forge-gestures.sh install

lcars-authority-ask <compte>            un shell, un rail
  → roles.sock, SO_PEERCRED             le meme service, appartenance a `humans` demandee a la forge
  → le jeton du role, une ligne

Fleet.Admiral.ToolchainReconciler       le BEAM, sous l'humain
  → toolchain.sock (rien sur le fil)    la socket dit le verbe, la forge dit le contenu
  → privileged-executor.py              root, l'UNIQUE process root : il resout la tete de `tool_request`
  → runtime/bin/lcars-toolchain-converge <sha>
```

## Qui pose quoi

| | posé où | tenu par |
|---|---|---|
| `catalogue-executor.py` (+ `lcars_socket.py`) | `/opt/lcars/` | systemd `lcars-catalogue` (compte `lcars-authority`) |
| `privileged-executor.py` (+ `lcars_socket.py`) | `/opt/lcars/` | systemd `lcars-privileged` (root) |
| `human-converger.sh` · `human.d/` · `agent/` | `/opt/lcars/` ; les sous-arbres à côté (cible `/opt/lcars/services/`, le rail pose encore `/opt/lcars/services/`) | systemd `lcars-converger` |
| `console-landing.sh` + `console-deck.py` | `/opt/lcars/` | systemd `lcars-landing` |
| `console.sh` · `console-humans.sh` · `console-status.sh` · `console-pod.sh` | `/opt/lcars/` | piloté par `lcars-converger` |
| `forge-gestures.sh` · `forge-recipe/` | `/opt/lcars/` ; la recette à côté (même cible que ci-dessus) | le boot de la boîte **et** l'exécuteur |
| `provision-role-tokens.sh` | `/opt/lcars/` | le minteur de jetons de rôle — `63-forge-tokens` sur un poste, l'init de la boîte |
| `forge.d/` · `human.d/` · `lib/` · `box/` | `/opt/lcars/services/` | les MODULES du produit, leur protocole, et l'init/boot de la boîte (voir ci-dessous) |
| `supervise.sh` | `/opt/lcars/` | la BOÎTE (`docker/entrypoint.sh`), à la place du `Restart=` que le poste laisse à systemd |
| `admiral/skills/` | le `~/.claude` du siège | le provisioning |
| `console.tmux.conf` · `lcars.bashrc` | données du même rail | — |

Deux rails, une source : le `COPY` du Dockerfile côté boîte, `62-runtime-helpers` côté poste. Le
miroir entre les deux est tenu dans les deux sens par `deploy/tests/transverse/runtime_helpers.bats`.

## Les modules du produit — `human.d/`, `forge.d/`, `lib/`, `box/`

⚖ user 2026-09-04 (chantier deploy-independance, Q3) : « la frontière, c'est : joué uniquement à
l'install, ou utilisé en prod ? ». Trois familles de modules sont **utilisées en prod** et vivent
donc ici, dans le dialecte des modules (`p_*`, `verdict_*`, `LCARS_*`), sur le protocole de
`lib/module-protocol.sh` (`lib/human-protocol.sh` y ajoute la personne) :

- `human.d/` — les modules per-humain, joués par `human-converger.sh` à chaque humain que la
  forge inscrit, sous l'identité de l'humain ;
- `forge.d/` — les gestes de forge (jetons de rôle, cache des catalogues, branche ops, client
  OAuth2 du deck), joués par la boîte à l'init de son instance et à chaque boot, et par
  l'installeur à l'install (`deploy/modules.d/45-catalogues`, `63-forge-tokens`, `65-ops-branch`,
  `66-deck-oidc` sont des appelants minces) ;
- `box/` — l'init de l'instance et le boot de la boîte (`init.sh`, `boot.sh`, le PID 1 de l'image).

L'installeur APPELLE ces modules ; il ne leur prête rien, et ils ne lui empruntent rien — c'est
la frontière. Chaque dossier porte son README, qui instruit le protocole `<module> check|apply`.
Une machine posée (poste ou boîte) porte cet arbre à `/opt/lcars/services/` ; un checkout, à
`runtime/services/`.

⚠ **CE RÉPERTOIRE NE PORTE QUE DES SERVICES ET LES MODULES QUE CES SERVICES JOUENT**, c'est-à-dire
ce que systemd, le convergeur ou le boot de la boîte démarre ou joue. Un binaire que le BEAM ou `runtime/bin/lcars` INVOQUE (`lcars-toolchain-converge`,
`lcars-authority-ask`) vit sous `runtime/bin/`, sous son nom définitif, comme `lcars` et
`fleet` : rien ne le démarre, il n'est dans aucune unité ni aucun `STARTERS`, et la convention
d'ici (`*.sh`/`*.py`) lui donnerait sur le `PATH` un autre nom que le sien.

## La règle, et le témoin qui la tient

**Tout fichier d'ici est POSÉ quelque part** — dans `HELPERS=()` du module, ou dans un `COPY`.
`deploy/tests/services_dir.bats` le vérifie, et vérifie aussi que `deploy/docker/` n'en reprend
aucun.

⚠ Ce n'est pas une redondance avec le miroir : celui-ci croise **deux listes**, celui-là croise le
**répertoire** avec elles. Un fichier présent et déclaré nulle part est invisible au premier
(mesuré : une exploration de 1211 lignes est restée trois semaines dans l'arbre sans être copiée,
posée ni appelée).

**Un fichier rangé est un fichier dont plus personne ne se demande s'il sert.**
