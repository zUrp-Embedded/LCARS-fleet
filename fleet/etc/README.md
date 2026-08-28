# etc/ — run & déploiement de la fleet (chantier 16)

**Date**: 2026-05-10
**Last revised**: 2026-08-09
**Status**: human-launched model (systemd removed 2026-06-16)
**Referenced by**: `design-notes/promoted/lcars-fleet_service.md`, `STATUS-CHANTIERS.md`

Substrat de lancement. **systemd est retiré** : la fleet ne tourne plus comme un service
système `User=lcars`. Modèle (ADR-E, doctrine 2026-06-11) : **chaque humain lance SA fleet sous son
propre UID** → la BEAM tourne *as* l'humain → les pods héritent son UID (ownership/creds/isolation OS
gratis, pas de drop, pas de `/var/lib/lcars`). L'état va sous `~/.lcars/*` de chaque humain.

## Lancer la fleet — `bin/fleet_v2`

```bash
cp etc/fleet_v2.env.template ~/.lcars/fleet_v2.env   # éditer : FORGE (découverte des projets par topic, pas de repo fixe)
bin/fleet_v2 start          # démarre le BEAM sous toi, boote l'arch, attache son REPL claude
bin/fleet_v2 status         # BEAM vivant ? pods vivants ?
bin/fleet_v2 stop           # arrête la fleet
```

`fleet_v2` calcule seul les **ports per-UID** (offset déterministe → N fleets coexistent dans un même
conteneur), pose la spec MCP + les on-switches ; le reste (state / sock tmux / task-queue / audit)
défaute sous `~/.lcars/*`. Accès à l'arch : le REPL tmux (TUI) **ou** `/remote-control` (claude-desktop,
mobile). Détail config : `etc/fleet_v2.env.template`.

### Comment on « fire » la fleet selon le substrat
- **Dev (WSL/laptop)** : `fleet_v2 start` dans un terminal.
- **Cible (conteneur Docker sur le NAS)** : l'humain **SSH** dans le conteneur *en tant que lui*
  (`sshd` = le login-manager : auth + drop vers son UID, zéro privilège custom) → `fleet_v2 start`.
  Un dashboard web « start fleet » (futur) est une surface alternative, pas une dépendance.
  Pas de systemd-in-docker (pas de boîte dans la boîte). La forge tourne dans son conteneur à côté.

## Install canonique & deploy — `/opt/lcars/runtime` (SSoT, ne pas re-dériver)

