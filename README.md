<!-- Date: 2026-08-18 · Dernière révision: 2026-09-14 · Statut: README de la beta, français puis anglais dans ce seul fichier · Référencé par: la page d'accueil du dépôt, le kit -->

# LCARS-fleet — beta

**Firmware-as-a-Service.** Une flotte d'agents qui tourne sur une machine : une forge git, un runner
CI, des agents tenus par leur rôle et un tableau de bord, montés par une commande, en conteneur
ou dans le système.

[Français](#français) · [English](#english)

---

## Français

> **C'est une beta, faite pour être essayée.** Avec `--bench`, elle monte une pile jetable : sa
> forge, son runner, ses comptes. Elle sert à l'essai, et une forge existante ne reçoit la
> structure de LCARS que lorsqu'on la branche.

### Prérequis

| Composant | Rôle |
|---|---|
| Docker, avec le plugin compose | exécute le conteneur LCARS, la forge et le runner CI. Sous Windows : Docker Desktop avec l'intégration WSL 2 activée pour la distribution ; un `docker.io` posé dans la distribution à côté de Docker Desktop est refusé. Sous Ubuntu natif : `docker.io` et `docker-compose-v2`, ou Docker Engine ; en mode conteneur le daemon est un prérequis, en mode `--workstation` sur une machine dédiée l'installeur le pose |
| git, curl | le clone, le téléchargement du kit, les échanges avec la forge |
| jq | mode conteneur : le banc (`--bench`) lit l'API de sa forge, et `deploy/container forge-apply` dérive le roster d'une forge fournie ; en mode `--workstation`, l'installation le pose |
| sudo | mode `--workstation` seulement : root une fois, après la pause, pour mesurer ce que root seul lit et provisionner le système ; sans terminal, un `sudo` sans mot de passe |
| WSL 2 | sous Windows ; WSL 1 ne fournit pas les espaces de noms nécessaires |
| Compte Anthropic | les agents sont des processus Claude Code ; les identifiants de `~/.claude/.credentials.json` sont réutilisés quand ils existent |

Les versions publiées sont pré-compilées : un kit et une image. Aucune chaîne Elixir/Erlang n'est
requise pour les installer.

### Installation

La dernière version publiée s'installe en une commande. En conteneur :

```bash
curl -fsSL https://github.com/zurp-embedded/LCARS-fleet/releases/latest/download/install.sh | bash -s -- --bench
```

Dans ce système (une distribution WSL 2, ou une machine Linux dédiée déclarée par
`LCARS_ALLOW_ANY_HOST=1`) :

```bash
curl -fsSL https://github.com/zurp-embedded/LCARS-fleet/releases/latest/download/install.sh | bash -s -- --workstation --bench
```

Sur une machine Linux dédiée, la déclaration se donne à `bash`, après le `|`, à chaque passe :

```bash
curl -fsSL https://github.com/zurp-embedded/LCARS-fleet/releases/latest/download/install.sh | LCARS_ALLOW_ANY_HOST=1 bash -s -- --workstation --bench
```

`install.sh` mesure la machine sans privilège, affiche ce qui sera installé, marque une pause
avant de modifier le système (Entrée pour continuer, Ctrl+C pour annuler), puis agit. Avant cette
pause, seul `~/.lcars/kits/` reçoit le kit de la version. Sans terminal, il continue en le disant.
En conteneur, rien ne demande root. En mode `--workstation`, la grille nomme ce que root pose (/etc,
la racine de LCARS, les comptes, les groupes, les paquets) ; après la pause, l'installeur se relance
une fois par `sudo`. Depuis un clone, root exécute ce checkout tel quel : ce canal fait confiance au
checkout. Pipé, root copie l'archive du kit dans un dossier à lui, la vérifie contre la somme inscrite
dans l'installeur, la détare et joue cette copie ; l'arbre posé sous `~/.lcars/kits/` n'est jamais
exécuté par root. Root décide lui-même de ce qui protège la machine (déclaration d'un Linux dédié,
canal, chaque port de ce projet, projets compose présents, écriture sous la racine), puis
provisionne. Les choix de l'opérateur passent à `sudo` en options, jamais en variables. Sans `sudo`, ou sans terminal quand
`sudo` demande un mot de passe, il s'arrête avant la grille. Relancer reprend depuis la mesure :
l'état est celui du système, lu à chaque passage.

| Option | Effet |
|---|---|
| *(sans option)* | LCARS tourne dans un conteneur Docker ; rien n'est installé hors de Docker |
| `--workstation` | LCARS s'installe dans le système |
| `--bench` | l'installeur monte lui-même la forge Gitea, son runner CI et un compte de démonstration. Sans cette option, une forge existante est requise (`FORGE_BASE_URL`) |
| `--check` | mesure et affiche, ne modifie rien ; avec `--workstation`, la mesure se complète en root, par `sudo` |
| `--dry-run` | tout jusqu'à la commande qui serait exécutée ; avec `--workstation`, par `sudo`, pour mesurer entier |
| `--port-forge N` `--port-deck N` `--port-ssh N` | ports publiés ; le bilan affiche chaque port retenu, défaut compris. `--port-forge` va avec `--bench`, `--port-ssh` avec le mode conteneur |
| `--forge-project N` | la base des projets compose (défaut `lcars`) |

La mesure vit dans le kit : pipés sans kit déjà posé, `--check` et `--dry-run` s'arrêtent avant de
télécharger, sans rien mesurer, et disent la commande qui serait jouée. `install.sh --help` liste le
reste.

Pipé, l'installeur pose l'arbre de la version sous `~/.lcars/kits/<version>/lcars_install` : les
commandes `deploy/…` de ce document se jouent depuis ce dossier.

Chaque release publie son propre `install.sh`, lié aux artefacts de cette version : une version
précise se prend par `releases/download/<version>/install.sh`, et `install.sh.sha256`, publié à
côté, permet de vérifier l'installeur avant de le jouer. Le kit est téléchargé dans
`~/.lcars/kits/<version>/` et vérifié contre les sommes sha256 inscrites dans l'installeur ; un
écart supprime le fichier et interrompt l'installation. Une version publiée avec une clé minisign
porte la clé publique dans son installeur et la signature `.minisig` de chaque kit : quand
`minisign` est installé, une signature absente ou invalide interrompt l'installation ; sans
`minisign`, ou sans clé dans l'installeur, il signale que la provenance repose sur les sommes
sha256. En mode conteneur, l'image de la version est tirée de son registre sans identifiants
(`ghcr.io` pour une release GitHub) quand elle n'est pas déjà sur le daemon ; la publication d'une
version vérifie ce tirage (`deploy/README.md`, « Publier une version »).

#### Fin d'installation

Avec `--bench`, l'installation crée la forge, provisionne comptes et équipes, génère les jetons,
démarre le conteneur ou les services et enregistre le runner CI. En mode conteneur, elle se termine
sur le verdict du banc et ses points d'entrée (extrait) :

```
[bench-up] banc PRÊT
[bench-up]   forge     : http://192.168.1.42:21000   (admiral / toto123456 · lcars / toto32toto32)
[bench-up]   deck      : http://192.168.1.42:20999
[bench-up]   conteneur : lcars-fleet-lcars-1   ssh lcars@192.168.1.42 -p 2222
[bench-up]   runner    : enregistré — labels : shell:…,dood:…,ubuntu-latest:…
[bench-up]   fleet     : démarrée sous lcars
[bench-up]   détruire  : bench-down.sh --project lcars --yes
```

Tout autre verdict que `banc PRÊT` nomme l'élément manquant. En mode `--workstation`, elle se
termine sur l'acceptation : les identifiants annoncés ouvrent la forge, un runner sert les labels
que les workflows d'un projet demandent, et la fleet démarre sous un humain de fleet de la machine ;
les identifiants s'affichent ensuite.

#### Pour développer

Depuis un clone, l'installeur installe depuis ce clone (canal `source`). En mode `--workstation`,
il pose la chaîne Elixir/OTP et Node aux versions épinglées par le provisionnement et compile le
runtime ; les dépendances se tirent de hex.pm, que la machine joint directement (`sudo` ne transmet
aucune variable de proxy). En mode conteneur, l'image doit être sur le daemon avant `install.sh`.
`deploy/container build` la bâtit sur le poste, depuis un arbre commité : il joue `deploy/pack.sh`,
qui demande la chaîne Elixir/OTP, node, bats, shellcheck et docker buildx, et joue le gate complet. Une image
publiée se tire, et `install.sh` la reçoit par la même variable, dans le même shell :

```bash
export LCARS_IMAGE=<registre/image:tag>
deploy/container pull
bash install.sh --bench
```

`--from-release`, depuis un clone, rejoue l'installeur de la dernière release publiée du dépôt,
vérifié contre sa somme.

```bash
git clone --branch <version> https://github.com/zurp-embedded/LCARS-fleet.git lcars-fleet
cd lcars-fleet
bash install.sh --workstation --bench
```

Un kit (`lcars-fleet-<version>-otp<N>-<arch>.tar.gz`, produit par `deploy/pack.sh`) s'installe
dans le système par `deploy/workstation up --from <kit.tar.gz>` (canal `kit`).
La machine enregistre le canal utilisé ; les mises à jour se font par le même canal, et
l'installation d'un canal par-dessus un autre est refusée en nommant le geste.

### Entrer

Avec `--bench`, deux comptes existent, et ils ne sont pas interchangeables.

| compte | mot de passe | ce que c'est |
|---|---|---|
| `lcars` | `toto32toto32` | l'humain de la flotte : le compte d'usage. Il possède les projets, parle aux agents, a une console sur le tableau de bord |
| `admiral` | `toto123456` | l'administrateur système : il possède le conteneur (sudo) et a fondé la forge. Démarrer une flotte sous lui est refusé par construction |

Dans le système (`--workstation --bench`), l'administrateur de la forge est le compte qui a lancé
l'installation, avec le même mot de passe. Ces mots de passe sont des défauts de test.

Ce qui écoute sur `0.0.0.0` est joignable du réseau local : une autre personne peut ouvrir le
tableau de bord depuis son poste. En conteneur, `--bench` publie la forge, le tableau de bord et ssh
sur `0.0.0.0` ; sans `--bench`, le conteneur publie le tableau de bord et ssh sur `127.0.0.1`. Dans
le système, le tableau de bord écoute sur `0.0.0.0` dans les deux cas, et la forge montée par
`--bench` aussi. Réseau de confiance seulement.

Les ports sont ceux que le bilan de l'installeur a affichés.

**Le tableau de bord** — `http://<adresse>:<port du deck>`. L'entrée principale ; on s'y connecte
par la forge (le bouton est sur la page d'accueil). Il porte un terminal web par humain, l'état de
la flotte et la liste des agents qui tournent.

**La forge** — `http://<adresse>:<port de la forge>`. Un Gitea complet : les projets, leurs pull
requests, leurs runs de CI. Connexion en `lcars`.

**SSH** — `ssh lcars@<adresse> -p <port ssh>`. Le même conteneur, dans un terminal :

```bash
fleet start           # démarrer la flotte
fleet status          # ce qu'elle fait
lcars catalogue list  # les catalogues métier que cette installation porte
```

#### Le catalogue de démonstration

À l'installation, un catalogue est là, `fleet`. Un second, `web-demo`, attend sur la forge sous
forme de dépôt ; `lcars catalogue list` l'affiche en `disponible`, et `lcars catalogue install
web-demo` crée son organisation sur la forge, ses comptes de rôle, ses équipes, et pose son
matériel sur la machine. C'est un geste d'administration de la forge ; sur ce banc, `lcars` en est
administrateur. Une fois installé, ses cartes apparaissent à côté de celles de `fleet` quand un
agent propose le catalogue d'un nouveau projet ; le catalogue d'un projet est fixé à sa création.

Dans cette version, `lcars catalogue install` échoue : la résolution du dépôt du catalogue lit une
ligne de journal au lieu de sa réponse. Le défaut est connu ; `fleet`, livré avec l'installation,
n'est pas concerné.

### Un premier projet

Tout passe par une conversation avec un agent ; il n'y a pas de formulaire.

1. Ouvrir le tableau de bord et démarrer la console.
2. Lancer `fleet start`, puis `claude` : c'est le guichet de la flotte.
3. Lui demander un projet. Il montre les cartes que portent les catalogues installés (une carte est
   un workflow : qui écrit, qui relit, si la CI doit être verte avant de fusionner), laisse en
   choisir une, et crée le dépôt, les branches et les dossiers de travail.
4. Ouvrir un ticket sur ce projet. La flotte le prend, lance les agents que la carte nomme, et le
   travail arrive en pull request, jugée par les relecteurs que cette carte déclare.

Avec `--bench`, le runner est enregistré : la CI d'un projet tourne. Sur une forge existante, la CI
tourne sur les runners que son opérateur y a enregistrés.

### Mettre à jour

En conteneur, une instance déjà posée n'est pas réinstallée : `install.sh` la refuse et nomme sa mise
à jour. Le conteneur est recréé sur l'image de la nouvelle version ; ses volumes et son magasin
restent. Le geste se joue depuis l'arbre qui a installé l'instance, dont le compose l'a créée :

```bash
LCARS_IMAGE=<image de la version> deploy/container pull
LCARS_IMAGE=<image de la version> deploy/container -p <base>-fleet up
```

Un banc (`--bench`) garde sa forge et ses jetons ; seule l'image de son conteneur change :
`deploy/docker/bench/bench-swap-image.sh --image <image de la version> --forge-project <base>`.

Dans le système, l'installeur de la nouvelle version se relance par le même canal : il reprend depuis
la mesure et repose ce qui a changé.

### Retirer

Le terrain se détruit et se refait ; aucun désinstalleur ne l'accompagne.

Mode conteneur, depuis l'arbre de l'installation. Le magasin d'une instance, ce sont ses volumes
`<base>-fleet-*` (caches, chaînes d'outils, sysroots, état convergé) : ce qui coûte du temps à
refaire, gardé hors du projet compose.

```bash
deploy/docker/bench/bench-down.sh --project <base> --yes   # avec --bench : le conteneur, la forge, le runner et le magasin, volumes compris
deploy/container -p <base>-fleet reset                     # après confirmation, le conteneur et ses volumes ; la forge et le magasin restent
```

Mode `--workstation` : la distribution WSL 2 se supprime (`wsl --unregister <distribution>` côté
Windows), la machine dédiée se réinstalle. Sous WSL, la forge et le runner montés par `--bench`
vivent dans Docker Desktop et survivent à la distribution ; ils se retirent avant elle :

```bash
docker compose -p <base>-forge down -v
docker compose -p <base>-runner down -v
```

`~/.lcars` porte les kits téléchargés et les états par humain.

### Les limites de cette beta

- La forge créée est jetable et vit sur le réseau local : c'est un banc d'essai. Une forge
  existante se branche par `FORGE_BASE_URL` ; ce qu'elle doit fournir (ses adresses, un jeton
  master site-admin, le mot de passe des comptes de rôle) et les gestes qui la posent, la vérifient
  et la structurent (`deploy/container config`, `forge-check`, `forge-apply`) sont dans
  `deploy/README.md`, « Une forge fournie ».
- Les mots de passe ci-dessus sont des défauts fixes.
- Projets, dépôts et conteneurs restent tant que l'opérateur ne les supprime pas.
- Les agents coûtent des tokens : ce sont des processus Claude Code sur le compte configuré, et une
  flotte laissée tourner continue de travailler.
- Exercé sur Ubuntu (WSL 2 et natif) avec Docker ; le préflight demande une distribution de la
  famille Debian.

### Si quelque chose va de travers

```bash
deploy/container -p <base>-fleet status   # l'état de l'instance vu de l'hôte : 0 sain · 1 dégradé · 2 panne
deploy/container -p <base>-fleet logs     # le récit que le conteneur fait de son propre démarrage
deploy/workstation doctor                 # mode --workstation : ce qui est posé, ce qui a dérivé ; la sonde demande sudo, une fois
```

Ces commandes se jouent depuis l'arbre de l'installation (un clone, ou
`~/.lcars/kits/<version>/lcars_install` après un `curl | bash`). `-p` vise le projet compose du
conteneur, `<base>-fleet` (`lcars-fleet` par défaut ; `--forge-project` change la base). La ligne
`détruire` de l'écran final porte la base. Une PR
bloquée par sa CI se répare depuis la PR : le runner joue le `ci.yml` du commit testé, corriger ce
fichier et repousser débloque la PR elle-même.

### Ce qu'il y a dedans

- **Un conteneur, ou un système** — Ubuntu 26.04, qui fait tourner le runtime de la flotte
  (Elixir/OTP) et un tableau de bord web.
- **Une forge** — Gitea, dans son propre conteneur, avec les organisations, équipes et comptes
  machine dont la flotte a besoin.
- **Un runner** — Gitea Actions, enregistré, pour que la CI soit réelle.
- **Des catalogues** — les définitions métier : quels rôles existent, quelles cartes de workflow
  ils servent, quel est le system prompt de chaque agent. Un catalogue est de la donnée, pas du
  code. `fleet` est livré dans le runtime ; `web-demo` est déposé sur la forge, et son installation
  échoue dans cette version (« Le catalogue de démonstration »).
- **Des agents** — des processus Claude Code, chacun dans un bac à sable qui monte exactement ce
  dont son rôle a besoin.

### Licence

Voir [`LICENSE`](LICENSE) et [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

---

## English

> **This is a beta, meant to be tried.** With `--bench`, it brings up a disposable stack: its
> forge, its runner, its accounts. It is meant for trying out, and an existing forge receives the
> LCARS structure only once it is plugged in.

### Requirements

| Component | Role |
|---|---|
| Docker, with the compose plugin | runs the LCARS container, the forge and the CI runner. On Windows: Docker Desktop with WSL 2 integration enabled for the distribution; a `docker.io` installed in the distribution next to Docker Desktop is refused. On native Ubuntu: `docker.io` and `docker-compose-v2`, or Docker Engine; in container mode the daemon is a prerequisite, in `--workstation` mode on a dedicated machine the installer installs it |
| git, curl | the clone, the kit download, the exchanges with the forge |
| jq | container mode: the bench (`--bench`) reads its forge's API, and `deploy/container forge-apply` derives the roster of a provided forge; in `--workstation` mode, the install puts it in place |
| sudo | `--workstation` mode only: root once, after the pause, to measure what only root reads and provision the system; without a terminal, a passwordless `sudo` |
| WSL 2 | on Windows; WSL 1 does not provide the namespaces needed |
| Anthropic account | agents are Claude Code processes; the credentials in `~/.claude/.credentials.json` are reused when present |

Published versions are pre-built: a kit and an image. No Elixir/Erlang toolchain is needed to
install them.

### Install

The latest published version installs with one command. In a container:

```bash
curl -fsSL https://github.com/zurp-embedded/LCARS-fleet/releases/latest/download/install.sh | bash -s -- --bench
```

Into this system (a WSL 2 distribution, or a dedicated Linux machine declared with
`LCARS_ALLOW_ANY_HOST=1`):

```bash
curl -fsSL https://github.com/zurp-embedded/LCARS-fleet/releases/latest/download/install.sh | bash -s -- --workstation --bench
```

On a dedicated Linux machine, the declaration goes to `bash`, after the `|`, on every run:

```bash
curl -fsSL https://github.com/zurp-embedded/LCARS-fleet/releases/latest/download/install.sh | LCARS_ALLOW_ANY_HOST=1 bash -s -- --workstation --bench
```

`install.sh` measures the machine without privilege, shows what will be installed, pauses before
changing the system (Enter to continue, Ctrl+C to cancel), then acts. Before that pause, only
`~/.lcars/kits/` receives the version's kit. Without a terminal it goes on and says so. In a
container, nothing asks for root. In `--workstation` mode, the grid names what root puts in place
(/etc, the LCARS root, accounts, groups, packages); after the pause, the installer relaunches
itself once through `sudo`. From a clone, root runs that checkout as it is: this channel trusts the
checkout. Piped, root copies the kit archive into a directory of its own, checks it against the sum
written into the installer, unpacks it and runs that copy; the tree under `~/.lcars/kits/` is never
run by root. Root decides by itself what protects the machine (the dedicated-Linux declaration, the
channel, each of this project's ports, the compose projects present, writing under the root), then
provisions. The operator's choices reach `sudo` as options, never as variables. Without `sudo`, or
without a terminal when `sudo` asks for a password, it stops before the grid. Re-running starts
again from the measurement: the state is the system's, read on every run.

| Option | Effect |
|---|---|
| *(no option)* | LCARS runs in a Docker container; nothing is installed outside Docker |
| `--workstation` | LCARS is installed into the system |
| `--bench` | the installer brings up the Gitea forge, its CI runner and a demo account itself. Without it, an existing forge is required (`FORGE_BASE_URL`) |
| `--check` | measures and reports, changes nothing; with `--workstation`, the measurement completes as root, through `sudo` |
| `--dry-run` | everything up to the command that would run; with `--workstation`, through `sudo`, to measure in full |
| `--port-forge N` `--port-deck N` `--port-ssh N` | published ports; the summary shows each port in use, defaults included. `--port-forge` goes with `--bench`, `--port-ssh` with container mode |
| `--forge-project N` | the base name of the compose projects (default `lcars`) |

The measurement lives in the kit: piped with no kit already in place, `--check` and `--dry-run`
stop before downloading, measure nothing, and print the command that would run.
`install.sh --help` lists the rest.

Piped, the installer puts the version's tree under `~/.lcars/kits/<version>/lcars_install`: the
`deploy/…` commands of this document run from that directory.

Each release publishes its own `install.sh`, bound to that version's artifacts: a specific version
comes from `releases/download/<version>/install.sh`, and `install.sh.sha256`, published next to it,
lets you check the installer before running it. The kit is downloaded into
`~/.lcars/kits/<version>/` and checked against the sha256 sums written into the installer; a
mismatch deletes the file and stops the install. A version published with a minisign key carries
the public key in its installer and the `.minisig` signature of each kit: when `minisign` is
installed, a missing or invalid signature stops the install; without `minisign`, or without a key
in the installer, it reports that provenance rests on the sha256 sums. In container mode, the
version's image is pulled from its registry without credentials (`ghcr.io` for a GitHub release)
when it is not already on the daemon; publishing a version checks that pull (`deploy/README.md`,
« Publier une version »).

#### End of install

With `--bench`, the install creates the forge, provisions accounts and teams, generates the
tokens, starts the container or the services and registers the CI runner. In container mode, it
ends on the bench verdict and its entry points (excerpt):

```
[bench-up] banc PRÊT
[bench-up]   forge     : http://192.168.1.42:21000   (admiral / toto123456 · lcars / toto32toto32)
[bench-up]   deck      : http://192.168.1.42:20999
[bench-up]   conteneur : lcars-fleet-lcars-1   ssh lcars@192.168.1.42 -p 2222
[bench-up]   runner    : enregistré — labels : shell:…,dood:…,ubuntu-latest:…
[bench-up]   fleet     : démarrée sous lcars
[bench-up]   détruire  : bench-down.sh --project lcars --yes
```

Any verdict other than `banc PRÊT` names what is missing. In `--workstation` mode, it ends on the
acceptance: the announced credentials open the forge, a runner serves the labels a project's
workflows ask for, and the fleet starts under a fleet human of the machine; the credentials are
printed next.

#### For development

From a clone, the installer installs from that clone (`source` channel). In `--workstation` mode
it installs the Elixir/OTP toolchain and Node at the versions pinned by the provisioning and builds
the runtime; the dependencies come from hex.pm, which the machine reaches directly (`sudo` passes
no proxy variable). In container mode, the image must be on the daemon before `install.sh`.
`deploy/container build` builds it on the workstation, from a committed tree: it runs
`deploy/pack.sh`, which needs the Elixir/OTP toolchain, node, bats, shellcheck and docker buildx, and runs the
full gate. A published image is pulled, and `install.sh` receives it through the same variable, in
the same shell:

```bash
export LCARS_IMAGE=<registry/image:tag>
deploy/container pull
bash install.sh --bench
```

`--from-release`, from a clone, replays the installer of the repository's latest published
release, checked against its sum.

```bash
git clone --branch <version> https://github.com/zurp-embedded/LCARS-fleet.git lcars-fleet
cd lcars-fleet
bash install.sh --workstation --bench
```

A kit (`lcars-fleet-<version>-otp<N>-<arch>.tar.gz`, produced by `deploy/pack.sh`) installs into
the system with `deploy/workstation up --from <kit.tar.gz>` (`kit` channel). The machine
records the channel used; updates go through the same channel, and installing one channel over
another is refused, naming the way out.

### Getting in

With `--bench`, two accounts exist, and they are not interchangeable.

| account | password | what it is |
|---|---|---|
| `lcars` | `toto32toto32` | the fleet's human: the everyday account. It owns the projects, talks to the agents, has a console on the dashboard |
| `admiral` | `toto123456` | the system administrator: it owns the container (sudo) and founded the forge. Starting a fleet under it is refused by construction |

Into the system (`--workstation --bench`), the forge administrator is the account that ran the
install, with the same password. These passwords are test defaults.

What listens on `0.0.0.0` is reachable from the local network: someone else can open the dashboard
from their own machine. In a container, `--bench` publishes the forge, the dashboard and ssh on
`0.0.0.0`; without `--bench`, it publishes the dashboard and ssh on `127.0.0.1`. Into the system,
the dashboard listens on `0.0.0.0` either way, and so does the forge brought up by `--bench`.
Trusted network only.

The ports are the ones the installer's summary showed.

**The dashboard** — `http://<address>:<deck port>`. The main entrance; you log in through the forge
(the button is on the landing page). It carries one web terminal per human, the fleet's state and
the list of running agents.

**The forge** — `http://<address>:<forge port>`. A full Gitea: the projects, their pull requests,
their CI runs. Log in as `lcars`.

**SSH** — `ssh lcars@<address> -p <ssh port>`. The same container, in a terminal:

```bash
fleet start           # start the fleet
fleet status          # what it is doing
lcars catalogue list  # the business catalogues this install carries
```

#### The demo catalogue

At install time one catalogue is there, `fleet`. A second one, `web-demo`, waits on the forge as a
repository; `lcars catalogue list` shows it as `disponible`, and `lcars catalogue install
web-demo` creates its organisation on the forge, its role accounts, its teams, and puts its
material on the machine. It is a forge admin gesture; on this bench, `lcars` is a forge admin. Once
installed, its cards show up next to `fleet`'s when an agent proposes a catalogue for a new
project; a project's catalogue is fixed at creation.

In this version, `lcars catalogue install` fails: resolving the catalogue's repository reads a log
line instead of its answer. The defect is known; `fleet`, which ships with the install, is not
affected.

### A first project

Everything goes through a conversation with an agent; there is no form.

1. Open the dashboard and start the console.
2. Run `fleet start`, then `claude`: that is the fleet's front desk.
3. Ask it for a project. It shows the cards carried by the installed catalogues (a card is a
   workflow: who writes, who reviews, whether CI must be green before merging), lets you pick one,
   and creates the repository, the branches and the working directories.
4. Open a ticket on that project. The fleet picks it up, spawns the agents the card names, and the
   work arrives as a pull request, judged by the reviewers that card declares.

With `--bench`, the runner is registered: a project's CI runs. On an existing forge, CI runs on the
runners its operator has registered there.

### Updating

In a container, an instance already in place is not reinstalled: `install.sh` refuses it and names
its update. The container is recreated on the new version's image; its volumes and its store stay.
The gesture runs from the tree that installed the instance, whose compose created it:

```bash
LCARS_IMAGE=<version image> deploy/container pull
LCARS_IMAGE=<version image> deploy/container -p <base>-fleet up
```

A bench (`--bench`) keeps its forge and its tokens; only its container's image changes:
`deploy/docker/bench/bench-swap-image.sh --image <version image> --forge-project <base>`.

Into the system, the new version's installer is run again through the same channel: it starts again
from the measurement and puts back what changed.

### Tearing down

The ground is destroyed and rebuilt; no uninstaller comes with it.

Container mode, from the install's tree. An instance's store is its `<base>-fleet-*` volumes
(caches, toolchains, sysroots, converged state): what takes time to rebuild, kept outside the
compose project.

```bash
deploy/docker/bench/bench-down.sh --project <base> --yes   # with --bench: the container, the forge, the runner and the store, volumes included
deploy/container -p <base>-fleet reset                     # after confirmation, the container and its volumes; the forge and the store stay
```

`--workstation` mode: the WSL 2 distribution is removed (`wsl --unregister <distribution>` on the
Windows side), the dedicated machine is reinstalled. Under WSL, the forge and the runner brought up
by `--bench` live in Docker Desktop and outlive the distribution; they are removed before it:

```bash
docker compose -p <base>-forge down -v
docker compose -p <base>-runner down -v
```

`~/.lcars` holds the downloaded kits and the per-human state.

### The limits of this beta

- The forge it creates is disposable and lives on the local network: it is a trial bench. An
  existing forge is plugged in through `FORGE_BASE_URL`; what it must provide (its addresses, a
  site-admin master token, the role accounts' password) and the gestures that set it up, check it
  and structure it (`deploy/container config`, `forge-check`, `forge-apply`) are in
  `deploy/README.md`, « Une forge fournie ».
- The passwords above are fixed defaults.
- Projects, repositories and containers stay until the operator deletes them.
- Agents cost tokens: they are Claude Code processes on the configured account, and a fleet left
  running keeps working.
- Exercised on Ubuntu (WSL 2 and native) with Docker; the preflight asks for a Debian-family
  distribution.

### When something goes wrong

```bash
deploy/container -p <base>-fleet status   # the instance's state seen from the host: 0 healthy · 1 degraded · 2 down
deploy/container -p <base>-fleet logs     # the container's own account of its boot
deploy/workstation doctor                 # --workstation mode: what is installed, what drifted; the probe asks for sudo, once
```

These commands run from the install's tree (a clone, or `~/.lcars/kits/<version>/lcars_install`
after a `curl | bash`). `-p` targets the container's compose project, `<base>-fleet` (`lcars-fleet`
by default; `--forge-project` changes the base). The `détruire` line of the final screen carries the
base. A PR blocked by its CI is fixed from the PR: the runner plays the `ci.yml` of the tested commit,
fixing that file and pushing again unblocks the PR itself.

### What is inside

- **A container, or a system** — Ubuntu 26.04, running the fleet runtime (Elixir/OTP) and a web
  dashboard.
- **A forge** — Gitea, in its own container, with the organisations, teams and machine accounts
  the fleet needs.
- **A runner** — Gitea Actions, registered, so that CI is real.
- **Catalogues** — the business definitions: which roles exist, which workflow cards they serve,
  what each agent's system prompt is. A catalogue is data, not code. `fleet` ships in the runtime;
  `web-demo` is deposited on the forge, and its install fails in this version (« The demo
  catalogue »).
- **Agents** — Claude Code processes, each in a sandbox that mounts exactly what its role needs.

### License

See [`LICENSE`](LICENSE) and [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
