# deploy — l'installeur de LCARS-fleet

**Date** : 2026-07-05
**Dernière révision** : 2026-09-13 (chantier installeur : un pipeline, trois couches de témoins, les workflows de CI et de publication partis ; `provision update` retiré, exécuter et qualifier séparés dans la lib)
**Statut** : en service
**Référencé par** : `deploy/tests/README.md`, `deploy/tests/provision.bats` (la table des modules)

`deploy/` porte l'installation, et rien d'autre : ce qui amène une machine nue — une distribution
WSL2, une machine Linux dédiée, un conteneur — jusqu'à `fleet start`. Le produit vit sous
`runtime/` ; ses auxiliaires système (services, consoles, gestes de forge) vivent dans
`runtime/services/` et sont posés par le module `62-runtime-helpers`.

## Les entrées

| commande | rôle |
|---|---|
| `install.sh` (racine) | l'installeur : il mesure la machine, montre ce qu'il va faire, demande confirmation et délègue. Sans option, LCARS tourne dans un conteneur ; `--workstation` l'installe dans le système ; `--bench` monte aussi la forge, son runner CI et un compte de démonstration. `--check`, `--dry-run`, `--from-release`, les ports : voir `install.sh --help` |
| `deploy/workstation up [--from <kit>] \| doctor` | le délégué du poste : `up` escalade par `sudo` une fois, joue `provision apply` depuis ce checkout ou depuis un kit détaré sous `~/.lcars/kits/<nom>/`, puis `accept` ; `doctor` sonde sans escalader |
| `deploy/container <verbe>` | le délégué du conteneur : `up`, `pull`, `build`, `status`, `shell`, `logs`, `down`, `reset`, `config`, `forge-check`, `forge-apply`, `runner-token`, `source-push` ; une conf par projet compose sous `~/.lcars/container/` |
| `deploy/pack.sh [--publish \| --no-image]` | le lanceur de version : gate, release, doc, kit `.tar.gz`, installeur de la version, image docker. Le kit et son `.sha256` restent dans `<parent du checkout>/lcars-packs/` (`LCARS_PACK_DIR` le déplace), le tiroir `dist/<tag>/` les reprend par liens durs avec l'installeur de la version, l'image reste dans le daemon ; `--publish` pousse l'image sur le registre, puis le kit et l'installeur sur la release de la forge |
| `deploy/provision apply \| doctor \| list \| audit` | le runner des modules, joué par `workstation` et par la construction de l'image |
| `deploy/accept` | l'acceptation d'une installation : les identifiants annoncés ouvrent la forge, des runners servent les labels que les workflows d'un projet demandent, la fleet démarre sous l'humain de fleet |

## Le pipeline

`provision` joue `modules.d/NN-*.sh` dans l'ordre des préfixes. Chaque module est un processus
(`<module> check|apply`) qui déclare en tête où il mute (`APPLY-ON`), où son état doit tenir
(`CHECK-ON`), sous quelle identité il se joue (`NEEDS: root | human`) et ce qui le précède
(`AFTER`). Le substrat est mesuré — `docker` dans un conteneur, `wsl` sous un noyau Microsoft,
`linux` sinon — ou forcé par `--substrate`. En apply, un module retenu par `CHECK-ON` mais hors
`APPLY-ON` est joué en check, et son drift est un échec : rien sur place ne peut converger.

Le doctor est le même code que l'apply : chaque module sonde le système, ne garde aucun fichier
d'état, et tout ce qu'il écrit passe par un fichier temporaire du même dossier puis `mv`. Rejouer
est toujours sûr.

| | codes |
|---|---|
| module check | 0 conforme · 1 drift · 2 erreur de sonde · 3 mort avant son verdict |
| module apply | 0 convergé · 1 échec · 2 drift résiduel · 3 mort avant son verdict |
| `provision apply` | 0 convergé · 1 échec · 2 drift résiduel |
| `provision doctor` | 0 conforme · 1 drift · 2 erreur (`--porcelain` : une ligne `MODULE=OK|DRIFT|ERROR` par module) |

