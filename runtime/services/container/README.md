# box — le boot de la boîte, côté produit

**Date** : 2026-09-04
**Statut** : actif — lot 6 du chantier deploy-independance
**Référencé par** : `runtime/services/README.md`, `deploy/docker/Dockerfile` (`ENTRYPOINT`)

⚖ user 2026-09-04 (Q1) : « pour docker, pourquoi on pourrait pas build l'image, et qu'elle reste
alive entre 2 démarrages ? … dans docker, le deploy semble n'avoir aucun intérêt à partir dans le
container ». Le modèle est celui de Docker : l'image est le produit, le conteneur une instance,
l'état dans le volume, l'entrypoint démarre le service. Ce dossier porte ce que la boîte fait
d'elle-même, sans l'installeur.

| geste | ce qu'il fait |
|---|---|
| `boot.sh` | le BOOT de la boîte, PID 1 sous `tini` (`ENTRYPOINT` du Dockerfile) : joue `init.sh apply`, les quatre gestes de `../forge.d/` (`tokens`, `catalogues`, `ops-branch`, `deck-oidc`), le convergeur d'humains, la console et le deck, les deux exécuteurs, puis `exec sshd`. Ses mots (`verify`, `roles`, `roles-tfvars`, `catalogue-root`, `catalogue-source`) sont l'API de l'image et délèguent à `lcars tool` ; `forge-apply` joue `forge-gestures apply` dans la boîte |
| `init.sh` | l'init de l'INSTANCE : le siège (résolu puis créé), les zones de face, la source et le corpus ops, les clés d'hôte SSH, le layout du volume et du magasin, la skill du siège, `pilot.assignee` — idempotent, ce qu'une instance neuve doit avoir sur son volume |

## Le protocole

`init.sh` répond à quatre verbes — `<module> seat|secrets|store|apply` — sur le protocole des modules du produit
(`../lib/module-protocol.sh`).

- `init.sh secrets` : importe dans le répertoire privé de la boîte ce que le compose monte sous
  `/run/secrets` (`forge_master_token`, `forge_seed_password` — posés côté hôte par `box config`).
  Une fois, puis seulement si le secret change (rotation). Un montage vide n'est pas une faute.
- `init.sh seat` : résout le siège (table `forge-uid.map`, sinon le #1 de la forge par le jeton
  master, sinon la semence `LCARS_ADMIRAL`), l'enregistre, écrit `/etc/lcars/seat.uid` et
  `/run/lcars-seat.login`. Rend `0` résolu, `1` divergence (la semence contredit une source
  durable — on ne renomme pas un home en silence), `3` indéterminable : c'est l'état « en attente
  de configuration », la boîte reste debout pour que `box config` soit jouable.
- `init.sh store` : le magasin — les quatre arbres que l'hôte monte sous `LCARS_STORE_ROOT`
  (`cache`, `toolchains`, `sysroots`, `state`) reçoivent leur mode et leur propriétaire. Un arbre
  absent est un volume non monté : drift nommé, jamais fabriqué dans le conteneur ; `LCARS_STORE_ROOT`
  non posé est un drift aussi. Rend `0` convergé, `2` drift, `1` échec.
- `init.sh apply` : `secrets`, `seat`, puis tout le reste (dont `store`). Rend `0` convergé, `2` drift résiduel, `1` échec,
  `3` en attente de configuration.

Ce qu'il lit : `LCARS_UID`, `LCARS_ADMIRAL`, `LCARS_SSH_AUTHORIZED_KEYS`, `FORGE_BASE_URL`,
`LCARS_STORE_ROOT`, `LCARS_DECK_OIDC_FILE` (sous le volume `var` : l'état du client OAuth2 survit
à un conteneur recréé, DI-11), `LCARS_SOURCE_DIR`/`LCARS_SOURCE_REMOTE`/`LCARS_SOURCE_REF` — ce que le
compose donne au conteneur — et les défauts du protocole pour le reste.

Ce qu'il ne fait pas : les gestes de forge (`../forge.d/`, le minteur `../provision-role-tokens.sh`),
joués par `boot.sh` après lui ; les humains (le convergeur) ; les services (`boot.sh`).

`boot.sh` ne joue AUCUN module de l'installeur, et rien dans la boîte ne lit `deploy/` : l'image
runtime ne le porte plus (lot 7) — seul le stage `verify` du Dockerfile le copie pour jouer le
doctor au build, et `final` repart de `runtime` avec le tampon `/opt/lcars/.verified`. Les
fichiers de boot sont des objets du produit, hors de la table de l'installeur : `/run/lcars-boot.state`
(`awaiting-config`, `init-failed`), `/run/lcars-seat.login`, `/run/lcars-provision.rc`,
`/run/lcars-humans.rc`, `/opt/lcars/.verified` — `deploy/container status` les lit de l'hôte.
