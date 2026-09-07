<!-- Date: 2026-08-18 · Dernière révision: 2026-08-18 · Statut: README de la BETA livrée, version FR (le jumeau EN est README_EN.md) · Référencé par: le tar de livraison, README.md -->

<a id="top"></a>

# LCARS-fleet — beta

### Firmware-as-a-Service.
*Pas mal non ? C'est français.*

*(In English: [README_EN.md](README_EN.md).)*

Une flotte d'agents qui tourne sur ta machine : une forge git, un runner CI, des agents tenus par
leur rôle, et un tableau de bord — le tout monté par une commande, en conteneurs, sans rien
installer sur ton système.

> **C'est une BETA, faite pour être essayée.** Elle monte une pile **jetable** : sa forge, son
> runner, ses comptes. Ce n'est pas un déploiement de production, et elle ne touche à aucune forge
> que tu aurais déjà. La détruire ne laisse que les images docker.

---

## Prérequis

| Composant | Rôle |
|---|---|
| Docker | exécute le conteneur LCARS, la forge et le runner CI. Sous Windows : Docker Desktop avec l'intégration WSL 2. Sous Ubuntu natif, le paquet `lcars` installe `docker.io` s'il est absent |
| curl | téléchargement de la version, échanges HTTP avec la forge |
| python3 | lecture des réponses JSON de la forge |
| WSL 2 | sous Windows uniquement ; WSL 1 ne fournit pas de namespaces |
| Compte Anthropic | les agents sont des processus Claude Code ; les credentials de `~/.claude/.credentials.json` sont réutilisés |

Les versions publiées sont pré-compilées : un kit, des paquets Debian, une image. Aucun toolchain
Elixir/Erlang n'est requis, sauf pour une installation depuis les sources sur le rail poste.

---

## Installation

`install.sh` est l'unique point d'entrée. Il détecte ce que la machine permet, affiche ce qui sera
installé, demande confirmation, puis délègue au rail choisi.

| Option | Effet |
|---|---|
| `--workstation` | installe LCARS dans le système (Ubuntu ou WSL 2) : paquets `.deb` sous Debian/Ubuntu, kit sinon |
| `--container` | exécute LCARS dans un conteneur ; rien n'est installé hors de Docker |
| `--bench` | crée les annexes : forge Gitea, runner CI, compte de démonstration. Sans cette option, une forge existante doit être indiquée par `FORGE_BASE_URL` |
| `--dry-run` | affiche les artefacts, leurs sha256 attendus et la commande du rail, sans rien télécharger ni installer |
| `--check` | sonde en lecture seule |
| `--tar` | sous Debian/Ubuntu, utilise le kit plutôt que les paquets |
| `--port-forge N` `--port-deck N` `--port-ssh N` | ports publiés ; défauts 21000, 20999, 2222 |

Les arguments placés après `--` sont transmis tels quels au rail (`--bind`, `--advertise`,
`--project`).

### Depuis une release

Chaque release publie sa propre porte, liée aux artefacts de cette version :

```bash
curl --proto '=https' --tlsv1.2 -fsSL https://<forge>/<owner>/lcars-fleet/releases/download/<version>/install.sh | bash -s -- --workstation --bench
```

```bash
curl --proto '=https' --tlsv1.2 -fsSL https://<forge>/<owner>/lcars-fleet/releases/download/<version>/install.sh | bash -s -- --container --bench
```

Les artefacts sont téléchargés dans `~/.lcars/kits/<version>/` et vérifiés contre les sommes
sha256 inscrites dans la porte ; un écart supprime le fichier et interrompt l'installation. La
signature minisign est vérifiée si `minisign` est installé ; sinon, l'absence de vérification est
signalée.

Sur le rail `--workstation`, les paquets sont installés par `sudo apt-get install` ; c'est la seule
élévation de privilèges. Sous WSL 2, le paquet `lcars-docker-desktop` est ajouté automatiquement.
Sur le rail `--container` sous WSL, `sudo` est requis pour accéder à la socket Docker.

### Depuis le dépôt apt

```bash
sudo curl -fsSL https://<forge>/api/packages/<owner>/debian/repository.key -o /etc/apt/keyrings/lcars.asc
echo "deb [signed-by=/etc/apt/keyrings/lcars.asc] https://<forge>/api/packages/<owner>/debian <distribution> main" | sudo tee /etc/apt/sources.list.d/lcars.list
sudo apt update
sudo apt install lcars-demo                         # Ubuntu natif
sudo apt install lcars-docker-desktop lcars-demo    # WSL 2 avec Docker Desktop
```

Sous WSL 2, `lcars-docker-desktop` doit être installé dans la même transaction que les autres
paquets. Sans lui, apt sélectionne `docker.io`, ce qui démarre un second daemon et remplace la
socket de Docker Desktop ; le provisionnement détecte cet état et s'arrête en indiquant la
correction.

