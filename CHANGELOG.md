# Changelog

**Date** : 2026-03-04
**Dernière révision** : 2026-03-23
**Statut** : actif — Keep a Changelog format
**Référencé par** : —

All notable changes to LCARS-fleet are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/) — Added / Changed / Fixed / Removed per version.

---

## [Unreleased]

## [6.0.0-beta] — 2026-03-23

### Added
- SP-custom injection: system-prompt.md assembled per role by build-sp.sh (replaces @import chain)
- PreCompact hook: mechanical harvest before auto-compact (git state + fleet state → handoff)
- fleet-doctor: 591 checks across 9 sections, CC vs SP version check
- Release workflow: FreeBSD-style freeze/beta/RC/release with fleet-system.yaml release_phase
- Protocole v6.0: audited, stable, retrocompat baseline
- Day-1 documentation: 4 user guides (#24-#27) + interactive onboarding skill
- docs/design-history/: narrative genesis preserved (13 files from directives archive)
- 3-track versioning: directives + protocole + fleet, all converging to 6.0.0

### Changed
- directives/ reduced to 3 user-owned files (protocole.md, protocole-user.md, profile.md)
- CLAUDE.md = user personalization surface (@import → directives/ only)
- sources/protocole.md → symlink to directives/protocole.md (single source of truth)
- fleet-system.yaml: version 5.5.0, release_phase freeze, protocole >=6.0 in requires
- fleet-build-yaml.sh: FLEET_DIR resolution via env > runtime > dirname
- fleet-update.sh: sudo on chmod (fixes fleet_user ownership after pull)
- deploy.sh: silent skip for non-provisioned homes, consultant allowed_tools +Write+Edit
- hooks.yaml: declarative source of truth for all 7 hooks
- Profiles: removed 6 unimplemented skills from architect/dev/consultant

### Removed
- directives/regles.md, conventions.md, roles.md, role.md, README.md (DEPRECATED → migrated to SP sources)
- directives/roles/ (12 files, replaced by fleet/system-prompt/sources/roles/)
- directives/_archived/ (6 files, obsolete migration artifacts)
- role.md symlinks in agent homes (role injected via SP-custom)
- directives_rev mechanism in CLAUDE.md + fleet-build-yaml.sh (replaced by fleet-system.yaml requires)
- Dead protocole deployment code in deploy-hooks.sh

### Fixed
- fleet-doctor false positives: CLAUDE.md drift, pre-commit scan scope, conditional checks
- Hook modes 664→775 on all agents
- Credentials mode 660→600 on headless agents
- /home/private permissions 770→700
- /mnt/c writability (chmod 555)

## [5.4.0] — 2026-03-21

(Previous [Unreleased] entries, now part of the v5.x series)

### Changed
- Scratchpad : `docs/v5-scratchpad.md` → `docs/scratchpad.md` (version implicite par branche git)
- Scratchpad : scope, outil (`bash >>`), format minimal (date+heure), rédacteur par construction
- Scratchpad : exception Read préalable encodée dans les règles d'édition
- `note bien:` : destination canonique → `docs/scratchpad.md` (était "handoff ou ACTIONS")
- Internal naming: `LCARS-fleet` → `LCARS` everywhere except GitHub URLs
- Instance naming: `qa` → `qualifier`, `architect-fleet` → `engineer`, `architect-lead` → `architect`
- Commons flat: handoff files directly in `/home/commons/` root (was `#8_handoffs/`)
- Single CLAUDE.md for all roles — role differences via memory/ files (was 4 variants)
- `@import` chain: relative path `@CLAUDE-protocol.md` (was `@~/.claude/...`)
- FR canonical for protocol, translations via `fleet.yaml` `lang:` field
- Ready Room (`/home/ready-room/`) replaces `#7_exchange/`
- `LCARS_ROOT=/local/LCARS` (was `/local/LCARS-fleet`)
- Docker: updated to v2 naming and paths

### Removed
- `sync-mr-hr.sh` — MR/HR token-optimized duplication eliminated
- PowerShell `rename-instances.ps1` — LCARS deploys on vanilla WSL, no custom scripts needed
- `home_claude_CLAUDE-glossary-machine.md` — never registered
- `home_claude_CLAUDE-protocol.md` — orphan EN condensed, replaced by `.claude/CLAUDE-protocol.md`
- Dead commands: `doc-audit.md`, `maj_doc.md`
- Dead hooks: `post-write-doc-reminder.sh`
- `lcars-provisioning` references — never existed as separate repo

## [2.0.0] — 2026-03-04

### Added
- qualifier instance: pytest/ctest runner, `to-qualifier.md` channel, `fleet-build-done.sh` auto-trigger
- `build-cycle.sh`: incremental build with `--arch arm64|x86-64`, replaces per-arch instances
- `/push-github` skill: pre-push automation with danger assessment (Step 0), stardate update, README check
- `fleet-monitor.py`: Rich dashboard, per-instance state cards including architect
- `fleet-notify.sh`: shell-based inter-instance notification (token optimization)
- `herald.sh` + auto-wake directionals: fleet-monitor dispatches wake signals on `notify` field
- IPC audit: `ipc-protocol.md`, scope boundaries per instance, language rules

### Changed
- `builder` consolidation: single instance replaces `build-arm` + `build-x86-64`
- `deploy.sh`: unified deployment matrix, `--update-models` flag
- Wake messages: English compact format `[wake] instance: task`

### Fixed
- `fleet-notify.sh`: `qualifier` added to valid targets whitelist
- `update-header-dates.sh`: execute bit restored (drvfs strip bug)
- `deploy.sh` ARM_UTILS: `filter-build-output.py` (was `.sh`)
- `fleet-lock-cleanup.sh` + `supervisor-notes-check.sh`: added to INSTANCE_UTILS

## [1.x] — internal phases (not public)