**UNE install partagée multi-humains** : `/opt/lcars/runtime/` (LCARS = le projet ; `fleet_*` = l'applicatif ;
le `_v2` est provisoire, reste du dev v1→v2). Elle contient **rel/ ET bin/ co-localisés** — les launchers
sont lus depuis `$BIN_DIR` de l'install (`bin/fleet_v2` exporte `LCARS_*_LAUNCH_PATH=$BIN_DIR/...`) :
**ZÉRO copie de launcher dans `/usr/local/bin`** (les copies éparpillées de juin ont divergé 3 semaines —
cicatrice 2026-07-18 : deux installs parallèles, deux fleets sur des builds à 5 jours d'écart, personne
d'alerté). Seuls les **symlinks PATH** vivent dans `/usr/local/bin` :

```bash
/usr/local/bin/fleet_v2 -> /opt/lcars/runtime/bin/fleet_v2
/usr/local/bin/lcars    -> /opt/lcars/runtime/bin/lcars
```

Le PATH de l'humain et les deploys de l'agent visent donc LE MÊME endroit — c'est le contrat.

**Procédure de deploy** (depuis `fleet`, gate vert exigé avant) :

```bash
MIX_ENV=prod mix release --overwrite
sudo rsync -a --delete _build/prod/rel/lcars_fleet/ /opt/lcars/runtime/rel/lcars_fleet/
# la liste des fichiers bin/ vit dans etc/install.manifest (données) — plus jamais recopiée ici :
sudo cp $(awk 'NF && $1 !~ /^#/ { print "bin/" $1 }' etc/install.manifest) /opt/lcars/runtime/bin/
sudo chgrp -R fleet /opt/lcars/runtime && sudo chmod g+rx /opt/lcars/runtime/bin/*
# CHAQUE humain relance SA fleet pour recharger le BEAM : fleet_v2 stop && fleet_v2 start
```

⚠ `rel/` seul ne suffit PAS : `bin/` porte les launchers N0/N1 (le monde des pods) — un deploy qui
oublie `bin/` fait tourner le nouveau BEAM avec les vieux sandboxes.

**La liste des fichiers livrés vit dans `etc/install.manifest`** (données : fichier, exec/noexec,
flag `link`) — consommée par `etc/install.sh` (qui automatise cette procédure) ET par le doctor
du provisioning (`60-deploy check`). Avant le manifest, la liste existait ici ET dans install.sh,
et les deux copies avaient commencé à dériver.

`bin/claude_launch.identity` **est** dans le manifest depuis que le BEAM publie : le tool MCP
`github_publish` fait tourner `bin/publish-transform.sh` côté hôte, et ce script source l'identité
co-localisée (`$SCRIPT_DIR/claude_launch.identity`) pour l'attribution du co-auteur. Tant que seul
l'opérateur lançait le script depuis le repo, l'identité n'avait pas à être livrée ; son invocation
par le BEAM la rend nécessaire à l'install. `bin/publish-rail.sh` (le rail phase-2) et
`bin/publish-transform.sh` shippent pour la même raison.

## Tests intégration

```bash
bash test/integration/host_launch_test.sh
# LAUNCH-Q : host_launch.sh vs tmux RÉEL (command factice, pas de claude) — sock+session+holder, contrat
# argv de bout en bout, teardown SIGTERM→kill-server. 15 checks, exit 0. Nécessite tmux.

bash test/integration/sandbox_notrace_test.sh
# F094 : invariant no-trace de bwrap_launch.sh vs bwrap RÉEL — arbo runtime LCARS host invisible,
# /home tmpfs, HOME=pod_dir, /etc SÉLECTIF (/etc/fleet ABSENT du pod). Nécessite bwrap+userns+tmux.
# Codes retour (audit F-09) : 0 = prouvé, 77 = SKIP (userns indispo — preuve NON exécutée), autre = échec.
# Un wrapper qui compte doit distinguer 77 : un skip n'est JAMAIS un vert.
```

### Sondes manuelles (hors `mix gate`, non-CI)

Ces scripts se déclarent `SONDE MANUELLE` dans leur en-tête : ils ne sont invoqués par RIEN — ni
`mix gate`, ni `test/shell_gate.sh` (qui ne lance que le test python du bridge et les `.bats`). Sans
cette liste, une sonde vivante que personne ne sait lancer pourrit sans bruit.

```bash
bash test/gate-r0.1-bwrap.sh          # isolation e2e RÉELLE (bwrap+tmux+vendor). 0 = prouvé, 3 = SKIP
                                      # explicite (bwrap/userns indispo) — jamais un PASS déguisé.
bash test/gate-r0.2-otp.sh            # lifecycle BEAM / superviseur OTP.
bash test/gate-r0.6-tooling.sh        # outillage statique (Credo/Sobelow/Dialyzer).
bash test/gate-r-core-comm-inc3b1.sh  # couche tool MCP, pur Elixir.
```

*(Il n'y a pas de sonde de boot/readiness hors-mix : `test/integration/boot_test.sh` visait le
hardening systemd et a été retiré avec lui. Le besoin n'est pas en attente d'un « re-ciblage » — il
n'existe plus sous cette forme ; une sonde de readiness serait à écrire, pas à récupérer.)*

## À reprendre (notes)
- **Graceful shutdown façon fleet_v2** : avec systemd parti, le drain coordonné (`Fleet.Starfleet.Shutdown`)
  n'est plus déclenché par `ExecStop=`. `fleet_v2 stop` fait un `tmux kill-server` (brutal). À câbler :
  `stop` déclenche le drain (begin → wait in-flight → kill). Voir backlog.
- **Caps bwrap en conteneur** : bwrap exige `unshare`/`mount`/`setns`/`pivot_root` (user+mount NS).
  Le systemd unit les autorisait via `SystemCallFilter`/`RestrictNamespaces` ; en Docker, c'est au
  **conteneur** de les accorder (cap-add / seccomp). À documenter au packaging cible.

## Frontière vendor

N0 (substrat pur). La frontière vendor N1 isolée = `bin/claude_launch.sh` (post-ADR-G ;
`fleet_claude_bridge` retiré).

## Role-tokens forge (fix A4)

Les comptes de rôle (architect, consultant, engineer, gatekeeper, qualifier, reviewer)
postent EN LEUR NOM via `<FORGE_ROLE_TOKENS_DIR>/<role>.gitea_token`. La pose est mécanisée :

    etc/provision-role-tokens.sh --forge <URL> --passwords-file <secrets.json> \
                                                                # les 6 rôles + le système = A4 complet
    etc/provision-role-tokens.sh --forge <URL> --check                          # sonde (nuke-drill)

Le `passwords-file` (JSON `{"compte":"pwd"}`, clé insensible à la casse) EST le livrable A4 durable :
un fichier opérateur-only, rejouable. Chaque token = une paire `compte:fichier` : les rôles produisent
`<role>.gitea_token`, et le compte SYSTÈME suit le MÊME contrat depuis qu'il s'appelle
`system_starfleet` — son fichier est `system_starfleet.gitea_token`, dérivé de son login comme les
autres. Tout part donc dans le même geste → A4 100%, pas de token système minté à la main.
(Il portait `system.gitea_token` pour un compte nommé `lcars-system` : un nom qui ne dérivait de
rien, donc une table `--extra-token` pour lui seul. Le drapeau existe toujours pour un vrai
décalage compte↔fichier ; il n'a plus d'usager dans la recette.) Gitea n'accepte QUE la basic auth pour créer un token (même un token site-admin ne peut
pas minter — vérifié 2026-07-05). Exécution PRIVILÉGIÉE, une fois par forge, idempotente. Sans ces
tokens, un humain neuf bloque au premier geste signé par un rôle (create_issue → 401, vécu 2026-07-05).
Tests : `test/provision_role_tokens/` (bats, couvert par `mix gate`).
