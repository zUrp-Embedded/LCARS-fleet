# lcars-fleet.service (chantier 16)

**Date** : 2026-05-10
**Dernière révision** : 2026-05-10
**Statut** : att-1 livré
**Référencé par** : `design-notes/promoted/lcars-fleet_service.md`, `STATUS-CHANTIERS.md`

Substrat OS Ring 0 — systemd unit + readiness probe + EnvironmentFile +
Mix release config pour daemon LCARS v2 umbrella OTP.

## Livrables

| Fichier | Path cible | Permissions | Description |
|---|---|---|---|
| `etc/lcars-fleet.service` | `/etc/systemd/system/lcars-fleet.service` | root:root 0644 | systemd unit `Type=notify` + hardening strict |
| `bin/lcars-readiness` | `/usr/local/bin/lcars-readiness` | root:root 0755 | bash readiness probe `/api/health` polling |
| `etc/lcars-fleet.env.template` | `/etc/fleet/lcars-fleet.env` | root:lcars 0640 | EnvironmentFile (secrets cookie + tokens, hors git) |
| `rel/runtime.exs` | inclus dans Mix release `_build/prod/rel/...` | — | runtime config Elixir 1.9+ stdlib (env vars → Application config) |

## Hardening systemd (refus par défaut canon §0 #1)

```
ProtectHome=yes
ProtectSystem=strict
ReadWritePaths=/var/lib/lcars /var/log/fleet-audit.jsonl /var/log/fleet-starfleet.jsonl /tmp
NoNewPrivileges=yes
PrivateTmp=yes
CapabilityBoundingSet=             # vide (port :8080 > 1024 sans privilège)
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources
RestrictNamespaces=user mount      # bwrap requirement (ch4 PROMOTED)
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
LockPersonality=yes
```

## Readiness probe

`/usr/local/bin/lcars-readiness [timeout_s]` (default 60s) :
- polling `curl -sf http://localhost:8080/api/health` toutes les 2s
- exit 0 si HTTP 200 reçu
- exit 1 si timeout
- override URL via `LCARS_HEALTH_URL` env var (CI/debug/monitoring externe)

## Procédure deploy host-natif

```bash
# 1. Build Mix release prod
cd fleet/runtime
MIX_ENV=prod mix deps.get
MIX_ENV=prod mix release

# 2. Copier release vers host cible
sudo mkdir -p /var/lib/lcars/release
sudo tar -xzf _build/prod/fleet_umbrella-0.1.0.tar.gz -C /var/lib/lcars/release/
sudo chown -R lcars:lcars /var/lib/lcars/

# 3. Installer unit + readiness + env
sudo cp etc/lcars-fleet.service /etc/systemd/system/
sudo cp bin/lcars-readiness /usr/local/bin/
sudo chmod +x /usr/local/bin/lcars-readiness

sudo cp etc/lcars-fleet.env.template /etc/fleet/lcars-fleet.env
# Éditer secrets : RELEASE_COOKIE (32 bytes base64), GITEA_TOKEN, etc.
sudo $EDITOR /etc/fleet/lcars-fleet.env
sudo chown root:lcars /etc/fleet/lcars-fleet.env
sudo chmod 0640 /etc/fleet/lcars-fleet.env

# 4. Provisionner secrets root:lcars 0600
sudo install -o root -g lcars -m 0600 /dev/null /etc/fleet/api-secret
sudo install -o root -g lcars -m 0600 /dev/null /etc/fleet/webhook-secret
# Remplir les 2 secrets

# 5. Activer + démarrer
sudo systemctl daemon-reload
sudo systemctl enable --now lcars-fleet.service

# 6. Vérifier
sudo systemctl status lcars-fleet.service
journalctl -u lcars-fleet.service -f
curl -sf http://localhost:8080/api/health  # → {"status":"ok",...}
```

## Hardening verify (post-deploy)

```bash
sudo systemd-analyze security lcars-fleet.service
# Score cible : ≤ 3.5 (low exposure)
```

## Tests intégration

```bash
bash test/integration/boot_test.sh
# 31 checks, exit 0
```

Vérifie hardening directives + readiness exit codes + env vars + Mix
release config + runtime.exs wire-up coord_backend ch12+ch13 → Fleet.Coord.

Tests *deployment* réels (`systemctl start`) hors scope CI — host avec
systemd actif requis. Procédure manuelle ci-dessus.

## Decisions deferred

- **Watchdog systemd liveness 30s** : critère 1ère freeze daemon
  observable → `WatchdogSec=30` + `sd_notify(WATCHDOG=1)` Elixir
- **SystemCallFilter audit mode** : critère 1er service kill par
  syscall non-prévu → `audit` mode log-only puis durcir
- **Hot-code-loading upgrade** : critère production stable +
  downtime restart >5s problématique → `release_handler` OTP

## Frontière vendor

N0 (substrat OS pur, daemon démarré consume SDK indirectement via
ch8 `fleet_claude_bridge` frontière vendor N1 isolée).
