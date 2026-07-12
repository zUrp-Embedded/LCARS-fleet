# etc/ — run & déploiement de la fleet (chantier 16)

**Date** : 2026-05-10
**Dernière révision** : 2026-07-12
**Statut** : modèle humain-lance (systemd retiré 2026-06-16)
**Référencé par** : `design-notes/promoted/lcars-fleet_service.md`, `STATUS-CHANTIERS.md`

Substrat de lancement Ring 0. **systemd est retiré** : la fleet ne tourne plus comme un service
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

## Binaires partagés à installer (RO, owner système)

Le spawner lit les launchers à des **paths absolus** `/usr/local/bin/*_launch.sh` (hors `/home`,`/tmp`
sinon masqués par le `--tmpfs` du sandbox). Absents → 1er spawn KO `:executable_missing`.

```bash
# Launchers N0/N1 pod : bwrap_launch (containment bwrap) · host_launch (containment none, LAUNCH-Q) ·
# claude_launch (launcher vendor N1, ADR-G).
sudo cp bin/bwrap_launch.sh bin/host_launch.sh bin/claude_launch.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/{bwrap_launch.sh,host_launch.sh,claude_launch.sh}
# CLI opérateur (spawn/list/attach un pod). `attach` exige le même UID que la fleet (= l'humain).
sudo cp bin/lcars /usr/local/bin/ && sudo chmod +x /usr/local/bin/lcars
```

## Tests intégration

```bash
bash test/integration/host_launch_test.sh
# LAUNCH-Q : host_launch.sh vs tmux RÉEL (command factice, pas de claude) — sock+session+holder, contrat
# argv de bout en bout, teardown SIGTERM→kill-server. 15 checks, exit 0. Nécessite tmux.

bash test/integration/sandbox_notrace_test.sh
# F094 : invariant no-trace de bwrap_launch.sh vs bwrap RÉEL — arbo runtime LCARS host invisible,
# /home tmpfs, HOME=pod_dir, /etc SÉLECTIF (/etc/fleet ABSENT du pod). Nécessite bwrap+userns+tmux.
```

*(`test/integration/boot_test.sh` testait le hardening/readiness systemd — obsolète avec le retrait,
à re-cibler ou retirer.)*

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
        --extra-token lcars-system:system.gitea_token       # les 6 rôles + le token système = A4 complet
    etc/provision-role-tokens.sh --forge <URL> --check                          # sonde (nuke-drill)

Le `passwords-file` (JSON `{"compte":"pwd"}`, clé insensible à la casse) EST le livrable A4 durable :
un fichier opérateur-only, rejouable. Chaque token = une paire `compte:fichier` : les rôles produisent
`<role>.gitea_token` ; `--extra-token lcars-system:system.gitea_token` pose le token SYSTÈME (compte
`lcars-system` ≠ nom de fichier `system.gitea_token`) dans le MÊME geste → A4 100%, pas de token système
minté à la main. Gitea n'accepte QUE la basic auth pour créer un token (même un token site-admin ne peut
pas minter — vérifié 2026-07-05). Exécution PRIVILÉGIÉE, une fois par forge, idempotente. Sans ces
tokens, un humain neuf bloque au premier geste signé par un rôle (create_issue → 401, vécu 2026-07-05).
Tests : `test/provision_role_tokens/` (bats, couvert par `mix gate`).
