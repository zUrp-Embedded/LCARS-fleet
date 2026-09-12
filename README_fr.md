<!-- Date: 2026-08-18 · Dernière révision: 2026-09-12 · Statut: README de la BETA livrée, version FR (le jumeau EN est README_EN.md) · Référencé par: le kit, README.md -->

<a id="top"></a>

# LCARS-fleet — beta

### Firmware-as-a-Service.

*(In English: [README_EN.md](README_EN.md) — work in progress, see this page meanwhile.)*

Une flotte d'agents qui tourne sur une machine : une forge git, un runner CI, des agents tenus par
leur rôle, et un tableau de bord — montés par une commande, en conteneur ou dans le système.

> **C'est une BETA, faite pour être essayée.** Elle monte une pile **jetable** : sa forge, son
> runner, ses comptes. Ce n'est pas un déploiement de production, et elle ne touche à aucune forge
> existante.

---

## Prérequis

| Composant | Rôle |
|---|---|
| Docker | exécute le conteneur LCARS, la forge et le runner CI. Sous Windows : Docker Desktop avec l'intégration WSL 2 activée pour la distribution. Sous Linux natif, en mode conteneur, le daemon est un prérequis ; en mode `--workstation`, l'installeur le pose |
| git, curl | le clone, le téléchargement du kit et les échanges avec la forge |
| sudo | mode `--workstation` seulement : une escalade, pour le provisionnement du système |
| WSL 2 | sous Windows ; WSL 1 ne fournit pas les espaces de noms nécessaires |
| Compte Anthropic | les agents sont des processus Claude Code ; les identifiants de `~/.claude/.credentials.json` sont réutilisés |

Les versions publiées sont pré-compilées : un kit et une image. Aucune chaîne Elixir/Erlang n'est
requise, sauf pour une installation depuis un clone en mode `--workstation`, où l'installeur la
pose lui-même.

---

## Installation

`install.sh` est l'unique point d'entrée. Il mesure la machine, affiche ce qui sera installé,
demande confirmation, puis délègue. Il ne demande jamais `sudo` lui-même ; le mode `--workstation`
le fait, une fois.

| Option | Effet |
|---|---|
| *(sans option)* | LCARS tourne dans un conteneur Docker ; rien n'est installé hors de Docker |
| `--workstation` | LCARS s'installe dans le système : une distribution WSL 2, ou une machine Linux dédiée déclarée par `LCARS_ALLOW_ANY_HOST=1` |
| `--bench` | l'installeur monte lui-même la forge Gitea, son runner CI et un compte de démonstration. Sans cette option, une forge existante est requise (`FORGE_BASE_URL`) |
| `--check` | mesure et affiche, ne modifie rien |
| `--dry-run` | tout jusqu'au bilan, puis la commande qui serait exécutée |
| `--from-release` | depuis un clone : prendre le kit de cette version, vérifié, au lieu de l'arbre courant. C'est ce que fait le script quand il est pipé |
| `--port-forge N` `--port-deck N` `--port-ssh N` | ports publiés ; défauts 21000, 20999, 2222 |
| `--forge-project N` | la base des projets compose (défaut `lcars`) |

`install.sh --help` liste le reste (`--repo`, `--substrate`, et les options passées au
provisionnement en mode `--workstation`).

### Depuis une release

Chaque release publie son propre `install.sh`, lié aux artefacts de cette version :

```bash
curl --proto '=https' --tlsv1.2 -fsSL https://<forge>/<owner>/lcars-fleet/releases/download/<version>/install.sh | bash -s -- --bench
```

```bash
curl --proto '=https' --tlsv1.2 -fsSL https://<forge>/<owner>/lcars-fleet/releases/download/<version>/install.sh | bash -s -- --workstation --bench
```

Le kit est téléchargé dans `~/.lcars/kits/<version>/` et vérifié contre les sommes sha256
inscrites dans l'installeur ; un écart supprime le fichier et interrompt l'installation. La
signature minisign est vérifiée si `minisign` est installé ; sinon l'absence de vérification est
signalée. `install.sh.sha256`, publié à côté, permet de vérifier l'installeur lui-même avant de le
jouer.

### Depuis les sources

```bash
git clone --branch <version> https://<forge>/<owner>/lcars-fleet.git
cd lcars-fleet
bash install.sh --workstation --bench     # ou : bash install.sh --bench
```

Lancé depuis un clone, l'installeur installe depuis ce clone (canal `source`) : en mode
`--workstation`, il compile le runtime et pose la chaîne Elixir/OTP aux versions épinglées par le
provisionnement ; en mode conteneur, `deploy/container build` bâtit l'image sur le poste.
`--from-release` prend le kit de cette version à la place.