Les données viennent de l'environnement ou d'un `--env FICHIER`, avec une seule définition des
défauts dans `lib/provision-lib.sh` : `PROV_PREFIX` (`/opt/lcars/runtime`), `PROV_FLEET_GROUP`
(`fleet`), `PROV_TOKENS_DIR` (`/opt/lcars/var/tokens`), `PROV_FORGE_URL`, `PROV_HUMAN` (l'appelant
par défaut), les ports (`PROV_FORGE_HOST_PORT` 21000, `PROV_DECK_PORT` 20999, `PROV_SSH_PORT`
2222), les épingles de la chaîne de compilation (`PROV_ELIXIR_PIN`, `PROV_ELIXIR_PIN_SHA256`,
`PROV_ELIXIR_OTP_MAJOR`). `/etc/lcars/channel` retient qui a posé le produit, `source` (un
checkout) ou `kit` ; un canal ne se pose pas sur un autre.

## Modules (`modules.d/NN-*.sh`)

| Module | APPLY-ON | CHECK-ON | Pose |
|---|---|---|---|
| 00-preflight | any | any | les planchers (OS, bash, architecture, mémoire, disque, WSL2, espaces de noms utilisateur) et les faits d'entrée ; aucune mutation |
| 10-packages | wsl linux docker | any | tmux, bubblewrap, git, curl, jq, unzip, ca-certificates, python3, socat, et une sandbox bwrap réellement lancée sous l'humain |
| 12-docker-engine | linux | linux | docker-ce depuis le dépôt upstream, posé une fois si aucun daemon ne répond ; ensuite le daemon est constaté, jamais touché. Sous WSL il vient de Docker Desktop |
| 15-toolchain | wsl linux docker | wsl linux docker | Erlang par apt (plancher OTP) et Elixir précompilé épinglé par sha256 sous `/opt` ; de la compilation seulement, jamais dans le conteneur d'exécution |
| 16-node | wsl linux docker | any | Node précompilé épinglé, qui bâtit la documentation du deck |
| 20-groups | any | any | le groupe `fleet` et l'appartenance de l'humain |
| 21-service-accounts | any | any | les comptes système des services, dont `lcars-authority`, qui détient les secrets de forge et n'a aucun privilège noyau ; membre de `fleet` pour traverser `/opt/lcars/runtime` |
| 22-fleet-human | wsl linux | wsl linux | atteste l'humain de fleet du poste : un compte unix qui n'est pas le siège (uid 1000) ; il ne crée rien, la forge sème le compte et le convergeur le matérialise |
| 25-directories | any | any | l'arborescence système : `/opt/lcars` et ses zones, les zones de face sous `/home`, les dossiers de `/run` et leur déclaration tmpfiles ; le substrat de chaque entrée se lit dans `system.manifest` |
| 30-wsl | wsl | wsl | `/etc/wsl.conf` clé par clé (lecteurs Windows fermés, interop coupée, systemd, nom d'hôte), écrit en dernier ; snapd purgé ; gpg-agent masqué |
| 44-media | wsl linux docker | any | les médias partagés (avatars, favicon) et la doc du deck, bâtie depuis les sources ou posée depuis le kit ; modes et propriétaire relus contre `system.manifest` |
| 45-seat-skill | wsl linux | wsl linux | le skill `system-issues` dans le `~/.claude` du siège (l'uid `LCARS_SYSADMIN_UID`), et de lui seul ; le check le compare à sa source |
| 46-tofu | wsl linux docker | any | OpenTofu épinglé (sha256) et son miroir de providers hors-ligne, refait quand un `init` hors-ligne échoue |
| 48-forge-host | wsl linux | wsl linux | la forge du poste (conteneur Gitea) ou la forge fournie : adresses, compte admin, jeton master et seed ; sans elle, 63 et 66 restent en dérive |
| 49-forge-runner | wsl linux | wsl linux | le runner CI de la forge du poste, enrôlé par `docker/forge-runner.sh` quand la forge n'en a aucun ; rien sur une forge fournie, ni sur un compte de runners illisible |
| 50-catalogues | any | any | le matériel des catalogues installés, convergé depuis la forge — un appelant mince de `runtime/services/forge.d/catalogues.sh` |
| 60-deploy | wsl linux docker | any | la release du runtime : bâtie (ou reprise du kit) par `lib/deploy-release.sh` sous l'humain, verrouillée root:fleet 0750, câblée sur `/usr/local/bin` ; les intrus hors `release.manifest` sont retirés ; le canal s'écrit après la pose |
| 61-forge-structure | wsl linux | wsl linux | la structure de la forge (organisations, comptes de rôle, équipes, dépôt modèle) : roster dérivé de la release posée, recette tofu copiée, initialisée hors-ligne et jouée par `forge-gestures.sh apply` avec le tofu épinglé |
| 62-runtime-helpers | wsl linux docker | any | les auxiliaires du runtime sur la machine : services, binaires du PATH, arbres embarqués à plat sous `/opt/lcars`, client de terminal épinglé, réglage de shell (`/etc/skel/.bashrc`, PATH `~/.local/bin` dans `/etc/bash.bashrc`) |
| 63-forge-tokens | wsl linux | wsl linux | les jetons de rôle — un appelant mince de `runtime/services/forge.d/tokens.sh` |
| 64-services | wsl linux | any | l'environnement des daemons, l'uid du siège, les quatre unités systemd (un service debout est relancé quand son unité, l'environnement, ou ce qu'il charge et que 62 a posé, a changé depuis son démarrage) et une passe du convergeur d'humains tant que son daemon ne tourne pas ; en conteneur, le superviseur et ses programmes sont sondés à la place |
| 65-ops-branch | wsl linux | wsl linux | la branche d'outillage sur le dépôt ops — un appelant mince de `runtime/services/forge.d/ops-branch.sh` |
| 66-deck-oidc | wsl linux | wsl linux | le client OAuth2 du deck et `/etc/lcars/deck-oidc.json` — un appelant mince de `runtime/services/forge.d/deck-oidc.sh` |

Dans l'image docker, les mêmes modules jouent `provision apply --substrate docker` depuis le kit
(`docker/Dockerfile`), puis le stage `verify` joue le doctor sur le système de fichiers de l'image
et refuse le build sur un drift. Le conteneur ne joue aucun module au démarrage : son boot est
`runtime/services/container/boot.sh`.

## Les libs (`lib/`)

| fichier | rôle |
|---|---|
| `provision-lib.sh` | le protocole des modules : verdicts (`p_ok`, `p_chg`, `p_drift`, `p_warn`, `p_fail`), poses atomiques (`ensure_dir`, `ensure_mode`, `write_atomic`), verrou, apt, `as_human`, les défauts `PROV_*`, la table de traduction vers les noms `LCARS_*` du produit et `prov_geste`, le lanceur des gestes de `runtime/services/forge.d` (50, 63, 65, 66) |
| `geste-protocol.sh` | le protocole que `prov_geste` donne à un geste : celui du produit, dont les sorties de verdict se marquent |
| `docker-endpoint.sh` | le substrat et le daemon docker : une CLI du PATH, une socket, un verdict qui nomme le geste manquant |
| `deploy-release.sh` | la release du runtime, bâtie ou reprise du kit, basculée sous le préfixe ; liens, modes et élagage par `60-deploy` |
| `kit-verify.sh` | ce qu'un kit doit porter, contre `system.manifest`, `release.manifest` et les listes que 62 pose (`PROV_HELPERS`, `PROV_HELPERS_DATA`, `PROV_SHELL_RC` des constantes) |
| `door-gen.sh` | l'installeur d'une version : le gabarit `install.sh` avec sa base, sa clé et sa table de sommes |
| `forge-publish.sh` | la release sur la forge : brouillon sur le commit, assets, publication ; une release existante est un refus |
| `forge-bootstrap.sh` | l'amorçage d'une forge Gitea : admin, jeton master, graine |
| `enroll-catalogue.sh` | le roster d'un catalogue pour la recette tofu, demandé à l'image, à la release ou aux sources |
| `store.sh` | les natures de volumes de l'instance conteneur et leurs noms |
| `provision-audit.sh` | ce qui est apparu sur la machine entre deux instantanés et que la table ne déclare pas |

## `docker/`

`Dockerfile` (l'image, bâtie depuis le kit par les modules ; stages `runtime`, `verify`, `final`),
`docker-compose.yml` (l'instance livrée), `docker-compose.bench.yml` (le réseau partagé avec la
forge du banc) et `docker-compose.secrets.yml` (les secrets posés par `container config`, montés
sous `/run/secrets`), `forge-compose.yml` et `runner-compose.yml` (la forge jetable et son
runner), leurs surcouches `forge-compose.bench.yml` et `runner-compose.bench.yml` (le marqueur du
banc, empilé par le banc seul), `forge-runner.sh` (l'enrôlement d'un runner, joué par 49 et par le banc),
`lcars-hardened-seccomp.json` (le profil du conteneur), et `bench/` : `bench-up.sh`,
`bench-down.sh --project <nom> --yes`, `bench-swap-image.sh`.

## Publier une version

`deploy/pack.sh --publish` se joue depuis le poste, après le gate local, sur un arbre commité :
le tag est celui de git quand HEAD en porte un, sinon `<AAAA-MM-JJ>-<sha>` (`LCARS_PACK_TAG` le
pose) ; l'installeur généré nomme l'image de la version (`<registre>/<owner>/<repo>:<tag>`) et la
tire avant `container up` quand elle manque au daemon ; la forge, le propriétaire et le dépôt se dérivent d'`origin` (`LCARS_PACK_FORGE`,
`LCARS_PACK_OWNER`, `LCARS_PACK_REPO` sinon) ; le jeton vient de `LCARS_PACK_TOKEN` ou de
`LCARS_PACK_TOKEN_FILE`, portées `write:repository` et `write:package`, jamais en argv. L'image
part d'abord, sur le registre de la forge (`ghcr.io` pour GitHub, `LCARS_PACK_REGISTRY` sinon) :
un tag d'image qui existe est un refus. Puis la release naît en brouillon, reçoit ses assets (kit,
`.sha256`, `install.sh`, `install.sh.sha256`, `.minisig` quand la clé est là), et est publiée d'un
coup. Une release du tag qui existe, brouillon compris, est un refus : pour refaire, la supprimer
sur la forge. L'installeur publié porte en dur la base
`<forge>/<owner>/<repo>/releases/download/<tag>` et les sha256 de ses artefacts. Aucun workflow de
CI ne publie de version ; `.github/workflows/site.yml` publie la plaquette du site sur GitHub
Pages, indépendamment.

## Ce que l'installeur ne fait pas

- **Pas de désinstalleur** : LCARS s'installe sur un terrain qu'on peut détruire — une distribution
  WSL2, un conteneur — et un terrain se refait. `provision audit` mesure une machine contre la
  table, il ne retire rien.
- **Pas de paquet système** : le kit et l'image sont les deux livraisons.
- **Pas de docker posé en mode conteneur** : ce mode installe LCARS dans un conteneur sur une
  machine que l'administrateur définit ; le daemon y est un prérequis nommé. Seul le mode
  `--workstation` sur une machine Linux dédiée (`LCARS_ALLOW_ANY_HOST=1`) pose docker-ce.
- **Pas de forge d'opérateur gérée** : une forge fournie (`FORGE_BASE_URL`) est mesurée par
  `container forge-check` et amenée à son contrat par `container forge-apply` (« Une forge
  fournie », plus bas).
- **Pas d'utilisateur Linux par rôle** : un pod est un processus bwrap sous l'uid de l'humain ;
  les rôles sont des comptes de forge.

## Une forge fournie

La forge porte les dépôts, les issues et les PR, la seule copie durable du travail ; LCARS ne la
fabrique pas. Une instance en conteneur la reçoit par sa conf de projet, posée par
`deploy/container config` (`~/.lcars/container/<projet>.env` et `<projet>.secrets/`) :

- `FORGE_BASE_URL`, son adresse vue du conteneur : `http://host.docker.internal:<port publié>` sous
  Docker Desktop, le nom de service de la forge sur un réseau partagé sous docker natif ;
- `FORGE_PUBLIC_URL`, la même forge vue du navigateur, où reviennent les retours OAuth2 du deck ;
- `FORGE_ADMIN_TOKEN`, un jeton master d'un compte site-admin (Gitea : Settings → Applications,
  scope « all ») ; le conteneur le garde, la structure change pendant toute la vie du système ;
- `FORGE_SEED_PASSWORD`, le mot de passe que les comptes de rôle reçoivent à leur création, et que
  le conteneur relit pour minter leurs jetons.

`deploy/container forge-check` vérifie ce contrat depuis l'hôte, sans docker : les deux adresses
posées, une forge qui répond, un jeton accepté et site-admin, un seed posé ; chaque manque vient
avec son geste. `deploy/container forge-apply` pose ensuite la structure (OpenTofu tourne dans le
conteneur), rejouable.

## Témoins

`deploy/gate.sh [unit | integration | structure]` : le plancher shellcheck, les en-têtes
déclaratifs, puis le corpus de `tests/`, entier ou par couche. Voir `tests/README.md`.
