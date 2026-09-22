# deploy — l'installeur de LCARS-fleet

**Date** : 2026-07-05
**Dernière révision** : 2026-09-14
**Statut** : en service
**Référencé par** : `deploy/tests/README.md`, `deploy/tests/provision.bats` (la table des modules), `deploy/container forge-check` (« Une forge fournie »)

`deploy/` porte l'installation, et rien d'autre : ce qui amène une machine nue — une distribution
WSL2, une machine Linux dédiée, un conteneur — jusqu'à `fleet start`. Le produit vit sous
`runtime/` ; ses auxiliaires système (services, consoles, gestes de forge) vivent dans
`runtime/services/` et sont posés par le module `62-runtime-helpers`.

## Les entrées

| commande | rôle |
|---|---|
| `install.sh` (racine) | l'installeur : il mesure la machine sans privilège (`provision mesure`), montre ce qu'il va faire, marque une pause avant de modifier le système (Entrée pour continuer, Ctrl+C pour annuler) et agit ; avant la pause, seul `~/.lcars/kits/` reçoit le kit d'une release, où vit la mesure. Sans option, LCARS tourne dans un conteneur, sans root ; `--workstation` l'installe dans le système : après la pause, un seul `sudo` relance l'installeur : depuis un clone, sur ce checkout tel quel (ce canal fait confiance au checkout) ; pour un kit, sur une copie que root fait de l'archive dans un dossier à lui, vérifie contre la somme inscrite dans l'installeur, détare et retire à la sortie. En root, la mesure décide seule des refus qui protègent la machine, puis exec `workstation up --faits` sur ses faits ; les choix de l'opérateur passent à `sudo` en options, et aucune ne dispense root de sa mesure. `--bench` monte aussi la forge, son runner CI et un compte de démonstration. En mode conteneur, jq est demandé sur l'hôte (le banc lit l'API de sa forge, `container forge-apply` dérive le roster d'une forge fournie), et une instance déjà posée est refusée avec sa mise à jour. Le reste : `install.sh --help` |
| `deploy/workstation up [--from <kit>] \| doctor` | le délégué du poste, en root : `up` sans root mesure sans privilège, arrête un terrain que le préflight refuse, dit ce que root pose et se relance une fois par `sudo` ; en root, il joue la mesure root (ou reçoit ses faits d'`install.sh` par `--faits`), puis `provision apply` sur ces faits depuis ce checkout ou depuis un kit (un `.tar.gz` se détare sous `~/.lcars/kits/<nom>/`, un kit déjà détaré se prend tel quel : root exécute cet arbre tel quel), puis `accept`. `doctor` sans root se relance par `sudo`, avec le daemon docker qui a répondu à l'opérateur ; en root, il rend les codes de `provision doctor` |
| `deploy/container <verbe>` | le délégué du conteneur : `up`, `pull`, `build`, `status`, `shell`, `logs`, `down`, `reset`, `config`, `forge-check`, `forge-apply`, `runner-token`, `source-push` ; une conf par projet compose sous `~/.lcars/container/`. Codes de sortie et variables : `deploy/container help` |
| `deploy/pack.sh [--publish \| --no-image]` | le lanceur de version : les deux gates, release, doc, kit `.tar.gz`, installeur de la version, image docker. Le kit et son `.sha256` restent dans `<parent du checkout>/lcars-packs/` (`LCARS_PACK_DIR` le déplace) ; le tiroir `dist/<tag>/` les reprend par liens durs, avec le compose de l'instance, son profil seccomp, les constantes de l'installeur et l'installeur de la version ; l'image reste dans le daemon. Prérequis et codes de sortie : `deploy/pack.sh --help` ; `--publish` : « Publier une version », plus bas |
| `deploy/provision apply \| doctor \| mesure \| list \| audit` | le runner des modules, joué par `workstation`, par l'installeur et par la construction de l'image ; `apply` et `doctor` se jouent en root ; `mesure` joue le préflight seul pour un lanceur, sans root ce qui se lit sans privilège, en root les refus qui protègent la machine, et écrit ses faits dans `--faits`. Options et codes de sortie : `deploy/provision --help` |
| `deploy/accept` | l'acceptation d'une installation dans le système : les identifiants annoncés ouvrent la forge, des runners servent les labels que les workflows du modèle de projet demandent, la fleet démarre sous un humain de fleet de la machine (sur un banc, sous l'humain de démonstration) |

## Le pipeline

`provision` joue `modules.d/NN-*.sh` dans l'ordre des préfixes. Chaque module est un processus
(`<module> check|apply`) qui déclare en tête où il mute (`APPLY-ON`), où son état doit tenir
(`CHECK-ON`), `NEEDS: root`, et les modules dont il emploie le travail (`AFTER`, que
`provision list` affiche ; l'ordre est celui des préfixes, et un `AFTER` nomme un préfixe
inférieur). Le substrat se mesure —
`docker` dans un conteneur, `wsl` sous un noyau Microsoft, `linux` sinon — et un `--substrate` qui
contredit la mesure est refusé. Le préflight (`00-preflight`) est la barrière de l'apply : tout
verdict autre que conforme arrête la passe avant le module suivant, et `--only` le joue quand
même ; un apply qui reçoit `--faits`, la mesure root conforme de la même invocation (un fichier 0600
du compte qui joue l'apply), ne le rejoue pas et le compte, rendu par la mesure. Le préflight a deux
phases, que `provision mesure` choisit par l'identité : sans privilège (système, docker, forge,
ports, traces, canal ; un port tenu par un processus invisible y est « tenu », jamais un refus), pour
la grille et les refus précoces ; et root, qui ne reprend rien d'avant `sudo` et décide des refus
qui protègent la machine : déclaration d'un Linux dédié, canal, chaque port de ce projet par
`ss -ltnp` (seuls ses conteneurs et la landing de cette machine le tiennent ; un port écouté sans
processus visible, sous WSL2 celui d'une autre distribution, est refusé avec son remède), projets
compose présents qualifiés par le mode de la forge, écriture et `mv --exchange` sous le parent de la
racine. Les planchers (OS, architecture, mémoire, disque) ne sont pas repris en root. Apply et doctor
jouent les deux phases à la suite. En apply, un module retenu par `CHECK-ON` mais hors `APPLY-ON` est joué en check, et son
drift est un échec : rien sur place ne peut converger.

Le doctor joue le check de chaque module, le même que celui qui encadre son apply. Un module sonde
le système et ne garde aucun fichier d'état : une passe rejouée repart de la mesure. Un fichier se
pose par un temporaire du même dossier puis `mv` (`write_atomic`) ; comptes, groupes, paquets et
services passent par leurs outils système. Les codes de sortie des modules et du runner sont dans
`deploy/provision --help`.

Les faits fixes de l'installeur — racines, fichiers de jetons, comptes et groupes, adresse interne
de la forge, épingles de la chaîne Elixir, listes de ce que 62 pose — sont déclarés une fois dans
`installer-constants.env` : la lib le lit comme une donnée, compose le reçoit par `--env-file`, et
l'environnement ne les surcharge pas. Les choix de l'opérateur (ports, base des projets, humain)
viennent des drapeaux de `provision`, de l'environnement ou d'un `--env FICHIER`. Les ports, la
base et l'humain de démonstration d'un banc ont leurs défauts dans les clés `_DEFAULT` du même
fichier, et la ligne `params` du journal de la machine retient ceux qui s'en écartent ; l'humain de
démonstration retenu ne se retire pas, son compte de forge porte son travail. L'humain servi se redonne à chaque
passe (`--human`, sinon `SUDO_USER`, sinon l'appelant). Le fichier de canal (`PROV_CHANNEL_FILE`) retient qui a posé le
produit, `source` (un checkout) ou `kit` ; un canal ne se pose pas sur un autre. La livraison suit
l'arbre joué : une livraison source est un checkout, qui bâtit la release et la doc sur la machine
et y pose pour cela la chaîne Elixir et Node ; un kit, reconnu à son tampon de révision
(`PROV_SOURCE_STAMP`), porte la release (ERTS embarqué) et la doc déjà bâties.

## Modules (`modules.d/NN-*.sh`)

| Module | APPLY-ON | CHECK-ON | Pose |
|---|---|---|---|
| 00-preflight | any | any | les planchers (famille Debian, architecture, mémoire, disque, WSL2 plutôt que WSL1, docker sous WSL) et les refus qui protègent la machine (`mv --exchange` sous le parent de la racine, déclaration d'un Linux dédié, canal lisible et non mélangé, ports de ce projet tenus par lui seul, projets compose d'un autre déploiement), et les faits d'entrée de l'installeur, en deux phases (sans privilège, root) ; aucune mutation |
| 10-packages | wsl linux docker | any | les paquets apt du runtime et des pods (la liste `PACKAGES` du module), et une sandbox bwrap réellement lancée sous l'humain ; au build de l'image, cette sonde se reporte au boot |
| 12-docker-engine | linux | linux | docker-ce depuis le dépôt upstream, posé si aucun moteur n'est là ; un daemon qui répond est conforme, un moteur posé et arrêté (docker-ce ou docker.io) ou un daemon qui refuse l'utilisateur se disent sans que rien ne soit reposé. Sous WSL, le daemon vient de Docker Desktop |
| 15-toolchain | wsl linux docker | wsl linux docker | Erlang par apt, à la majeure OTP du zip d'Elixir, et Elixir précompilé épinglé (version et sha256) sous `/opt`, avec le retrait des arbres d'une autre version que ce module a marqués ; sur une livraison source seulement, un kit embarque son ERTS |
| 16-node | wsl linux docker | any | Node précompilé épinglé, qui bâtit la documentation du deck, sur une livraison source seulement |
| 20-groups | any | any | les groupes `fleet` et `lcars-console`, au gid que `system.manifest` déclare, et le siège dans `fleet` ; un autre humain y entre par le convergeur, seul juge de l'appartenance |
| 21-service-accounts | any | any | les deux comptes de service, chacun sur son groupe éponyme et sans shell : `lcars-authority` détient les secrets de forge et entre dans `fleet` pour traverser le préfixe du runtime, `lcars-system` détient le secret OAuth2 du deck ; un compte existant qui s'en écarte est refusé et nommé, jamais corrigé |
| 25-directories | any | any | l'arborescence système : la racine de LCARS et ses zones, les zones de face sous `/home`, les dossiers de `/run` et leur déclaration tmpfiles ; mode, propriétaire et substrat de chaque entrée se lisent dans `system.manifest` |
| 30-wsl | wsl | wsl | `/etc/wsl.conf` clé par clé (lecteurs Windows fermés, interop coupée, systemd, nom d'hôte pris de la base du projet et refusé s'il n'est pas une étiquette DNS), écrit en dernier ; snapd purgé ; gpg-agent masqué ; `credsStore` retiré de `~/.docker/config.json` ; docker.io posé à côté de Docker Desktop est un échec qui nomme le geste |
| 44-media | wsl linux docker | any | les médias partagés (avatars, favicon) et la doc du deck, bâtie depuis les sources ou posée depuis le kit ; modes et propriétaire relus contre `system.manifest` |
| 45-seat-skill | wsl linux | wsl linux | le skill `system-issues` dans le `~/.claude` du siège (l'uid `LCARS_SYSADMIN_UID`), et de lui seul ; le check le compare à sa source |
| 46-tofu | wsl linux docker | any | OpenTofu épinglé (sha256) et son miroir de providers hors-ligne, refait quand un `init` hors-ligne échoue |
| 48-forge-host | wsl linux | wsl linux | la forge du poste (conteneur Gitea, son compte d'administration et son jeton master) ou la forge fournie par `FORGE_BASE_URL` (jeton master écrit par l'opérateur) : adresses, forme, promotion de l'administrateur, seed, enregistrement du siège |
| 49-forge-runner | wsl linux | wsl linux | le runner CI de la forge du poste, enrôlé par `docker/forge-runner.sh` quand la forge n'en a aucun ; rien sur une forge fournie, ni sur un compte de runners illisible |
| 50-catalogues | any | any | le matériel des catalogues installés, convergé depuis la forge — un appelant mince de `runtime/services/forge.d/catalogues.sh` |
| 60-deploy | wsl linux docker | any | la release du runtime : bâtie (ou reprise du kit) par `lib/deploy-release.sh` sous l'humain, verrouillée root:fleet, câblée sur le dossier des liens du PATH ; les intrus hors `release.manifest` sont retirés ; le canal s'écrit après la pose. Sur une livraison source, l'outillage mix et les dépendances se tirent de hex.pm sous l'humain |
| 61-forge-structure | wsl linux | wsl linux | la structure de la forge (organisations, comptes de rôle, équipes, dépôt modèle, catalogue de démonstration déposé) : roster dérivé de la release posée, recette tofu copiée, initialisée hors-ligne et jouée par `forge-gestures.sh apply` avec le tofu épinglé |
| 62-runtime-helpers | wsl linux docker | any | les auxiliaires du runtime sur la machine : services, binaires du PATH, arbres embarqués à plat sous la racine de LCARS, client de terminal épinglé, réglage de shell (`/etc/skel/.bashrc`, PATH `~/.local/bin` dans `/etc/bash.bashrc`) |
| 63-forge-tokens | wsl linux | wsl linux | les jetons de rôle — un appelant mince de `runtime/services/forge.d/tokens.sh` |
| 64-services | wsl linux | any | l'environnement des daemons, l'uid du siège, les quatre unités systemd (un service debout est relancé quand son unité, l'environnement, ou ce qu'il charge et que 62 a posé, a changé depuis son démarrage) et une passe du convergeur d'humains tant que son daemon ne tourne pas ; en conteneur, le superviseur et ses programmes sont sondés à la place |
| 65-ops-repo | wsl linux | wsl linux | le dépôt du système (`lcars/_ops` : branches `tool_request` et `incidents`, protection) — un appelant mince de `runtime/services/forge.d/ops-repo.sh`, qui VÉRIFIE ce que la recette de 61 a posé |
| 66-deck-oidc | wsl linux | wsl linux | le client OAuth2 du deck et son fichier sous `/etc/lcars` — un appelant mince de `runtime/services/forge.d/deck-oidc.sh` |
| 67-system-project | wsl linux | wsl linux | LCARS publié comme projet de la fleet qu'il installe : l'arbre dont cette machine a été installée devient `<catalogue>/lcars-fleet` sur sa propre forge, avec ses trois faces. Appelle la porte du release (`lcars project adopt-system`), sous le siège — l'adoption est du runtime, et les faces appartiennent au groupe `fleet` |

Dans l'image docker, les mêmes modules jouent `provision apply --substrate docker` depuis le kit
(`docker/Dockerfile`), puis le stage `verify` joue le doctor sur le système de fichiers de l'image
et refuse le build sur un drift. Le conteneur ne joue aucun module au démarrage : son boot est
`runtime/services/container/boot.sh`.

## Les libs (`lib/`)

| fichier | rôle |
|---|---|
| `provision-lib.sh` | le protocole des modules : les constantes de `installer-constants.env` et les choix de l'opérateur, verdicts (`p_ok`, `p_chg`, `p_drift`, `p_warn`, `p_fail`), poses atomiques (`ensure_dir`, `ensure_mode`, `write_atomic`), lecture de `system.manifest`, verrou, apt, `as_human`, `forge_api` (le client de forge : jeton lu dans un fichier et passé sur stdin), la table de traduction vers les noms `LCARS_*` du produit et `prov_geste`, le lanceur des gestes de `runtime/services/forge.d` (50, 63, 65, 66) |
| `docker-endpoint.sh` | le substrat et le daemon docker : une CLI, le `DOCKER_HOST` de l'environnement s'il répond, sinon la socket système et l'adresse écartée rendue pour être dite, un verdict qui nomme le geste manquant |
| `deploy-release.sh` | la release du runtime, bâtie ou reprise du kit, basculée sous le préfixe ; liens, modes et élagage par `60-deploy` |
| `kit-verify.sh` | ce qu'un kit doit porter : tampon de révision, release, doc bâtie, entrées de `release.manifest`, listes que 62 pose (`PROV_HELPERS`, `PROV_HELPERS_DATA`, `PROV_SHELL_RC` des constantes), médias |
| `door-gen.sh` | l'installeur d'une version : le gabarit `install.sh` avec sa version, sa base, sa clé, son image et sa table de sommes, et son `install.sh.sha256` |
| `forge-publish.sh` | la release sur la forge : refus d'une release existante, brouillon sur le commit, assets, publication |
| `forge-bootstrap.sh` | l'amorçage d'une forge Gitea : montage, compte d'administration, jeton master, graine, humain de démonstration du banc |
| `bench.sh` | la lib des scripts de banc : options et projets dérivés de la base, marqueur `lcars.bench`, montage du conteneur, attente, relance, credentials, jetons |
| `enroll-catalogue.sh` | le roster d'un catalogue pour la recette tofu, demandé à l'image, à la release ou aux sources |
| `store.sh` | les natures de volumes du magasin d'une instance et leurs noms |
| `provision-audit.sh` | ce qui est apparu sur la machine entre deux instantanés et que la table ne déclare pas |

⚠ **`provision-lib.sh` porte dix-neuf fonctions qui existent aussi dans le protocole du produit**
(`runtime/services/lib/module-protocol.sh`), et ce n'est pas un accident de nommage : les unes sont
le dialecte du rail (tag, compteurs, couleur, piège de sortie), les autres sont une dette. La note
qui les sépare vit dans `runtime/services/README.md` ; leur composition fait foi dans
`tests/transverse/homonymes.bats`, et un homonyme de plus y est un échec nommé.

## `docker/`

`Dockerfile` (l'image, bâtie depuis le kit par les modules ; stages `runtime`, `verify`, `final`),
`docker-compose.yml` (l'instance livrée), `docker-compose.bench.yml` (le réseau et l'adresse de la
forge du banc, la source du conteneur, le marqueur du banc) et `docker-compose.secrets.yml` (les
secrets posés par `container config`, montés sous `/run/secrets`), `forge-compose.yml` et
`runner-compose.yml` (la forge jetable et son runner), `runner-network.yml` (le runner sur le réseau
de sa forge, empilé par `forge-runner.sh`), les surcouches `forge-compose.bench.yml` et
`runner-compose.bench.yml` (le marqueur du banc, empilé par le banc seul), `forge-runner.sh`
(l'enrôlement d'un runner, joué par 49 et par le banc), `lcars-hardened-seccomp.json` (le profil du
conteneur), et `bench/` : `bench-up.sh`, `bench-down.sh --project <nom> --yes`,
`bench-swap-image.sh`.

## Publier une version

`deploy/pack.sh --publish` se joue depuis le poste, hors root, sur un arbre commité ; il joue
lui-même les deux gates avant d'empaqueter. Le tag est celui de git quand HEAD en porte un, sinon
`<AAAA-MM-JJ>-<sha>` (`LCARS_PACK_TAG` le pose). La forge, le propriétaire et le dépôt se lisent dans
`LCARS_PACK_FORGE`, `LCARS_PACK_OWNER` et `LCARS_PACK_REPO`, et à défaut se dérivent d'un `origin` en
http(s) ; une forge de publication est en https. Le jeton se lit dans le fichier
`LCARS_PACK_TOKEN_FILE`, portées `write:repository` et `write:package`, jamais en argv ni dans
l'environnement, dont héritent le gate et npm.
L'installeur généré nomme l'image de la version (`<registre>/<owner>/<repo>:<tag>`) et la tire avant
`container up` quand elle manque au daemon ; le registre est `LCARS_PACK_REGISTRY`, par défaut
`ghcr.io` pour une forge GitHub et l'hôte de la forge sinon. `LCARS_MINISIGN_PUBKEY` et
`LCARS_MINISIGN_SECKEY` (le fichier de la clé secrète) vont ensemble : le kit est signé par minisign
dans le tiroir, et l'installeur porte la clé publique qui vérifie cette signature.

Avant tout envoi, dans cet ordre, sont des refus : une forge ou un propriétaire indéterminables,
aucun jeton, une release du tag qui existe (brouillon compris ; pour refaire, la supprimer sur la
forge) ou un jeton qui ne lit pas le dépôt, un commit que la forge ne porte pas (il se pousse
d'abord), un registre qui refuse le jeton. Vient l'image. Un tag d'image qui existe déjà au
registre n'est jamais repoussé : à la révision du kit (le label `org.opencontainers.image.revision`
de l'image), c'est l'image d'une publication arrêtée après son envoi, et elle est reprise ; à une
autre révision, c'est un refus. Sinon l'image part. Elle se relit alors par un tirage sans
identifiants, celui de l'installeur : une image que ce tirage ne voit pas arrête la publication
avant la release. Sur GHCR, un paquet naît privé à sa première publication : dans les réglages du
paquet (Package settings), « Change visibility » le passe public et « Connect repository » le relie
au dépôt ; `deploy/pack.sh --publish` relancé reprend ensuite l'image poussée. La release naît en
brouillon sur le commit, reçoit tout le tiroir
(le kit, son `.sha256` et sa `.minisig` quand le kit est signé, `docker-compose.yml`,
`lcars-hardened-seccomp.json`, `installer-constants.env`, `install.sh` et `install.sh.sha256`), et
est publiée d'un coup. L'installeur publié porte en dur la base
`<forge>/<owner>/<repo>/releases/download/<tag>` et les sha256 de ses artefacts, qui vérifient le
kit. Aucun workflow de CI ne publie de version ; `.github/workflows/site.yml` publie la plaquette du
site sur GitHub Pages, indépendamment.

## Le périmètre

- **Un terrain se refait** : LCARS s'installe sur un terrain qu'on peut détruire — une distribution
  WSL2, un conteneur, une machine dédiée — et aucun désinstalleur ne l'accompagne. `provision audit`
  mesure une machine contre la table, sans rien retirer.
- **Deux livraisons** : le kit et l'image ; aucun paquet système.
- **Docker est un prérequis du mode conteneur** : ce mode installe LCARS dans un conteneur sur une
  machine que l'administrateur définit, et nomme le daemon manquant. docker-ce se pose seulement par
  `--workstation` sur une machine Linux dédiée (`LCARS_ALLOW_ANY_HOST=1`), quand aucun moteur n'y
  est posé.
- **Une forge fournie reste à son opérateur** : `container forge-check` la mesure et
  `container forge-apply` l'amène à son contrat (« Une forge fournie », plus bas).
- **Un rôle est un compte de forge** : un pod est un processus bwrap sous l'uid de l'humain.

## Une forge fournie

La forge porte les dépôts, les issues et les PR, la seule copie durable du travail ; LCARS la reçoit
d'un opérateur. Une instance en conteneur la reçoit par sa conf de projet, posée par
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
avec son geste, et la sortie est 0 quand le contrat tient, 1 sinon. `deploy/container forge-apply`
pose ensuite la structure (OpenTofu tourne dans le conteneur), rejouable.

Une installation dans le système reçoit `FORGE_BASE_URL` et `FORGE_PUBLIC_URL` de l'environnement
ou d'un `--env FICHIER` ; `install.sh` et `workstation` les passent à `sudo` en options (`--forge`,
`--forge-publique`), qui ne transmet aucune variable. `48-forge-host` y génère le seed ; le jeton master s'écrit à la main dans
le fichier que son drift nomme (`PROV_MASTER_TOKEN_FILE`, 0600, au compte d'autorité), puis la passe
se relance et `61-forge-structure` pose la structure.

## Témoins

`deploy/gate.sh [unit | integration | structure]` : le plancher shellcheck, les en-têtes
déclaratifs, puis le corpus de `tests/`, entier ou par couche. Un témoin pose ses chemins système
sous une racine de décor (`LCARS_DECOR_ROOT`) et double la forge par `tests/support/`. Voir
`tests/README.md`.
