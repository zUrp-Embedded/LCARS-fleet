# Plan : consolidation builder multi-arch

## Contexte

Deux instances WSL distinctes (build-arm = cross ARM64, build-x86-64 = build natif,
quasi-inutilisée) avec un mécanisme de sélection active (`builder-choice` file).
Une seule instance est active à la fois. build-x86-64 n'a aucun build-cycle.sh,
aucun projet réel. L'objectif : une instance `builder`, flags `--arch arm64|x86-64`,
build-x86-64 retirée de la flotte (WSL distro conservée).

## Ce qui ne change pas

- `home_claude_CLAUDE-builder.md` — directives arch-agnostiques
- Logique ARM64 de `build-cycle.sh` — wrappée, pas réécrite
- Canaux IPC `to-build.md`, `to-dev.md` — inchangés
- `build-x86-64` WSL distro — hors flotte, pas désinscrite

## Fichiers modifiés

### E1 — deploy.sh

- TARGETS : retirer `$HOMES_ROOT/build-x86-64/.claude`, renommer `build-arm` → `builder`
- BUILDER_HOMES : même renommage
- ARM_HOME : `build-arm` → `builder`
- Supprimer filtre ligne 73 (`*build-x86-64* && skills && cross-arm64`) — plus qu'une cible builder
- Section settings.local.json : renommer la target

### E2 — Fleet scripts

| Fichier | Changement |
|---|---|
| `fleet/wake-instance.sh` | Supprimer logique `builder-choice`, hardcoder `ACTIVE_BUILDER="builder"` |
| `fleet/fleet-launch.sh` | Supprimer sélection arm\|x86, `BUILDER_WSL="builder"` hardcodé |
| `fleet/fleet-monitor.py` | Retirer `build-x86-64` de INSTANCE_NAMES, renommer `build-arm`, supprimer lecture `builder-choice` |
| `fleet/light_off.sh` | WORKERS : retirer `build-x86-64`, renommer `build-arm` |
| `fleet/backup-wsl.sh` | INSTANCES : même |
| `fleet/hub-menu.sh` | Retirer `Alt+x build-x86`, renommer label `build-ARM` → `builder` |
| `fleet/fleet-blocker.sh` | Guard pattern : `*build-arm*\|*build-x86*` → `*builder*` |
| `fleet/fleet-build-done.sh` | Guard pattern : même |
| `fleet/fleet-notify.sh` | Whitelist cibles : `build-arm`/`build-x86-64` → `builder` |

### E3 — build-cycle.sh : ajout --arch

Nouveau flag `--arch <arm64|x86-64>` (défaut : `arm64`).

**arm64** : source `~/.env.cross` → toolchain-rpi-aarch64.cmake + SYSROOT + CFLAGS_CPU (inchangé)

**x86-64** :
- source `~/.env.x86`
- cmake sans toolchain ni sysroot (`-DCMAKE_BUILD_TYPE=Release` seulement)
- Steps actifs : 1 (git pull), 3 (ostserver si --rebuild-ost), 4 (ostmodules), 5 (deliver)
- Steps NA : 2 (INDI), 6 (pi-gen), 7 (inject-image) → skip + message explicite dans le log

Implémentation : bloc `if [[ "$ARCH" == "arm64" ]]; then <cmake flags arm64> else <cmake flags x86> fi`
autour des variables cmake — corps des steps identique.

### E4 — .claude/hooks/session-startup.sh

- Patterns builder : `*build-arm*|*build-ARM*` + `*build-x86-64*` → `*builder*`
- Injection contexte RPi target : conserver, conditionné `builder` (pas arm64-spécifique)
- dev startup : `inject_state_only build-arm-handoff.md` + `build-x86-64-handoff.md`
  → `inject_state_only builder-handoff.md`
- IPC write tags : `[build-arm]` → `[builder]`

### E5 — Docs + IPC

- `memory/ipc-protocol.md` : retirer ligne build-x86-64, renommer build-arm → builder
- `memory/builder-rules.md` : nom d'instance
- `home_claude_CLAUDE.md` : section "Instance scope boundaries" + "Builders" règle
- `provisioning/wsl2/Deploy-Fleet.ps1` : retirer option build-x86-64, renommer build-ARM → builder
- `provisioning/wsl2/Instanciator.ps1` : retirer InstanceType build-x86-64, renommer build-ARM
- `provisioning/linux/deploy-fleet.sh` : même
- `README.md` : tableau fleet, section démarrage rapide

### E6 — Handoffs (migration fichiers)

```bash
mv /home/commons/handoff/build-arm-handoff.md /home/commons/handoff/builder-handoff.md
# build-x86-64-handoff.md → rm (vide / inutilisé)
```

### E7 — WSL rename (manuel, lordzurp, après validation E1-E6)

```powershell
# PowerShell (Windows)
wsl --export build-arm C:\WSL\backups\build-arm-backup.tar
wsl --import builder "C:\WSL\builder" C:\WSL\backups\build-arm-backup.tar --version 2
wsl -d builder -- whoami   # vérifier
# Renommer le répertoire partagé #2_Home (adapter le chemin réel) :
# Rename-Item "X:\...\#2_Home\build-arm" "builder"
# puis depuis architect :
bash /home/wsl-root/#0_LCARS-deploy.sh
# si OK :
wsl --unregister build-arm
del C:\WSL\backups\build-arm-backup.tar
```

## Ordre d'exécution

E1 → E2 → E3 → E4 → E5 → commit + deploy.sh → E6 (handoff rename)
E7 : manuel par lordzurp après validation

## Vérification

1. `bash deploy.sh --dry-run` → aucune référence build-x86-64, toutes les targets `builder`
2. `~/start` → fleet-monitor affiche `builder` (ni `build-arm`, ni `build-x86-64`)
3. `build-cycle.sh --arch arm64` → log `source ~/.env.cross`, cmake avec toolchain RPi
4. `build-cycle.sh --arch x86-64` → log `source ~/.env.x86`, cmake sans toolchain
5. `fleet-build-done.sh` depuis builder → DONE entry dans `to-dev.md`
