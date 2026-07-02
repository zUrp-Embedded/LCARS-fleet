# Fleet.SPBuilder

**Date** : 2026-05-09
**Dernière révision** : 2026-07-02
**Statut** : implémenté run #3.1 chantier #2 — design note PROMOTED
**Référencé par** : 04_design-notes/fleet_sp_builder.md

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

- `:fleet_sp_builder, :sp_role_root` — racine FS sous laquelle résout le chemin `spec.systemPrompt` d'un
  cap-profile. Défaut = le **canon cap-profiles BUNDLÉ** (`Application.app_dir(:fleet_cap_profile,
  "priv/canon/cap-profiles")`, même source que `Fleet.CapProfile.root_dir/0`) → résout en release comme en
  dev sans env (l'ancien défaut relatif `"cap-profiles"`, relatif au CWD, donnait `:enoent` en release).
- `:fleet_sp_builder, :modop_root` — racine FS des fragments SP de modop (`<root>/<name>/sp.md`).
  **CONFIG-OBLIGATOIRE** : pas de défaut bundlé (les fragments canon vivent dans
  `fleet_pipeline/priv/canon/modop-bundles`, Ring 3, hors du graphe de deps de ce Ring 1). Non configuré +
  modops demandés → `compose/3` rend `{:error, :modop_root_unconfigured}` (fail-loud, plus de défaut relatif
  `"modop"` qui donnait un `:enoent` muet). La chaîne de spawn PROD ne passe aucun modop → root jamais requis.

## Niveaux d'injection canoniques

- N0 : poids modèle.
- N1 : server prompt Anthropic.
- N2 : `system-prompt.md` (`compose/3`).
- N2bis : `~/context/brief.md` (référencé, pas composé).
- N3 : `~/.claude/CLAUDE.md` (`compose_claude_md/3`).
- N3bis : `~/.claude/skills/` (`filter_skills/2`).

## Frontière vendor

Module vendor-agnostic : il **compose** le SP, il ne l'**injecte** pas.
L'injection est faite par la frontière N1 (`bin/claude_launch.sh`) : le spawner
écrit le SP composé dans un FICHIER (`<pod_dir>/.lcars/system-prompt.md`), que le
launcher passe à `claude` via **`--system-prompt-file`** — HORS argv. Motif : le SP
en argv fuitait par `/proc/<pid>/cmdline` et frôlait `ARG_MAX` ; le mode fichier tue
les deux (`.lcars/` est lisible in-sandbox, contrairement à `.claude/` masqué par le
bind creds). RC interactif (post-ADR-G : plus de `claude -p` ni d'app
`fleet_claude_bridge`, retirée au pivot).