| Paquet | Contenu |
|---|---|
| `lcars` | socle : runtime, comptes de service, `/opt/lcars` |
| `lcars-workstation` | LCARS dans le système hôte |
| `lcars-container` | LCARS en conteneur |
| `lcars-forge` | forge Gitea locale |
| `lcars-bench` | runner CI et compte de démonstration |
| `lcars-demo` | méta-paquet : `lcars-workstation`, `lcars-forge`, `lcars-bench` |
| `lcars-tofu` | OpenTofu et son miroir de providers |
| `lcars-docker-desktop` | paquet vide satisfaisant la dépendance Docker sous WSL 2 |

Les paquets sont également publiés comme assets de la release, pour une installation hors ligne :

```bash
sudo apt install ./lcars-tofu_*.deb ./lcars_*.deb ./lcars-workstation_*.deb
```

Le provisionnement s'exécute à l'installation des paquets. `sudo /opt/lcars/deploy/provision
doctor` affiche l'état de la machine sans la modifier.

### Depuis les sources

```bash
git clone --branch <version> https://<forge>/<owner>/lcars-fleet.git
cd lcars-fleet
bash install.sh --workstation --bench     # ou --container --bench
```

Lancée depuis un clone, la porte installe depuis ce clone (provenance `source`). Pipée,
`--source [<ref>]` clone le dépôt au tag de la porte, ou à la référence indiquée. Sur le rail
`--workstation`, cette provenance compile le runtime et requiert Elixir/OTP aux versions minimales
déclarées par le provisionnement. Sur le rail `--container`, la compilation a lieu dans un
conteneur de build ; seule l'image résultante est conservée.

### Canal d'installation

`/etc/lcars/channel` enregistre le canal utilisé : `source`, `kit` ou `deb`. Les mises à jour se
font par le même canal. L'installation d'un canal par-dessus un autre est refusée, avec l'indication
de la procédure : désinstallation préalable, ou mise à jour par le canal en place. Une machine
installée par un kit antérieur à ce mécanisme est signalée `inconnu` ; elle se met à jour par un kit.

### Fin d'installation

L'installation crée la forge, provisionne comptes et équipes, génère les jetons, démarre les
services ou le conteneur, enregistre le runner CI, puis affiche les points d'entrée. Elle est
idempotente : relancée, elle converge vers le même état.

```
banc PRET
  forge     : http://192.168.1.42:21000   (humain lcars / toto32toto32)
  deck      : http://192.168.1.42:20999
  conteneur : lcars-nuit-lcars-1   ssh 192.168.1.42:2222
  runner    : ENREGISTRE (1 vu(s) par la forge)
  ecoute    : 0.0.0.0 — OUVERT SUR LE RESEAU. …
  destruire : bench-down.sh --project lcars-nuit
```

L'adresse affichée est celle de la machine, détectée au démarrage. Tout autre verdict que
`banc PRET` nomme l'élément manquant.

---

## Entrer

Deux comptes existent, et ils ne sont **pas** interchangeables.

| compte | mot de passe | ce que c'est |
|---|---|---|
| **`lcars`** | `toto32toto32` | **l'humain de la flotte.** C'est celui que tu utilises. Il possède les projets, parle aux agents, et a une console sur le tableau de bord. |
| **`admiral`** | `toto1234` | **l'administrateur système.** Il possède le conteneur (sudo) et a fondé la forge. Il fait tourner la machine ; il ne fait pas tourner la flotte — démarrer une flotte sous lui est refusé par construction. |

⚠ **Ces mots de passe sont des défauts de test, écrits en clair dans ce README — et le banc écoute
sur `0.0.0.0`, donc tout ce qui atteint ta machine l'atteint.** C'est délibéré : l'intérêt de cette
beta, c'est qu'un ami sur le même réseau ouvre le tableau de bord depuis son propre portable. C'est
un choix pour un réseau de confiance, et rien d'autre. Pour le refermer sur cette machine seule :

```bash
bash install.sh --container --bench -- --bind 127.0.0.1
```

⚠ Ce qui suit `--` part **verbatim** au fournisseur de banc : c'est là que vivent `--bind`,
`--advertise`, `--project` et les ports.

Si l'adresse annoncée est fausse (plusieurs interfaces, un nom DNS, un reverse-proxy), nomme-la :
`--advertise <ip-ou-nom>`. Les ports se déplacent pareil — `--forge-port`, `--deck-port`.

### Trois portes

**Le tableau de bord** — `http://<ton-ip>:20999`