### Depuis un kit

Un kit (`lcars-fleet-<version>-otp<N>-<arch>.tar.gz`, produit par `deploy/pack.sh`) s'installe
dans le système par son délégué :

```bash
deploy/workstation up --from lcars-fleet-<version>-otp27-x86_64.tar.gz
```

Le `.sha256` posé à côté est vérifié quand il existe, le kit est détaré sous `~/.lcars/kits/<nom>/`
et tout se joue depuis lui (canal `kit`).

### Canal d'installation

`/etc/lcars/channel` enregistre le canal utilisé, `source` ou `kit`. Les mises à jour se font par
le même canal ; l'installation d'un canal par-dessus un autre est refusée, avec l'indication de
la procédure : mise à jour par le canal en place, ou le terrain se refait.

### Fin d'installation

L'installation crée la forge, provisionne comptes et équipes, génère les jetons, démarre les
services ou le conteneur, enregistre le runner CI, puis affiche les points d'entrée. Elle est
idempotente : relancée, elle converge vers le même état.

```
banc PRÊT
  forge     : http://192.168.1.42:21000   (admiral / toto123456 · lcars / toto32toto32)
  deck      : http://192.168.1.42:20999
  conteneur : lcars-fleet-1   ssh lcars@192.168.1.42 -p 2222
  runner    : enregistré (1 vu(s) par la forge)
  écoute    : 0.0.0.0 — ouvert sur le réseau
  fleet     : démarrée sous lcars (sans identifiants claude : aucun pod ne pense)
  détruire  : bench-down.sh --project lcars --yes
```

L'adresse affichée est celle de la machine, détectée au démarrage. Tout autre verdict que
`banc PRÊT` nomme l'élément manquant. En mode `--workstation`, l'acceptation vérifie ensuite que
les identifiants annoncés ouvrent la forge, qu'un runner sert les labels que les workflows d'un
projet demandent, et que la fleet démarre sous l'humain de fleet.

---

## Entrer

Deux comptes existent, et ils ne sont **pas** interchangeables.

| compte | mot de passe | ce que c'est |
|---|---|---|
| **`lcars`** | `toto32toto32` | **l'humain de la flotte.** Le compte d'usage : il possède les projets, parle aux agents, et a une console sur le tableau de bord. |
| **`admiral`** | `toto123456` | **l'administrateur système.** Il possède le conteneur (sudo) et a fondé la forge. Il fait tourner la machine, pas la flotte : démarrer une flotte sous lui est refusé par construction. |

⚠ **Ces mots de passe sont des défauts de test, écrits en clair dans ce README — et le banc écoute
sur `0.0.0.0`, donc tout ce qui atteint la machine l'atteint.** C'est délibéré : l'intérêt de
cette beta est qu'une autre personne du même réseau ouvre le tableau de bord depuis son propre
poste. C'est un choix pour un réseau de confiance, et rien d'autre. Pour le refermer sur la
machine seule, en mode conteneur, les ports du deck et de ssh sont publiés sur `127.0.0.1` ; en
mode `--workstation`, `--port-deck` et `--port-ssh` restent sur l'adresse de la machine.

Si l'adresse annoncée est fausse (plusieurs interfaces, un nom DNS, un reverse-proxy), la ligne
`écoute` de l'écran final le dit, et `deploy/container status` la relit.

### Trois portes

**Le tableau de bord** — `http://<adresse>:20999`

