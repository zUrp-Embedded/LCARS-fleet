# fleet/deploy — machine nue → `fleet_v2 start`

**Date** : 2026-07-05
**Dernière révision** : 2026-08-07
**Statut** : **PROTO PARKÉ** (recadrage user 2026-07-06 : v1 est la brique qui marche, aucun client v2
tant qu'on n'a rien à installer). ⚠ 3 revues hostiles 2026-07-06 ont trouvé des bugs RÉELS **non
corrigés** — le code MENT vert sur certains échecs (verdict-sur-échec-apt, `runuser` absent en Docker).
NE PAS s'en servir en l'état. Le nord voulu = un déployeur GÉNÉRIQUE catalogue-driven, pas ce code
hardcodé LCARS. Décision + analyse + bugs : `work/beyond_#5/#5.3/drdree/ADR-install-compile-release-v2.md`.
**Référencé par** : `install.sh` (racine), `docker.sh` (racine)

Le provisioning du runtime v2 : amène une machine nue (WSL2, Docker, Linux natif) à l'état où
un humain lance `fleet_v2 start` et la chaîne complète fonctionne. A remplacé l'arbre v1 `fleet/provisioning/`, retiré le 2026-08-06 (récupérable par `git show v1-excommunication-base:`)
(v1, archivée dans ses feuilles `v1/` — elle provisionnait la fleet bash v1, users-par-rôle,
morte avec le modèle).

## L'idée en 4 lois

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

## Usage

```bash
sudo fleet/deploy/provision apply            # converge tout (substrat auto-détecté)
fleet/deploy/provision doctor                # sonde read-only — LA sonde du nuke-drill
sudo fleet/deploy/provision update           # la jambe update du triangle (voir ci-dessous)
fleet/deploy/provision list                  # les modules retenus pour ce substrat
sudo fleet/deploy/provision apply --only 60  # un seul module
```

**`update`** (héritier de `fleet-update.sh` v1) : pull `--ff-only` du checkout source, APRÈS
vérification d'autorité — le remote DOIT matcher `PROV_EXPECTED_REPO` (déclaré, jamais deviné ;
sans lui, aucun pull). Puis re-exec du runner FRAÎCHEMENT pullé en `apply` complet (jamais de
`--only` : un update partiel est irreprésentable). Déjà à jour → re-converge quand même.
Le rebuild/redeploy effectif est décidé par `60-deploy` (sha déployé vs HEAD).

Codes retour : `apply` 0=convergé 1=échec · `doctor` 0=conforme 1=drift 2=erreur-de-sonde.
`doctor --porcelain` → `MODULE=OK|DRIFT|ERROR`, une ligne par module (machine-lisible).

Données (env ou `--env FILE`, défauts dans `lib/provision-lib.sh` — une seule définition) :
`PROV_PREFIX` (/local/LCARS_v2 — le défaut d'etc/install.sh, SSoT etc/README.md) · `PROV_FLEET_GROUP` (fleet) · `PROV_TOKENS_DIR` (/home/private) ·
`PROV_FORGE_URL` (=FORGE_BASE_URL) · `PROV_FORGE_SEED_FILE` (seed bootstrap tofu → handoff A4) ·
`PROV_PASSWORDS_FILE` (livrable A4, 0600 opérateur) · `PROV_HUMAN` (défaut : l'appelant) ·
`PROV_WINDOWS_USER` (ready-room WSL, optionnelle) · pins toolchain (`PROV_ELIXIR_*`).

## Modules (`modules.d/NN-*.sh`)

Chaque module est un PROCESSUS exécuté (`<module> check|apply`), qui déclare son terrain en tête
sur DEUX axes (D6 : « qui applique » ≠ « ce qui doit être vrai ») — `# APPLY-ON:` (où les
mutations tournent), `# CHECK-ON:` (où l'état-cible doit tenir), `# NEEDS:` — greppable, filtré
par le runner. Ordre = préfixe numérique. En apply, un module CHECK-ON-retenu hors APPLY-ON
tourne en check : son drift est un ÉCHEC (rien sur place ne peut converger — rebuild l'image).

| Module | APPLY-ON | CHECK-ON | Pose |
|---|---|---|---|
| 00-preflight | any | any | planchers OS/bash/arch/RAM/disque/WSL2/userns — sondes actionnables, zéro mutation |
| 10-packages | wsl linux | any | tmux, bubblewrap, git, curl, jq, unzip + **sonde bwrap RÉELLE** (un sandbox tourne sous l'humain) |
| 15-toolchain | wsl linux | wsl linux | Erlang apt (plancher OTP) + Elixir précompilé PINNÉ sha256 (/opt, symlinks) — build only, jamais dans le conteneur runtime |
| 20-groups | any | any | groupe `fleet` + membership de l'humain (AUCUN user créé : le modèle est per-humain) |
| 25-directories | any | any | `/local` 0755 root + `/home/private` 0750 root:fleet — c'est tout |
| 30-wsl | wsl | wsl | lockdown C: (`/etc/wsl.conf` possédé entier, écrit EN DERNIER), purge snapd, masque gpg-agent, ready-room optionnelle |
| 40-claude-bin | any | any | binaire claude PER-HUMAIN (~/.local/bin) via installer officiel, staging jetable — frontière vendor N1 |
| 50-forge | any | any | SONDE de la structure (comptes — territoire OpenTofu, instruct-only) + tokens A4 (`etc/provision-role-tokens.sh`), passwords-file dérivé du seed bootstrap |
| 60-deploy | wsl linux | any | orchestre `fleet/etc/install.sh` (l'autorité) : unlock → build as-humain → verrou RO root:fleet → câblage `/usr/local/bin` |
| 70-human | any | any | ~/.lcars + ~/pods 0700, `fleet_v2.env` SEED-ONCE, sondes credentials (instruct-only, jamais posées) |

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
- **Runner CI : sidecar compose, pas un module** (arbitrage user 2026-07-30 — embarqué avec
  le profil `forge` : act_runner officiel pinné, label `elixir` = la même image que le stage
  build). Son enregistrement est un geste bootstrap (`docker.sh forge-bootstrap`), hors du
  chemin machine-nue→fleet.
- **Pas de gestion GitHub** (`gh`, branch-protection…) : la forge du triangle est Gitea.

## Dette de guerre encaissée (payée par v0→v1, à ne JAMAIS repayer)

snapd casse `systemd --user` sous WSL → purgé · gpg-agent-ssh.socket race au shutdown WSL2 →
masqué · wsl.conf ne prend effet qu'après `wsl --shutdown` + NOUVEL onglet → dit par la sonde ·
flag drvfs `metadata` obligatoire pour les perms Unix sur NTFS · `usermod -aG` inactif jusqu'au
relogin → dit (`sg fleet -c`) · le lockdown C: se sonde en RÉEL (touch-test), jamais en lisant
la config.
