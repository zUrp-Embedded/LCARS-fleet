# etc/ — lancement et release

**Date**: 2026-05-10
**Last revised**: 2026-09-04
**Status**: active — the launch (`bin/fleet_v2`) and release substrate of `runtime/`
**Referenced by**: `runtime/CLAUDE.md`

Ce dossier porte ce qui lance la fleet et ce qui la livre. Il ne porte aucun contrat de module :
le contrat d'une variable d'environnement est le commentaire de `config/runtime.exs` qui la lit,
et `fleet_v2.env.template` en est le catalogue.

## Le modèle : chaque humain lance SA fleet

Pas de service système. `bin/fleet_v2 start` démarre le BEAM **sous l'humain qui lance**, détaché
dans une session tmux dédiée ; les pods héritent son UID, ses credentials Claude (`~/.claude`) et
son identité git. Tout l'état per-humain vit sous `~/.lcars/*`. Le launcher refuse un compte
système (uid sous `UID_MIN`) et le siège sysadmin (`/etc/lcars/seat.uid`).

```bash
cp etc/fleet_v2.env.template ~/.lcars/fleet_v2.env   # éditer : FORGE_BASE_URL au minimum
fleet_v2 start [--debug] [--max-fan N]                # démarre le BEAM ; les permanents (starfleet) montent seuls
fleet_v2 status                                       # build, BEAM vivant, pods vivants
fleet_v2 stop                                         # SIGTERM → drain (Fleet.Admiral.Shutdown) → teardown
fleet_v2 forge [nom]                                  # le profil de forge actif (~/.lcars/forge.d/<nom>.env)
```

Aucun port : la porte d'écriture (`lcars spawn`) est une socket AF_UNIX par humain, le deck
d'observation aussi. La découverte des projets se fait par appartenance aux orgs des catalogues
installés : rien à configurer. L'architecte est par projet, lancé à l'ouverture du projet ; il n'y a
pas d'« attach de l'arch » au démarrage. Les logs du BEAM : `tmux -S ~/.lcars/run/fleet_v2.sock attach`.

## Les fichiers

| fichier | ce que c'est |
|---|---|
| `fleet_v2.env.template` | le catalogue des env vars de la boîte, à copier en `~/.lcars/fleet_v2.env` |
| `release.manifest` | ce qui part de `bin/` dans l'install (fichier, exec/noexec, `link`) — des données, pas du code |
| `deploy-release.sh` | gate → `mix release` → pose atomique sous `/opt/lcars/runtime` → symlinks PATH |
| `enroll-catalogue.sh` | dérive les entrées de la recette forge (tofu) depuis les rôles d'un catalogue |
| `provision-role-tokens.sh` | mint idempotent des jetons de rôle sur une forge, détenus par le service d'autorité |

## Install et deploy : `/opt/lcars/runtime`

Une install partagée entre humains, en lecture seule (`root`, groupe `fleet` r-x) : `rel/` (la
release, ERTS embarqué) **et** `bin/` (les launchers N0/N1 des pods) côte à côte. Le BEAM résout ses
launchers depuis `$BIN_DIR` de l'install, et seuls des symlinks vivent dans `/usr/local/bin`
(`fleet_v2`, `lcars`, les entrées `link` du manifest). Le PATH de l'humain et le deploy visent donc
le même endroit.

`etc/deploy-release.sh` fait la procédure entière et s'arrête sur un gate rouge : `mix gate` sur
l'arbre source, `MIX_ENV=prod mix release`, swap atomique de `rel/` (la génération précédente reste
en `.prev`), copie atomique de chaque entrée du manifest, template d'env, perms, symlinks. Il refuse
de tourner en root (seule la pose demande des droits ; `deploy/modules.d/60-deploy.sh` le joue
comme l'humain puis repose les liens). Sortie `3` = release posée, liens PATH incomplets : un fait
que l'appelant qui câble les liens lui-même accepte, un refus sinon.

⚠ `rel/` seul ne suffit pas : un deploy qui oublie `bin/` fait tourner le nouveau BEAM avec les
vieux sandboxes. Le manifest est la seule liste de ce qui part.

## Jetons de rôle

Les comptes de rôle postent en leur nom. Leurs jetons sont mintés par `provision-role-tokens.sh`
(la liste `ROLES` du script est tenue par le mur `roles.provisioning_locked`), écrits en
`<login>.gitea_token` sous `/opt/lcars/var/tokens` et détenus par le service d'autorité
(`lcars-authority`), seul lecteur. Le runtime ne lit aucun fichier de jeton : il **demande** le
jeton d'un compte au service (`bin/lcars-authority-ask`, socket `roles.sock`) au moment de pousser.
Minter exige la basic auth du compte : Gitea refuse la création de jeton par en-tête, même
site-admin (mesuré 2026-07-05). `--check` sonde sans écrire. Témoins : `test/etc/` (bats, dans le
gate).

## Tests d'intégration et sondes manuelles (hors `mix gate`)

```bash
bash test/integration/host_launch_test.sh
# host_launch.sh contre un tmux RÉEL (commande factice, pas de claude) — sock+session+holder,
# contrat argv de bout en bout, teardown SIGTERM→kill-server. Nécessite tmux.

bash test/integration/sandbox_notrace_test.sh
# invariant no-trace de bwrap_launch.sh contre bwrap RÉEL — arbo runtime hôte invisible, /home tmpfs,
# HOME=pod_dir, /etc sélectif. Nécessite bwrap+userns+tmux.
# Codes retour : 0 = prouvé, 77 = SKIP (userns indispo — preuve NON exécutée), autre = échec.
# Un wrapper qui compte doit distinguer 77 : un skip n'est JAMAIS un vert.
```

Ces scripts se déclarent `SONDE MANUELLE` dans leur en-tête : rien ne les invoque, ni `mix gate`
ni `test/shell_gate.sh`. Sans cette liste, une sonde vivante que personne ne sait lancer pourrit
sans bruit.

```bash
bash test/probes/gate-r0.1-bwrap.sh     # isolation e2e RÉELLE (bwrap+tmux+vendor). 0 = prouvé, 3 = SKIP explicite
bash test/probes/gate-r0.2-otp.sh       # lifecycle BEAM / superviseur OTP
bash test/probes/gate-r0.6-tooling.sh   # outillage statique (Credo/Sobelow/Dialyzer)
bash test/gate-r-core-comm-inc3b1.sh    # couche tool MCP, pur Elixir
```

Il n'y a pas de sonde de boot/readiness hors-mix : la readiness se lit sur le deck
(`/api/readiness/deep`) d'une fleet lancée.

## Frontière vendor

N0 (substrat pur). La frontière vendor N1 est `bin/claude_launch.sh`, un script et pas un module :
un vendor de plus, c'est un `bin/<vendor>_launch.sh` de plus, même forme d'arguments.
