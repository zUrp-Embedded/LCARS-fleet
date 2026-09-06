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

## Ce qu'il te faut

Quatre choses, et ta distribution a presque certainement les trois premières :

| | pourquoi |
|---|---|
| **docker** | tout tourne en conteneurs — le conteneur LCARS, la forge, le runner. Sous Windows c'est **Docker Desktop** ; sur un Ubuntu natif, le paquet `lcars` le tire lui-même |
| **curl** | la porte télécharge la version, et l'amorçage parle à la forge en HTTP |
| **python3** | il lit les réponses JSON de la forge |
| **WSL 2** | sous Windows seulement — WSL 1 n'a pas de namespaces, donc pas de pods |

Rien d'autre. **Pas d'Elixir, pas d'Erlang, aucun toolchain sur ta machine** : une version est
**pré-compilée** — un kit, huit paquets Debian, une image — et la porte pose le résultat. Le
toolchain n'est nécessaire que si tu choisis de compiler depuis les sources (voir plus bas).

Il te faut aussi un **compte Anthropic** : les agents sont des processus Claude Code. Si tu utilises
déjà `claude` sur cette machine, tes credentials sont repris automatiquement depuis
`~/.claude/.credentials.json`.

**Pendant l'installation il faut du réseau** : la forge qui publie la version (la Release et ses
artefacts), Docker Hub (images de base) et `claude.ai` (le binaire de l'agent). Un hoquet sur l'un
des trois fait échouer l'installation — bruyamment, sans laisser une machine à moitié posée.

---

## Installer

Une version se pose de **trois façons**. Les trois passent par la même porte, `install.sh`, et
posent le même produit ; ce qui change, c'est d'où il vient.

### 1. La porte, depuis la Release — le geste normal

```bash
# LCARS dans ce système (WSL 2 ou Ubuntu), avec sa forge et son runner CI :
curl --proto '=https' --tlsv1.2 -fsSL https://<forge>/<owner>/lcars-fleet/releases/download/<version>/install.sh | bash -s -- --workstation --bench

# LCARS dans un conteneur, rien hors de ton clone et de docker :
curl --proto '=https' --tlsv1.2 -fsSL https://<forge>/<owner>/lcars-fleet/releases/download/<version>/install.sh | bash -s -- --container --bench
```

L'URL est celle de la **Release** de la version, sur la forge qui la publie : chaque version a sa
porte, et cette porte ne connaît que *ses* artefacts. Elle les télécharge dans
`~/.lcars/kits/<version>/`, vérifie chacun contre les sha256 **écrits en dur dans la porte** (un
écart efface le fichier, rien n'est posé), dit l'état de la signature minisign (vérifiée si l'outil
est là, « NON vérifiée (sha256 seul) » sinon — jamais tue), annonce ce que ça prend, te demande, puis
délègue :

- **`--workstation`** : sous Debian/Ubuntu, les paquets `.deb` de la version, posés par
  `sudo apt-get install` — c'est le seul `sudo`, et il te sera demandé. Le paquet provisionne
  lui-même à l'installation (comptes, groupes, `/opt/lcars`, services). Sous WSL 2 la porte ajoute
  `lcars-docker-desktop`, le paquet vide qui dit « le daemon, c'est Docker Desktop ». `--tar` prend
  le kit plutôt que les `.deb`.
- **`--container`** : l'image de la version, et rien d'autre sur ta machine. ⚠ Sous WSL elle
  demandera `sudo` pour parler au daemon docker — sa socket appartient à root.
- **`--bench`** dit « et fabrique-moi les annexes » : forge jetable, runner CI, humain de
  démonstration. Sans lui, la porte attend une forge existante (`FORGE_BASE_URL`).

`--dry-run` va jusqu'au bilan et **dit** ce qui serait fait — artefacts, sha256 attendus, commande
du rail — sans rien télécharger ni poser. `--check` sonde seulement.

### 2. Les paquets Debian, par apt

La même version est aussi un dépôt apt, sur la forge. Deux lignes pour l'ancrer, une pour poser :

```bash
sudo curl -fsSL https://<forge>/api/packages/<owner>/debian/repository.key -o /etc/apt/keyrings/lcars-<owner>.asc
echo "deb [signed-by=/etc/apt/keyrings/lcars-<owner>.asc] https://<forge>/api/packages/<owner>/debian <distribution> main" | sudo tee /etc/apt/sources.list.d/lcars.list
sudo apt update

sudo apt install lcars-demo                          # Ubuntu natif : poste + forge + runner + humain de démo
sudo apt install lcars-docker-desktop lcars-demo     # WSL 2 avec Docker Desktop : LES DEUX, toujours
```

⚠ Sous WSL, `lcars-demo` seul laisse apt choisir `docker.io` — un second daemon à côté de Docker
Desktop, et sa socket écrasée. Le produit le **refuse** en nommant le geste ; épargne-toi le détour.

Les paquets se composent : `lcars` (le socle), `lcars-workstation` (LCARS dans ce système),
`lcars-container` (LCARS en conteneur), `lcars-forge` (une forge sur ce poste), `lcars-bench`
(le banc : runner CI, humain de démo), `lcars-demo` (tout ce qui précède), `lcars-tofu` (l'outil
d'infrastructure) et `lcars-docker-desktop` (vide, WSL). Hors ligne, les mêmes `.deb` sont des
assets de la Release : `sudo apt install ./lcars-tofu_*.deb ./lcars_*.deb ./lcars-workstation_*.deb …`
dans cet ordre.

Après la pose, `deploy/provision doctor` (dans `/opt/lcars`) dit l'état de la machine, module par
module, sans rien toucher.

### 3. Depuis les sources — pour lire, déboguer, contribuer

```bash
git clone --branch <version> https://<forge>/<owner>/lcars-fleet.git && cd lcars-fleet
bash install.sh --workstation --bench          # ou --container --bench
```

La même porte, lancée dans un checkout, continue **dedans** : c'est la provenance « source », et
elle le dit (HEAD compris). Pipée, `--source [<ref>]` fait le clone au tag de la porte, jamais
`main` sans le dire. Sur le rail poste, ce chemin **compile** : il te faut Elixir/OTP aux planchers
que le provisionnement déclare. Sur le rail conteneur, non : le runtime est compilé dans un
conteneur de build jetable, et seul le résultat est gardé — deux images sortent du même
Dockerfile, celle que tu fais tourner et le jumeau toolchain que son runner CI sert.

### Un canal par machine

Une machine se souvient de **qui** l'a posée : `source`, `kit` ou `deb` (`/etc/lcars/channel`).
Une mise à jour se fait par le même canal ; poser un canal sur un autre est **refusé**, et le refus
nomme le geste — désinstaller d'abord, ou reprendre le même canal. Une machine posée par un kit
d'avant les canaux est dite « inconnue » : elle se met à jour par un kit, jamais par un `.deb`.

Désinstaller passe par la porte aussi : `bash install.sh --uninstall -- --yes` — `apt purge` des
paquets sous `deb`, `provision uninstall` sinon ; le conteneur se défait par `deploy/container
reset`. Sous `deb`, `sudo apt purge 'lcars*'` fait le même travail et ne laisse rien derrière lui
hors ce qu'un paquet du système garde en propre.

### Ce que l'installation imprime

L'installation crée une forge git, l'attend, provisionne les comptes et les teams, minte les jetons,
démarre le conteneur ou les services, enregistre un runner CI, et imprime ce qu'elle a monté. Elle
est **rejouable** : relancée, elle converge au lieu de dupliquer.

Quand c'est fini, elle imprime un bloc de ce genre — ce sont tes points d'entrée :

```
banc PRET
  forge     : http://192.168.1.42:21000   (humain lcars / toto32toto32)
  deck      : http://192.168.1.42:20999
  conteneur : lcars-nuit-lcars-1   ssh 192.168.1.42:2222
  runner    : ENREGISTRE (1 vu(s) par la forge)
  ecoute    : 0.0.0.0 — OUVERT SUR LE RESEAU. …
  destruire : bench-down.sh --project lcars-nuit
```

L'adresse imprimée est **celle de ta machine**, détectée au démarrage : c'est celle-là qu'on tape,
d'ici ou depuis une autre machine du même réseau. Les ports se choisissent à la porte :
`--port-forge`, `--port-deck`, `--port-ssh` (un banc par port — les WSL d'une même machine
partagent un daemon docker).

Si elle dit autre chose que `banc PRET`, elle nomme ce qui manque. Elle n'annonce jamais un succès
sur une pile qu'elle n'a pas pu vérifier.

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

## Détruire

**Rail conteneur** — ce que la ligne `destruire :` du bloc `banc PRET` t'a imprimé :

```bash
deploy/docker/bench/bench-down.sh --project lcars-nuit
docker builder prune -af          # puis, pour récupérer l'espace de build
```

Retire le conteneur, la forge, le runner et leurs volumes. Rien n'a jamais été écrit hors de docker.

**Rail poste** — la porte, ou apt, au choix ; les deux font le même travail :

```bash
bash install.sh --uninstall -- --yes            # apt purge sous « deb », provision uninstall sinon
sudo apt purge 'lcars*' && sudo apt autoremove --purge
```

Services, comptes de service, `/opt/lcars`, `/etc/lcars`, la forge du poste et son runner s'en
vont. Restent ce que tu as mis dans ton `~/.lcars` et les humains de la forge (`--humans` les
retire aussi). Ta machine est revenue là où elle était — c'est mesuré, pas promis : le relevé
avant/après est la règle du chantier qui a produit ces paquets.

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
