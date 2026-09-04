# deploy — machine nue → `fleet_v2 start`

**Date** : 2026-07-05
**Dernière révision** : 2026-08-26 (5ᵉ loi : la frontière est l'API docker — reconstituée depuis
quatre gestes qui lui obéissaient déjà, et la soustraction assumée qui en découle)
**Statut** : **EN SERVICE**, et le nord voulu reste un déployeur GÉNÉRIQUE catalogue-driven plutôt que
ce code hardcodé LCARS — c'est une direction de conception, pas une interdiction d'usage. Analyse et
ADR : `work/beyond_#5/#5.3/drdree/ADR-install-compile-release-v2.md`.

⚠ **CETTE LIGNE DISAIT « PROTO PARKÉ … NE PAS s'en servir en l'état », et le conteneur s'en sert à
CHAQUE DÉMARRAGE** — `entrypoint.sh` lance `provision apply --substrate docker` au boot, et le banc
entier repose dessus. Un lecteur avait donc, avec les seules sources qu'on lui donnait, une
contradiction insoluble : le README interdit, le runtime exécute. Les deux bugs qu'il nommait sont
FERMÉS et épinglés :
- *verdict-sur-échec-apt* — `apt_ensure` propage l'échec (`|| return 1`) **et re-sonde chaque paquet
  au `dpkg -s` après l'install**, `p_fail` sur tout absent ; `provision_lib.bats` B1 tient la
  propriété sous le titre « the green lie is dead ».
- *`runuser` absent en Docker* — le Dockerfile installe `util-linux-extra` en nommant la panne :
  « sans ce paquet l'entrypoint casse au premier module humain ».

Et `deploy/tests/*.bats` sont joués par `deploy/gate.sh`, la porte de l'installeur — qui tient aussi
son plancher shellcheck et ses en-têtes déclaratifs. `mix gate` ne lit plus `deploy/` (⚖ user
2026-09-04 : « chacun joue son gate, on les split »).
**Référencé par** : `install.sh` (racine)

## Ce que cette couche porte, et ce qu'elle ne porte plus

`deploy/` porte L'INSTALLATION — et depuis le 2026-08-25, rien d'autre.

⚠ **`deploy/docker/` A PORTE LA SOURCE CANONIQUE DE TOUT LE CODE PRIVILEGIE DE LA MACHINE**, sous
le nom de l'outil qui le TRANSPORTE. Douze fichiers — l'executeur de catalogue (root, socket,
autorite forge), le convergeur d'humains (root, `useradd`), le convergeur d'outillage (root, via
le sudoers etroit), les consoles et le deck. Sur le rail poste il n'y a PAS de docker pour eux :
un module les copie, systemd les tient, ils tournent nativement. Un lecteur qui cherchait le code
privilegie de cette machine ne regardait pas dans un dossier appele `docker`.

Ils vivent en **`fleet/services/`**, nomme comme le module qui les pose et les demarre
(`modules.d/64-services.sh`) : qui trouve l'un trouve l'autre. Deux temoins tiennent la
frontiere (`tests/services_dir.bats`) — `deploy/docker/` ne reprend aucun auxiliaire, et tout
fichier de `services/` est pose quelque part.

