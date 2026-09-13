<!-- Date: 2026-08-18 · Dernière révision: 2026-09-13 · Statut: README de la beta, français puis anglais dans ce seul fichier · Référencé par: la page d'accueil du dépôt, le kit -->

# LCARS-fleet — beta

**Firmware-as-a-Service.** Une flotte d'agents qui tourne sur une machine : une forge git, un runner
CI, des agents tenus par leur rôle et un tableau de bord, montés par une commande, en conteneur
ou dans le système.

[Français](#français) · [English](#english)

---

## Français

> **C'est une beta, faite pour être essayée.** Elle monte une pile jetable : sa forge, son runner,
> ses comptes. Ce n'est pas un déploiement de production, et elle ne touche à aucune forge
> existante.

### Prérequis

| Composant | Rôle |
|---|---|
| Docker, avec le plugin compose | exécute le conteneur LCARS, la forge et le runner CI. Sous Windows : Docker Desktop avec l'intégration WSL 2 activée pour la distribution. Sous Ubuntu : `docker.io` et `docker-compose-v2`, ou Docker Engine ; en mode conteneur le daemon est un prérequis, en mode `--workstation` sur une machine dédiée l'installeur le pose |
| git, curl | le clone, le téléchargement du kit, les échanges avec la forge |
| sudo | mode `--workstation` seulement : une escalade, pour le provisionnement du système |
| WSL 2 | sous Windows ; WSL 1 ne fournit pas les espaces de noms nécessaires |
| Compte Anthropic | les agents sont des processus Claude Code ; les identifiants de `~/.claude/.credentials.json` sont réutilisés quand ils existent |

Les versions publiées sont pré-compilées : un kit et une image. Aucune chaîne Elixir/Erlang n'est
requise pour les installer.

### Installation

La dernière version publiée s'installe en une commande. En conteneur :

```bash
curl -fsSL https://github.com/zurp-embedded/LCARS-temp/releases/latest/download/install.sh | bash -s -- --bench
```

Dans ce système (une distribution WSL 2, ou une machine Linux dédiée déclarée par
`LCARS_ALLOW_ANY_HOST=1`) :

```bash
curl -fsSL https://github.com/zurp-embedded/LCARS-temp/releases/latest/download/install.sh | bash -s -- --workstation --bench
```

`install.sh` mesure la machine, affiche ce qui sera installé, attend une confirmation (Entrée
pour continuer, Ctrl+C pour annuler), puis délègue. Sans terminal, il continue en le disant. Il
ne demande jamais `sudo` lui-même ; le mode `--workstation` le fait, une fois. Relancer est toujours sûr : l'état est
celui du système, mesuré à chaque passage.

| Option | Effet |
|---|---|
| *(sans option)* | LCARS tourne dans un conteneur Docker ; rien n'est installé hors de Docker |
| `--workstation` | LCARS s'installe dans le système |
| `--bench` | l'installeur monte lui-même la forge Gitea, son runner CI et un compte de démonstration. Sans cette option, une forge existante est requise (`FORGE_BASE_URL`) |
| `--check` | mesure et affiche, ne modifie rien |
| `--dry-run` | tout jusqu'au bilan, puis la commande qui serait exécutée |
| `--port-forge N` `--port-deck N` `--port-ssh N` | ports publiés ; défauts 21000, 20999, 2222 |
| `--forge-project N` | la base des projets compose (défaut `lcars`) |

`install.sh --help` liste le reste.

Chaque release publie son propre `install.sh`, lié aux artefacts de cette version : une version
précise se prend par `releases/download/<version>/install.sh`, et `install.sh.sha256`, publié à
côté, permet de vérifier l'installeur avant de le jouer. Le kit est téléchargé dans
`~/.lcars/kits/<version>/` et vérifié contre les sommes sha256 inscrites dans l'installeur ; un
écart supprime le fichier et interrompt l'installation. La signature minisign est vérifiée si
`minisign` est installé ; sinon l'absence de vérification est signalée. En mode conteneur, l'image
de la version est tirée depuis `ghcr.io` quand elle n'est pas déjà sur le daemon.

#### Fin d'installation

L'installation crée la forge, provisionne comptes et équipes, génère les jetons, démarre les
services ou le conteneur, enregistre le runner CI, puis affiche les points d'entrée :

```
banc PRÊT
  forge     : http://192.168.1.42:21000   (admiral / toto123456 · lcars / toto32toto32)
  deck      : http://192.168.1.42:20999
  conteneur : lcars-fleet-lcars-1   ssh lcars@192.168.1.42 -p 2222
  runner    : enregistré (1 vu(s) par la forge)
  fleet     : démarrée sous lcars
  détruire  : bench-down.sh --project lcars --yes
```

Tout autre verdict que `banc PRÊT` nomme l'élément manquant. En mode `--workstation`,
l'acceptation vérifie ensuite que les identifiants annoncés ouvrent la forge, qu'un runner sert
les labels que les workflows d'un projet demandent, et que la fleet démarre sous l'humain de fleet.

#### Pour développer

Depuis un clone, l'installeur installe depuis ce clone (canal `source`). En mode `--workstation`,
il compile le runtime et pose la chaîne Elixir/OTP aux versions épinglées par le provisionnement.
En mode conteneur, l'image doit être sur le daemon avant `install.sh` : `deploy/container build`
la bâtit sur le poste (la chaîne Elixir/OTP et node sont requises, et le gate complet est joué),
ou `LCARS_IMAGE=<registre/image:tag> deploy/container pull` la tire. `--from-release` prend le
kit de cette version à la place.

```bash
git clone --branch <version> https://github.com/zurp-embedded/LCARS-temp.git lcars-fleet
cd lcars-fleet
bash install.sh --workstation --bench
```

Un kit (`lcars-fleet-<version>-otp<N>-<arch>.tar.gz`, produit par `deploy/pack.sh`) s'installe
dans le système par `deploy/workstation up --from <kit.tar.gz>` (canal `kit`).
`/etc/lcars/channel` enregistre le canal utilisé ; les mises à jour se font par le même canal, et
l'installation d'un canal par-dessus un autre est refusée en nommant le geste.

### Entrer

Deux comptes existent, et ils ne sont pas interchangeables.

| compte | mot de passe | ce que c'est |
|---|---|---|
| `lcars` | `toto32toto32` | l'humain de la flotte : le compte d'usage. Il possède les projets, parle aux agents, a une console sur le tableau de bord |
| `admiral` | `toto123456` | l'administrateur système : il possède le conteneur (sudo) et a fondé la forge. Démarrer une flotte sous lui est refusé par construction |

Ces mots de passe sont des défauts de test. Avec `--bench`, la forge, le tableau de bord et ssh
écoutent sur `0.0.0.0` : le réseau local y accède, une autre personne peut ouvrir le tableau de
bord depuis son poste. Réseau de confiance seulement. Sans `--bench`, avec une forge existante
(`FORGE_BASE_URL`), le conteneur publie le tableau de bord et ssh sur `127.0.0.1`.

**Le tableau de bord** — `http://<adresse>:20999`. L'entrée principale ; on s'y connecte par la
forge (le bouton est sur la page d'accueil). Il porte un terminal web par humain, l'état de la
flotte et la liste des agents qui tournent.

**La forge** — `http://<adresse>:21000`. Un Gitea complet : les projets, leurs pull requests,
leurs runs de CI. Connexion en `lcars`.

**SSH** — `ssh lcars@<adresse> -p 2222`. Le même conteneur, dans un terminal :

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

### Un premier projet

Tout passe par une conversation avec un agent ; il n'y a pas de formulaire.

1. Ouvrir le tableau de bord et démarrer la console.
2. Lancer `fleet start`, puis `claude` : c'est le guichet de la flotte.
3. Lui demander un projet. Il montre les cartes que portent les catalogues installés (une carte est
   un workflow : qui écrit, qui relit, si la CI doit être verte avant de fusionner), laisse en
   choisir une, et crée le dépôt, les branches et les dossiers de travail.
4. Ouvrir un ticket sur ce projet. La flotte le prend, lance les agents que la carte nomme, et le
   travail arrive en pull request, jugée par les relecteurs que cette carte déclare.

Le runner est enregistré : la CI d'un projet tourne.

### Retirer

Pas de désinstalleur : le terrain se détruit et se refait.

Mode conteneur, avec la commande affichée sur la ligne `détruire` :

```bash
deploy/docker/bench/bench-down.sh --project <base> --yes   # le conteneur, la forge et le runner, volumes compris
deploy/container -p <base>-fleet reset                     # le conteneur, son image locale et ses volumes ; la forge reste
```

Mode `--workstation` : la distribution WSL 2 se supprime (`wsl --unregister <distribution>` côté
Windows), la machine dédiée se réinstalle. `~/.lcars` porte les kits téléchargés et les états par
humain.

### Ce que cette beta ne fait pas

- Pas de déploiement de production : la forge créée est jetable et vit sur le réseau local. Une
  forge existante se branche par `FORGE_BASE_URL` et `deploy/container forge-check`.
- Les mots de passe ci-dessus sont des défauts fixes.
- Rien n'est supprimé à la place de l'opérateur : projets, dépôts et conteneurs restent.
- Les agents coûtent des tokens : ce sont des processus Claude Code sur le compte configuré, et une
  flotte laissée tourner continue de travailler.
- Exercé sur Ubuntu (WSL 2 et natif) avec Docker ; les autres distributions ne sont pas testées.

### Si quelque chose va de travers

```bash
deploy/container -p <base>-fleet status   # l'état de l'instance vu de l'hôte : 0 sain · 1 dégradé · 2 panne
deploy/container -p <base>-fleet logs     # le récit que le conteneur fait de son propre démarrage
sudo deploy/provision doctor              # mode --workstation : ce qui est posé, ce qui a dérivé
```

`-p` vise le projet compose du conteneur, `<base>-fleet` (`lcars-fleet` par défaut ;
`--forge-project` change la base). La ligne `détruire` de l'écran final porte la base. Une PR
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
  code. `fleet` est livré dans le runtime ; `web-demo` est déposé sur la forge et s'installe en un
  geste.
- **Des agents** — des processus Claude Code, chacun dans un bac à sable qui monte exactement ce
  dont son rôle a besoin.

### Licence

Voir [`LICENSE`](LICENSE) et [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

---

## English

> **This is a beta, meant to be tried.** It brings up a disposable stack: its forge, its runner,
> its accounts. It is not a production deployment, and it touches no existing forge.

### Requirements

| Component | Role |
|---|---|
| Docker, with the compose plugin | runs the LCARS container, the forge and the CI runner. On Windows: Docker Desktop with WSL 2 integration enabled for the distribution. On Ubuntu: `docker.io` and `docker-compose-v2`, or Docker Engine; in container mode the daemon is a prerequisite, in `--workstation` mode on a dedicated machine the installer installs it |
| git, curl | the clone, the kit download, the exchanges with the forge |
| sudo | `--workstation` mode only: one escalation, for provisioning the system |
| WSL 2 | on Windows; WSL 1 does not provide the namespaces needed |
| Anthropic account | agents are Claude Code processes; the credentials in `~/.claude/.credentials.json` are reused when present |

Published versions are pre-built: a kit and an image. No Elixir/Erlang toolchain is needed to
install them.

### Install

The latest published version installs with one command. In a container:

```bash
curl -fsSL https://github.com/zurp-embedded/LCARS-temp/releases/latest/download/install.sh | bash -s -- --bench
```

Into this system (a WSL 2 distribution, or a dedicated Linux machine declared with
`LCARS_ALLOW_ANY_HOST=1`):

```bash
curl -fsSL https://github.com/zurp-embedded/LCARS-temp/releases/latest/download/install.sh | bash -s -- --workstation --bench
```

`install.sh` measures the machine, shows what will be installed, waits for a confirmation (Enter
to continue, Ctrl+C to cancel), then delegates. Without a terminal it goes on and says so. It
never asks for `sudo` itself; `--workstation` mode does, once. Re-running is always safe: the state is the
system's, measured on every run.

| Option | Effect |
|---|---|
| *(no option)* | LCARS runs in a Docker container; nothing is installed outside Docker |
| `--workstation` | LCARS is installed into the system |
| `--bench` | the installer brings up the Gitea forge, its CI runner and a demo account itself. Without it, an existing forge is required (`FORGE_BASE_URL`) |
| `--check` | measures and reports, changes nothing |
| `--dry-run` | everything up to the summary, then the command that would run |
| `--port-forge N` `--port-deck N` `--port-ssh N` | published ports; defaults 21000, 20999, 2222 |
| `--forge-project N` | the base name of the compose projects (default `lcars`) |

`install.sh --help` lists the rest.

Each release publishes its own `install.sh`, bound to that version's artifacts: a specific version
comes from `releases/download/<version>/install.sh`, and `install.sh.sha256`, published next to it,
lets you check the installer before running it. The kit is downloaded into
`~/.lcars/kits/<version>/` and checked against the sha256 sums written into the installer; a
mismatch deletes the file and stops the install. The minisign signature is checked when
`minisign` is installed; otherwise the missing check is reported. In container mode, the version's
image is pulled from `ghcr.io` when it is not already on the daemon.

#### End of install

The install creates the forge, provisions accounts and teams, generates the tokens, starts the
services or the container, registers the CI runner, then prints the entry points:

```
banc PRÊT
  forge     : http://192.168.1.42:21000   (admiral / toto123456 · lcars / toto32toto32)
  deck      : http://192.168.1.42:20999
  conteneur : lcars-fleet-lcars-1   ssh lcars@192.168.1.42 -p 2222
  runner    : enregistré (1 vu(s) par la forge)
  fleet     : démarrée sous lcars
  détruire  : bench-down.sh --project lcars --yes
```

Any verdict other than `banc PRÊT` names what is missing. In `--workstation` mode, the acceptance
then checks that the announced credentials open the forge, that a runner serves the labels a
project's workflows ask for, and that the fleet starts under the fleet human.

#### For development

From a clone, the installer installs from that clone (`source` channel). In `--workstation` mode
it builds the runtime and installs the Elixir/OTP toolchain at the versions pinned by the
provisioning. In container mode, the image must be on the daemon before `install.sh`:
`deploy/container build` builds it on the workstation (the Elixir/OTP toolchain and node are
required, and the full gate runs), or `LCARS_IMAGE=<registry/image:tag> deploy/container pull`
pulls it. `--from-release` takes that version's kit instead.

```bash
git clone --branch <version> https://github.com/zurp-embedded/LCARS-temp.git lcars-fleet
cd lcars-fleet
bash install.sh --workstation --bench
```

A kit (`lcars-fleet-<version>-otp<N>-<arch>.tar.gz`, produced by `deploy/pack.sh`) installs into
the system with `deploy/workstation up --from <kit.tar.gz>` (`kit` channel). `/etc/lcars/channel`
records the channel used; updates go through the same channel, and installing one channel over
another is refused, naming the way out.

### Getting in

Two accounts exist, and they are not interchangeable.

| account | password | what it is |
|---|---|---|
| `lcars` | `toto32toto32` | the fleet's human: the everyday account. It owns the projects, talks to the agents, has a console on the dashboard |
| `admiral` | `toto123456` | the system administrator: it owns the container (sudo) and founded the forge. Starting a fleet under it is refused by construction |

These passwords are test defaults. With `--bench`, the forge, the dashboard and ssh listen on
`0.0.0.0`: the local network reaches them, someone else can open the dashboard from their own
machine. Trusted network only. Without `--bench`, with an existing forge (`FORGE_BASE_URL`), the
container publishes the dashboard and ssh on `127.0.0.1`.

**The dashboard** — `http://<address>:20999`. The main entrance; you log in through the forge (the
button is on the landing page). It carries one web terminal per human, the fleet's state and the
list of running agents.

**The forge** — `http://<address>:21000`. A full Gitea: the projects, their pull requests, their CI
runs. Log in as `lcars`.

**SSH** — `ssh lcars@<address> -p 2222`. The same container, in a terminal:

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

### A first project

Everything goes through a conversation with an agent; there is no form.

1. Open the dashboard and start the console.
2. Run `fleet start`, then `claude`: that is the fleet's front desk.
3. Ask it for a project. It shows the cards carried by the installed catalogues (a card is a
   workflow: who writes, who reviews, whether CI must be green before merging), lets you pick one,
   and creates the repository, the branches and the working directories.
4. Open a ticket on that project. The fleet picks it up, spawns the agents the card names, and the
   work arrives as a pull request, judged by the reviewers that card declares.

The runner is registered: a project's CI runs.

### Tearing down

No uninstaller: the ground is destroyed and rebuilt.

Container mode, with the command printed on the `détruire` line:

```bash
deploy/docker/bench/bench-down.sh --project <base> --yes   # the container, the forge and the runner, volumes included
deploy/container -p <base>-fleet reset                     # the container, its local image and its volumes; the forge stays
```

`--workstation` mode: the WSL 2 distribution is removed (`wsl --unregister <distribution>` on the
Windows side), the dedicated machine is reinstalled. `~/.lcars` holds the downloaded kits and the
per-human state.

### What this beta does not do

- No production deployment: the forge it creates is disposable and lives on the local network. An
  existing forge is plugged in through `FORGE_BASE_URL` and `deploy/container forge-check`.
- The passwords above are fixed defaults.
- Nothing is deleted on the operator's behalf: projects, repositories and containers stay.
- Agents cost tokens: they are Claude Code processes on the configured account, and a fleet left
  running keeps working.
- Exercised on Ubuntu (WSL 2 and native) with Docker; other distributions are untested.

### When something goes wrong

```bash
deploy/container -p <base>-fleet status   # the instance's state seen from the host: 0 healthy · 1 degraded · 2 down
deploy/container -p <base>-fleet logs     # the container's own account of its boot
sudo deploy/provision doctor              # --workstation mode: what is installed, what drifted
```

`-p` targets the container's compose project, `<base>-fleet` (`lcars-fleet` by default;
`--forge-project` changes the base). The `détruire` line of the final screen carries the base. A
PR blocked by its CI is fixed from the PR: the runner plays the `ci.yml` of the tested commit,
fixing that file and pushing again unblocks the PR itself.

### What is inside

- **A container, or a system** — Ubuntu 26.04, running the fleet runtime (Elixir/OTP) and a web
  dashboard.
- **A forge** — Gitea, in its own container, with the organisations, teams and machine accounts
  the fleet needs.
- **A runner** — Gitea Actions, registered, so that CI is real.
- **Catalogues** — the business definitions: which roles exist, which workflow cards they serve,
  what each agent's system prompt is. A catalogue is data, not code. `fleet` ships in the runtime;
  `web-demo` is deposited on the forge and installs in one gesture.
- **Agents** — Claude Code processes, each in a sandbox that mounts exactly what its role needs.

### License

See [`LICENSE`](LICENSE) and [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