L'entrée principale. On s'y connecte par la forge (le bouton est sur la page d'accueil). Tu y as ton
propre terminal web, l'état de ta flotte, et la liste des agents qui tournent.

**La forge** — `http://<ton-ip>:21000`

Un Gitea complet. Tes projets, leurs pull requests, leurs runs de CI. Connexion en `lcars`.

**SSH** — `ssh lcars@<ton-ip> -p 2222`

Le même conteneur, dans un vrai terminal. De là :

```bash
fleet start        # démarrer la flotte
fleet status       # ce qu'elle fait
lcars catalogue list  # quels catalogues métier ce conteneur porte
```

### Installer le catalogue de démo

À la sortie du conteneur tu as un catalogue, `fleet`. Un second, `web-demo`, attend sur la forge sous
forme de dépôt — `catalogue list` l'affiche en `disponible`. L'installer tient en une commande :

```bash
lcars catalogue install web-demo
```

Ça crée son organisation sur la forge, ses comptes de rôle, ses teams, et pose son matériel sur le
conteneur. C'est un geste **admin** : `lcars` peut le jouer parce que ce banc en fait un admin de la
forge, et le runtime lit ce fait sur la forge plutôt que dans un drapeau local.

Une fois installé, ses cartes apparaissent à côté de celles de `fleet` quand un agent te propose le
catalogue d'un nouveau projet — et le catalogue d'un projet est fixé pour sa vie, donc la question
t'est posée au lieu d'être devinée.

---

## Ton premier projet

Tout passe par une conversation avec un agent — tu ne remplis pas de formulaire.

1. Ouvre le tableau de bord et démarre ta console.
2. Lance `fleet start`, puis `claude` — tu parles au guichet de la flotte.
3. Demande-lui un projet. Il te montre les **cartes** que portent les catalogues installés (une
   carte est un workflow : qui écrit, qui relit, si la CI doit être verte avant de merger), te
   laisse en choisir une, et crée le dépôt, les branches et les dossiers de travail.
4. Ouvre un ticket sur ce projet. La flotte le prend, spawn les agents que la carte nomme, et le
   travail arrive en pull request, jugée par les relecteurs que cette carte déclare.

Le runner est déjà enregistré, donc un projet dont la carte exige une CI verte l'obtient vraiment.

---

## Désinstallation

Rail conteneur, avec la commande affichée sur la ligne `destruire :` :

```bash
deploy/docker/bench/bench-down.sh --project <projet>
docker builder prune -af
```

Rail poste :

```bash
bash install.sh --uninstall -- --yes          # apt purge sous canal deb, provision uninstall sinon
sudo apt purge 'lcars*' && sudo apt autoremove --purge    # équivalent, sous canal deb
```

Sont retirés : services, comptes de service, `/opt/lcars`, `/etc/lcars`, forge locale et runner.
`~/.lcars` et les comptes humains de la forge sont conservés ; `--humans` les retire.

---

## Ce que cette beta ne fait PAS

Dit franchement, parce qu'un outil qui cache ses bords fait perdre du temps :

- **Ce n'est pas un déploiement de production.** La forge qu'elle crée est jetable et vit sur ton
  réseau. Brancher LCARS sur une forge que tu fais déjà tourner est un autre chemin, et il n'est pas
  dans ce paquet.
- **Les mots de passe ci-dessus sont des défauts fixes.** Bien pour un essai sur un réseau de
  confiance, faux partout ailleurs.
- **Rien n'est supprimé pour toi.** Projets, dépôts et conteneurs restent jusqu'à ce que tu les
  retires.
- **Les agents coûtent des tokens.** Ce sont de vrais processus Claude Code sur ton compte. Une
  flotte laissée tourner continue de travailler.
- **Ça a été exercé sur Debian/Ubuntu avec Docker.** Les autres distributions ne sont pas testées
  plutôt que non supportées — si ça casse, les messages d'échec sont écrits pour dire où.

---

## Si quelque chose va de travers

La pile est faite pour dire ce qui manque plutôt que pour avoir l'air en bonne santé :

```bash
deploy/container -p lcars-nuit doctor   # ce qui est provisionné, ce qui a dérivé, et le geste qui répare
deploy/container -p lcars-nuit logs     # le récit que le conteneur fait de son propre boot
```

⚠ `-p lcars-nuit` n'est pas optionnel ici. `deploy/container` vise par défaut un projet appelé `lcars`, et
le banc ci-dessus en crée un appelé `lcars-nuit` — sans le drapeau, tu interrogerais un déploiement
qui n'existe pas. (`install.sh --container --bench -- --project <nom>` le change ; la ligne de destruction qu'il imprime
porte toujours le bon.)

**Une PR bloquée par sa CI se répare depuis la PR.** Le runner joue le `ci.yml` du commit testé —
la tête de ta branche —, donc corriger ce fichier là et repousser débloque la PR elle-même. Il n'y a
rien à merger d'abord.

Le fournisseur de banc imprime son bloc de verdict même quand il échoue — les détails sont ce qu'il te faut
pour réparer, donc il ne les avale jamais.

---

## Ce qu'il y a dedans

- **Un conteneur** — Debian, qui fait tourner le runtime de la flotte (Elixir/OTP) et un
  tableau de bord web.
- **Une forge** — Gitea, dans son propre conteneur, avec les organisations, teams et comptes machine
  dont la flotte a besoin.
- **Un runner** — Gitea Actions, enregistré, pour que la CI soit réelle.
- **Des catalogues** — les définitions métier : quels rôles existent, quelles cartes de workflow ils
  servent, quel est le system prompt de chaque agent. Un catalogue est de la **donnée, pas du code**.
  `fleet` est livré dans le runtime et toujours là ; `web-demo` est déposé sur la forge et s'installe
  en un geste (cf. *Installer le catalogue de démo* plus haut).
- **Des agents** — des processus Claude Code, chacun dans une sandbox qui monte exactement ce dont
  son rôle a besoin.

---

## Licence

Voir [`LICENSE`](LICENSE) et [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