Ce qui reste sous `deploy/docker/` est du packaging conteneur : `Dockerfile`, `entrypoint.sh`
(PID 1 du conteneur, il n'existe que la), les cinq compose, le seccomp, `forge-runner.sh`
(appele pendant l'apply, jamais apres) et `bench/`.

un humain lance `fleet_v2 start` et la chaîne complète fonctionne. A remplacé l'arbre v1 `fleet/provisioning/`, retiré le 2026-08-06 (récupérable par `git show v1-excommunication-base:`)
(v1, archivée dans ses feuilles `v1/` — elle provisionnait la fleet bash v1, users-par-rôle,
morte avec le modèle).

## L'idée en 5 lois

1. **L'état, c'est le système.** Aucune sentinelle (`.install_ok`…), aucun fichier d'état :
   chaque module SONDE le réel (`check`) et le converge (`apply`). Re-lancer est toujours sûr,
   le doctor dit toujours où on en est. Après le reboot WSL, on relance le même apply.
2. **Une seule vérité par fait.** Le doctor N'EST PAS un autre code que l'apply : même sonde.
   La sonde des tokens EST le `--check` du script A4. La sonde du lockdown C: est UN touch-test,
   défini une fois.
3. **Verdict réel, échec verbeux.** Tout état est re-sondé APRÈS l'action ; un succès est une
   ligne, un échec dump tout. Rien n'est étouffé en `2>/dev/null`.
4. **Atomicité partout.** Tout fichier est écrit tmp-même-dossier puis `mv`. Un crash ne laisse
   jamais un fichier tronqué ni un état à moitié armé (wsl.conf s'écrit EN DERNIER de son module).
5. **La frontière est l'API docker.** LCARS agit à partir d'elle et au-dessus : conteneurs,
   volumes, réseaux, et ce qui vit dedans. En dessous — daemon, paquets, kernel, réseau de
   l'hôte — il est INVITÉ, et un invité ne pose rien. UN seul acte le rend propriétaire, et cet
   acte a un nom : `LCARS_ALLOW_ANY_HOST` / `/etc/lcars/host-consent`. C'est le rail POSTE, et
   lui seul.

   Quatre gestes la portent, et c'est d'eux qu'elle se lit :
   - le bandeau du rail boîte promet « pas de paquet, pas d'utilisateur, pas de groupe, rien dans
     /etc ni /usr » — `docker-ce` le contredirait mot pour mot (dépôt tiers, `/etc/apt/keyrings`,
     `sources.list.d`, unité systemd, groupe) ;
   - la même branche s'interdit l'`exec sudo`, sans quoi l'image sort bâtie en root : elle ne peut
     pas poser un paquet ;
   - `10-packages.sh` pose `docker-ce` sur le substrat `linux` seul, gardé par
     `LCARS_ALLOW_ANY_HOST` — le rail poste, celui à qui la machine a été donnée ;
   - `00-preflight.sh` refuse le rail poste hors WSL sans ce drapeau : « on ne le lâche pas sur une
     machine dont on ne sait pas si c'est celle de quelqu'un ».

## Usage

```bash
sudo deploy/provision apply            # converge tout (substrat auto-détecté)
deploy/provision doctor                # sonde read-only — LA sonde du nuke-drill
sudo deploy/provision update           # la jambe update du triangle (voir ci-dessous)
deploy/provision list                  # les modules retenus pour ce substrat
sudo deploy/provision apply --only 60  # un seul module
```

**Le jumeau : `deploy/box`.** `provision` provisionne un HÔTE (paquets, groupes, `/opt/lcars`,
`wsl.conf`) ; `box` pilote une BOÎTE (image, conteneur, volumes, forge de l'opérateur). Mêmes verbes
documentés en tête, mêmes codes retour, même place dans l'arbre — qui sait lire l'un sait lire
l'autre. Les douze verbes (`build up doctor shell logs down reset source-push config forge-check
forge-apply runner-token`) s'appellent par `deploy/box <verbe>` à la racine, qui détecte, refuse en
nommant ce qui manque, et `exec` le délégué avec l'argv verbatim.

**La porte publique des deux rails est `install.sh`** (racine) : elle détecte ce que la machine
PERMET, demande ce que l'opérateur VEUT quand les deux sont possibles, et délègue — `--workstation`
vers `provision apply`, `--box` vers `box`, `--bench` vers le fournisseur de banc. Ce qui suit
`--` part verbatim au délégué de la branche.

**`update`** (héritier de `fleet-update.sh` v1) : pull `--ff-only` du checkout source, APRÈS
vérification d'autorité — le remote, normalisé en `host/owner/repo`, doit être **exactement égal** à
`PROV_EXPECTED_REPO` (déclaré, jamais deviné ; sans lui, aucun pull). ⚠ **L'hôte fait partie de
l'autorité et la forme `owner/repo` est REFUSÉE** : la comparaison était une sous-chaîne, donc
`https://hôte-attaquant/attaquant/fleet/lcars-malware.git` satisfaisait `fleet/lcars` — et le runner
exécutait ce code en root (6-109). Puis re-exec du runner FRAÎCHEMENT pullé en `apply` complet (jamais de
`--only` : un update partiel est irreprésentable). Déjà à jour → re-converge quand même.
Le rebuild/redeploy effectif est décidé par `60-deploy` (sha déployé vs HEAD).

Codes retour : `apply` 0=convergé 1=échec · `doctor` 0=conforme 1=drift 2=erreur-de-sonde.
`doctor --porcelain` → `MODULE=OK|DRIFT|ERROR`, une ligne par module (machine-lisible).

Données (env ou `--env FILE`, défauts dans `lib/provision-lib.sh` — une seule définition) :
`PROV_PREFIX` (/opt/lcars/runtime — le défaut d'etc/deploy-release.sh, SSoT etc/README.md) · `PROV_FLEET_GROUP` (fleet) · `PROV_TOKENS_DIR` (/opt/lcars/var/tokens) ·
`PROV_FORGE_URL` (=FORGE_BASE_URL) · `PROV_FORGE_SEED_FILE` (seed bootstrap tofu → handoff A4) ·
`PROV_PASSWORDS_FILE` (livrable A4, 0600 opérateur) · `PROV_HUMAN` (défaut : l'appelant) ·
planchers toolchain (`PROV_ELIXIR_OTP_MAJOR`, `PROV_ELIXIR_MIN` — la distro sert, le rail vérifie).

## Modules (`modules.d/NN-*.sh`)

Chaque module est un PROCESSUS exécuté (`<module> check|apply`), qui déclare son terrain en tête
sur DEUX axes (D6 : « qui applique » ≠ « ce qui doit être vrai ») — `# APPLY-ON:` (où les
mutations tournent), `# CHECK-ON:` (où l'état-cible doit tenir) — greppables, filtrés par le
runner ; plus `# NEEDS: root|human`, l'identité SOUS LAQUELLE le module est joué, que le runner
pose UNE FOIS au dispatch (le corps du module ne dés-escalade pas ligne à ligne).
Ordre = préfixe numérique. En apply, un module CHECK-ON-retenu hors APPLY-ON
tourne en check : son drift est un ÉCHEC (rien sur place ne peut converger — rebuild l'image).

| Module | APPLY-ON | CHECK-ON | Pose |
|---|---|---|---|
| 00-preflight | any | any | planchers OS/bash/arch/RAM/disque/WSL2/userns — sondes actionnables, zéro mutation |
| 05-host-consent | linux | linux | le consentement de l'opérateur à modifier CETTE machine, rendu DURABLE (`/etc/lcars/host-consent`) — seconde source de 00-preflight, parce qu'un daemon ou un convergeur n'a pas l'environnement de celui qui a tapé la commande |
| 10-packages | wsl linux | any | tmux, bubblewrap, git, curl, jq, unzip + **sonde bwrap RÉELLE** (un sandbox tourne sous l'humain) |
| 15-toolchain | wsl linux | wsl linux | Erlang apt (plancher OTP) + Elixir précompilé PINNÉ sha256 (/opt, symlinks) — build only, jamais dans le conteneur runtime |
| 16-node | wsl linux | any | Node précompilé PINNÉ — le toolchain qui bâtit la DOC du produit |
| 20-groups | any | any | groupe `fleet` + membership de l'humain (AUCUN user créé : le modèle est per-humain) |
| 21-service-accounts | any | any | les comptes SYSTEME des services de la machine — aujourd'hui `lcars-authority`, qui DETIENT les secrets de forge et n'a AUCUN privilège noyau (l'inverse exact du convergeur, qui a le privilège et ne détient rien). Membre de `fleet` pour TRAVERSER `/opt/lcars/runtime`, jamais pour décider : l'adminité se demande à la forge. Rang 21 et pas moins : le compte a besoin du groupe que 20 vient de créer |
| 22-fleet-human | wsl linux | wsl linux | ATTESTE l'humain de fleet du poste : un compte unix qui n'est PAS le siège (GUARD B interdit à l'uid 1000 de lancer une fleet). Il ne crée rien et ne nomme rien — la forge sème le compte (48), le convergeur le matérialise (64), et son nom se demande à `services/forge-gestures.sh builtin-human`. Il porte la seule assertion d'ADHÉSION AU GROUPE du rail : `fleet_humans` compte les uid, pas les droits |
| 25-directories | any | any | `/opt/lcars` 0755 root + `/opt/lcars/var/tokens` 0710 lcars-authority:fleet — c'est tout |
| 26-store | docker | docker | les MODES du magasin d'outillage sur les quatre volumes externes — PRESENT est un magasin ACTIF : un répertoire vide se bind quand même en `ro` dans chaque pod |
| 30-wsl | wsl | wsl | lockdown C: (`/etc/wsl.conf` possédé entier, écrit EN DERNIER), purge snapd, masque gpg-agent |
| 40-claude-bin | any | any | binaire claude PER-HUMAIN (~/.local/bin) via l'installeur officiel joué TEL QUEL — deux gestes (download, puis run), aucune machinerie qui double la sienne — frontière vendor N1 |
| 44-media | wsl linux | any | les médias partagés (avatars, favicon) — le jumeau FICHIER du trou ISO des paquets |
| 45-catalogues | any | any | le matériel des catalogues INSTALLÉS, convergé depuis la forge — « installé » est un fait de forge, ce module est ce qui le rend vrai sur le disque |
| 45-sudoers-toolchain | any | any | les quatre ancrages système du domaine admiral (sudoers étroit, état conteneur, projection du login du siège, skill du siège). Rang 45 et pas moins : un NOPASSWD posé avant 20-groups viserait un groupe inexistant |
| 46-tofu | wsl linux | any | OpenTofu + son miroir de providers SUR LA MACHINE — la structure de forge n'a plus besoin d'une image (1,18 Go et dix minutes bâtis pour 124 Mo d'outil jamais démarré) |
| 48-forge-host | wsl linux | wsl linux | **la forge du POSTE DE TRAVAIL** : conteneur Gitea + admin + jeton master + seed + structure (run transitoire de l'image, porte `forge-apply`). Un LCARS installé nativement a besoin d'une forge ; sans ce module, 50-forge et 55-deck-oidc restent en dérive et leurs consignes nomment la boîte |
| 49-forge-runner | wsl linux | wsl linux | **le runner CI de la forge du poste** : enrôle un runner sur le réseau de la forge via `docker/forge-runner.sh`. Sorti de 48 le 2026-08-27 — son état était noyé dans le verdict de la forge, et « ma CI a-t-elle une machine ? » n'avait pas de réponse propre. Une forge sans lui accepte un ticket, dépense un producteur, ouvre une PR — et la CI attend une machine qui n'existe pas |
| 50-forge | any | any | SONDE de la structure (comptes — territoire OpenTofu, instruct-only) + tokens A4 (`etc/provision-role-tokens.sh`), passwords-file dérivé du seed bootstrap |
| 52-ops-branch | any | any | la boîte aux lettres du rail d'outillage : UNE branche, sur LE dépôt ops (`LCARS_OPS_REPO`, défaut `fleet/lcars`) et sur lui seul — jamais sur un dépôt de projet |
| 55-deck-oidc | any | any | client OAuth2 du deck + `/etc/lcars/deck-oidc.json`. Les ENTRÉES (`PROV_DECK_ORIGINS`) convergent : la loopback y est semée dans ses **deux** écritures (`127.0.0.1` ET `localhost` — deux origines pour un même point d'écoute), et une liste changée repose le client |
| 60-deploy | wsl linux | any | orchestre `fleet/etc/deploy-release.sh` (l'autorité) : unlock → build as-humain → verrou RO root:fleet → câblage `/usr/local/bin` |
| 62-runtime-helpers | wsl linux | any | les auxiliaires runtime du rail poste : ce que le `COPY` du Dockerfile pose côté image (console web, landing, convergeur d'humains, convergeur de toolchain) — sur une machine native ils n'existaient nulle part, et rien ne le disait |
| 64-services | wsl linux | any | ce qui doit être DEBOUT sur un poste natif : la landing et le convergeur d'humains. Dans la boîte l'entrypoint les lance et `tini` les tient ; nativement, c'est systemd |
| 70-human | any | any | ~/.lcars + ~/pods 0700, `fleet_v2.env` SEED-ONCE, sondes credentials (instruct-only, jamais posées) |
| 75-projects | any | any | reconvergence des projets déclarés (`Fleet.Project.Onboard`) — porte du release, architecte différé quand aucune fleet ne tourne |

En **Docker**, `10/15/60` appliquent dans l'image (`docker/Dockerfile`, mêmes pins, même
install.sh) et le reste converge à l'entrypoint. L'ISO WSL↔Docker n'est plus seulement la liste
filtrée : le doctor conteneur sonde AUSSI l'état-cible bâti par l'image (paquets + bwrap réel via
`10`, verrou RO/release/câblage via `60`) — deux substrats, une seule vérité, vérifiée des deux
côtés.

## Ce que la v2 ne fait PAS (soustractions assumées)

- **Pas d'users Linux par rôle** : un pod = un process bwrap sous l'UID de l'humain ; les rôles
  sont des cap-profiles du runtime + des comptes forge.
- **Pas de yq / fleet.yaml** : la donnée est plate (env + listes), jq suffit.
- **Pas de wizard enchâssé** : les gestes d'identité (claude /login, token opérateur) sont
  sondés et instruits, jamais exécutés.
- **Pas de forge auto-installée** : elle vit à côté (sidecar compose en Docker, service externe
  sinon) ; on provisionne ce que le runtime attend d'ELLE (comptes, tokens) via son API.
- **Pas de docker auto-installé sur le rail boîte** (loi 5) : ce rail installe LCARS DANS un
  conteneur, sur une machine que l'admin sys définit et maintient comme il l'entend, avec ses
  contraintes. Le daemon y est un PRÉREQUIS qu'on NOMME, jamais un manque qu'on comble — le
  combler exigerait un dépôt tiers, `/etc/apt`, une unité systemd et une escalade, c'est-à-dire
  tout ce que le bandeau de ce rail promet de ne pas faire. Le rail POSTE le pose, lui, parce
  qu'il a reçu la machine.
  ⚖ USER 2026-08-26 : « le rail boîte, c'est pour un système destiné à la production, dans un
  environnement contrôlé, défini et maintenu par l'admin sys — de la façon qu'il souhaite, avec
  les contraintes qu'il a. Notre job, c'est pas de provisionner un serveur de prod complet en le
  promettant résilient. On demande docker pour installer LCARS dans un conteneur ; la couche
  bare-metal, c'est pas notre scope. »
  `docker_installable_here` (`install.sh`) lit donc le rail autant que le substrat : tant que
  personne n'a choisi, le préflight annonce les deux moitiés, et l'option boîte se barre quand le
  daemon manque au lieu de s'offrir.
- **Runner CI : sidecar compose, pas un module** (arbitrage user 2026-07-30 — embarqué avec
  le profil `forge` : runner Gitea officiel, label `elixir` = la même image que le stage
  build). Son enregistrement est un geste bootstrap (`deploy/docker/forge-runner.sh`
  sur un banc ; sur une forge d'opérateur, le jeton de runner est minté à la main), hors du
  chemin machine-nue→fleet.
- **Pas de gestion GitHub** (`gh`, branch-protection…) : la forge du triangle est Gitea.

## Dette de guerre encaissée (payée par v0→v1, à ne JAMAIS repayer)

snapd casse `systemd --user` sous WSL → purgé · gpg-agent-ssh.socket race au shutdown WSL2 →
masqué · wsl.conf ne prend effet qu'après `wsl --shutdown` + NOUVEL onglet → dit par la sonde ·
flag drvfs `metadata` obligatoire pour les perms Unix sur NTFS · `usermod -aG` inactif jusqu'au
relogin → dit (`sg fleet -c`) · le lockdown C: se sonde en RÉEL (touch-test), jamais en lisant
la config.