L'entrée principale. On s'y connecte par la forge (le bouton est sur la page d'accueil). Il porte
un terminal web par humain, l'état de la flotte, et la liste des agents qui tournent.

**La forge** — `http://<adresse>:21000`

Un Gitea complet. Les projets, leurs pull requests, leurs runs de CI. Connexion en `lcars`.

**SSH** — `ssh lcars@<adresse> -p 2222`

Le même conteneur, dans un terminal. De là :

```bash
fleet start           # démarrer la flotte
fleet status          # ce qu'elle fait
lcars catalogue list  # les catalogues métier que cette installation porte
```

### Installer le catalogue de démonstration

À l'installation, un catalogue est là, `fleet`. Un second, `web-demo`, attend sur la forge sous
forme de dépôt — `catalogue list` l'affiche en `disponible`. L'installer tient en une commande :

```bash
lcars catalogue install web-demo
```

Elle crée son organisation sur la forge, ses comptes de rôle, ses équipes, et pose son matériel
sur la machine. C'est un geste d'administration : `lcars` peut le jouer parce que ce banc en fait
un administrateur de la forge, et le runtime lit ce fait sur la forge plutôt que dans un drapeau
local.

Une fois installé, ses cartes apparaissent à côté de celles de `fleet` quand un agent propose le
catalogue d'un nouveau projet — et le catalogue d'un projet est fixé pour sa vie, donc la question
est posée au lieu d'être devinée.

---

## Un premier projet

Tout passe par une conversation avec un agent ; il n'y a pas de formulaire.

1. Ouvrir le tableau de bord et démarrer la console.
2. Lancer `fleet start`, puis `claude` : c'est le guichet de la flotte.
3. Lui demander un projet. Il montre les **cartes** que portent les catalogues installés (une
   carte est un workflow : qui écrit, qui relit, si la CI doit être verte avant de fusionner),
   laisse en choisir une, et crée le dépôt, les branches et les dossiers de travail.
4. Ouvrir un ticket sur ce projet. La flotte le prend, lance les agents que la carte nomme, et le
   travail arrive en pull request, jugée par les relecteurs que cette carte déclare.

Le runner est déjà enregistré : un projet dont la carte exige une CI verte l'obtient réellement.

---

## Retirer

Il n'y a pas de désinstalleur : LCARS s'installe sur un terrain qu'on peut détruire, et un terrain
se refait.

Mode conteneur, avec la commande affichée sur la ligne `détruire` :

```bash
deploy/docker/bench/bench-down.sh --project <base> --yes   # le conteneur, la forge et le runner, volumes compris
deploy/container -p <base>-fleet reset                     # le conteneur, son image locale et ses volumes ; la forge reste
```

Mode `--workstation` : la distribution WSL 2 se supprime (`wsl --unregister <distribution>` côté
Windows) ou la machine dédiée se réinstalle. `~/.lcars` porte les kits téléchargés et les états par
humain.

---

## Ce que cette beta ne fait PAS

- **Ce n'est pas un déploiement de production.** La forge qu'elle crée est jetable et vit sur le
  réseau local. Brancher LCARS sur une forge existante passe par `FORGE_BASE_URL` et
  `deploy/container forge-check`, et ce chemin n'est pas celui de cette beta.
- **Les mots de passe ci-dessus sont des défauts fixes.** Adaptés à un essai sur un réseau de
  confiance, faux partout ailleurs.
- **Rien n'est supprimé à la place de l'opérateur.** Projets, dépôts et conteneurs restent
  jusqu'à ce qu'il les retire.
- **Les agents coûtent des tokens.** Ce sont des processus Claude Code sur le compte configuré.
  Une flotte laissée tourner continue de travailler.
- **Exercé sur Ubuntu (WSL 2 et natif) avec Docker.** Les autres distributions ne sont pas
  testées ; les messages d'échec sont écrits pour dire où.

---

## Si quelque chose va de travers

La pile est faite pour dire ce qui manque plutôt que pour avoir l'air en bonne santé :

```bash
deploy/container -p <base>-fleet status   # l'état de l'instance vu de l'hôte : 0 sain · 1 dégradé · 2 panne
deploy/container -p <base>-fleet logs     # le récit que le conteneur fait de son propre démarrage
sudo deploy/provision doctor              # mode --workstation : ce qui est posé, ce qui a dérivé
```

`-p` vise le projet compose du conteneur, `<base>-fleet` (`lcars-fleet` par défaut ;
`--forge-project` change la base). La ligne `détruire` de l'écran final porte la base, qui est ce
que `bench-down.sh --project` attend.

**Une PR bloquée par sa CI se répare depuis la PR.** Le runner joue le `ci.yml` du commit testé,
la tête de la branche : corriger ce fichier là et repousser débloque la PR elle-même.

---

## Ce qu'il y a dedans

- **Un conteneur, ou un système** — Debian ou Ubuntu, qui fait tourner le runtime de la flotte
  (Elixir/OTP) et un tableau de bord web.
- **Une forge** — Gitea, dans son propre conteneur, avec les organisations, équipes et comptes
  machine dont la flotte a besoin.
- **Un runner** — Gitea Actions, enregistré, pour que la CI soit réelle.
- **Des catalogues** — les définitions métier : quels rôles existent, quelles cartes de workflow
  ils servent, quel est le system prompt de chaque agent. Un catalogue est de la **donnée, pas du
  code**. `fleet` est livré dans le runtime et toujours là ; `web-demo` est déposé sur la forge et
  s'installe en un geste.
- **Des agents** — des processus Claude Code, chacun dans un bac à sable qui monte exactement ce
  dont son rôle a besoin.

---

## Licence

Voir [`LICENSE`](LICENSE) et [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
