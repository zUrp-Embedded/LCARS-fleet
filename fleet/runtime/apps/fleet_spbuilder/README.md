# Fleet.SPBuilder

**Date** : 2026-05-09
**Dernière révision** : 2026-05-22
**Statut** : implémenté run #3.1 chantier #2 — design note PROMOTED
**Référencé par** : 04_design-notes/fleet_spbuilder.md

System Prompt builder/composer (LCARS schema v2.5).

Module pure data transformer — `%Fleet.CapProfile{}` + modop bundles
(sp.md fragments) + identifiants pod → `system-prompt.md`, `CLAUDE.md`,
paths skills filtrés.

## API

- `Fleet.SPBuilder.compose/3` — compose le SP, retourne `{sp_md,
  stable_sha256, metadata}`. Déterminisme stable parts (pod_id,
  spawned_at, job_id, attempt_id exclus du hash).
- `Fleet.SPBuilder.compose_claude_md/3` — compose `CLAUDE.md` du pod
  (N3) avec extraction sélective des sections du `CLAUDE.md` repo.
- `Fleet.SPBuilder.filter_skills/2` — filtre `skills_root` selon la
  whitelist `cap_profile.spec["knowledge"]["skills"]`.

## Templates

- `priv/templates/sp_template.eex` — template système prompt (zones
  nommées, EEx stdlib).
- `priv/templates/claude_md_template.eex` — template CLAUDE.md du pod.

## Configuration

- `:fleet_spbuilder, :sp_role_root` — racine FS des SP rôle base
  (default `cap-profiles`).
- `:fleet_spbuilder, :modop_root` — racine FS des modop bundles
  (default `modop`).

## Niveaux d'injection canoniques

- N0 : poids modèle.
- N1 : server prompt Anthropic.
- N2 : `system-prompt.md` (`compose/3`).
- N2bis : `~/context/brief.md` (référencé, pas composé).
- N3 : `~/.claude/CLAUDE.md` (`compose_claude_md/3`).
- N3bis : `~/.claude/skills/` (`filter_skills/2`).

## Frontière vendor

Module vendor-agnostic. Les flags `claude -p`
(`--system-prompt-file`, `--append-system-prompt-file`) sont appliqués
par `Fleet.Claude.SPInjection` co-localisé `fleet_claude_bridge`
(chantier 8).
