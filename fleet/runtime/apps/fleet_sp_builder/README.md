# Fleet.SPBuilder

**Date**: 2026-05-09
**Last revised**: 2026-07-07 (EN translation + contract resync against code: `jason` dep removed, `yaml_elixir` now declared directly, `fleet_workflow` ring label corrected 3 → 2 ; 2026-07-05: facade split → Monk + RepoSections ; contract resync: `monk_registry_root` knob, `resolve_monk_injection/2` API, dependencies)
**Status**: implemented — design note PROMOTED
**Referenced by**: 04_design-notes/fleet_sp_builder.md

System Prompt builder/composer (LCARS schema v2.5).

Pure data-transformer module — `%Fleet.CapProfile{}` + modop bundles
(sp.md fragments) + pod identifiers → `system-prompt.md`, `CLAUDE.md`,
filtered skills paths.

## Modules

- `Fleet.SPBuilder` — the facade (`Composer` behaviour): composes SP + CLAUDE.md +
  filters skills, EEx templating, role SP / modop fragment reads, path
  resolution (`sp_role_root`/`modop_root` — config accessors cohesive with those reads,
  deliberately not extracted).
- `Fleet.SPBuilder.Monk` — monk-injection resolution (YAML registry I/O,
  a distinct data source): `resolve/2` (= the public API
  `resolve_monk_injection/2`, defdelegate), `resolve_or_empty/2` (non-monk →
  empty injection, compose flow byte-identical), `persona_section/1`.
- `Fleet.SPBuilder.RepoSections` — markdown mini-parser of the repo `CLAUDE.md`:
  `read/1` + `extract/1` (sections `Stack|Build|Test|Conventions|Commands|Gotchas`).
- `Fleet.SPBuilder.Composer` — the behaviour (test mock + future 2nd vendor).

## API

- `Fleet.SPBuilder.compose/3` — composes the SP, returns `{sp_md,
  stable_sha256, metadata}`. Stable-parts determinism (pod_id,
  spawned_at, job_id, attempt_id excluded from the hash).
- `Fleet.SPBuilder.compose_claude_md/3` — composes the pod's `CLAUDE.md`
  (N3) with selective extraction of the repo `CLAUDE.md` sections.
- `Fleet.SPBuilder.filter_skills/2` — filters `skills_root` by the
  `cap_profile.spec["knowledge"]["skills"]` whitelist.
- `Fleet.SPBuilder.resolve_monk_injection/2` — resolves the monk injection
  (defdelegate to `Monk.resolve/2`; outside the `Composer` behaviour).

## Templates

- `priv/templates/sp_template.eex` — system prompt template (named
  zones, stdlib EEx).
- `priv/templates/claude_md_template.eex` — pod CLAUDE.md template.

## Configuration

- `:fleet_sp_builder, :sp_role_root` — FS root under which a cap-profile's `spec.systemPrompt` path
  resolves. Default = the **BUNDLED cap-profiles canon** (`Application.app_dir(:fleet_cap_profile,
  "priv/canon/cap-profiles")`, same source as `Fleet.CapProfile.root_dir/0`) → resolves in release as in
  dev without env (the old relative default `"cap-profiles"`, relative to the CWD, gave `:enoent` in release).
- `:fleet_sp_builder, :modop_root` — FS root of the modop SP fragments (`<root>/<name>/sp.md`).
  **CONFIG-MANDATORY**: no bundled default (the canon fragments live in
  `fleet_workflow/priv/canon/modop-bundles`, Ring 2, outside the dep graph of this Ring 1 app). Unconfigured +
  modops requested → `compose/3` returns `{:error, :modop_root_unconfigured}` (fail-loud, no more relative
  `"modop"` default that gave a silent `:enoent`). The PROD spawn chain passes no modop → the root is never required.
- `:fleet_sp_builder, :monk_registry_root` — root resolving the monk registry's relative path
  (`spec.knowledge.monk_registry` = basename, e.g. `alpha.yaml`). Precedence: `:monk_registry_root` opt
  (test-seam) > this config > bundled default `Application.app_dir(:fleet_cap_profile,
  "priv/canon/cap-profiles/monks")`.

None of these knobs is set in `config/*.exs` or via env var — inline defaults only
(tests override via `Application.put_env` / opt).

## Dependencies

- `fleet_cap_profile` (in_umbrella, Ring 0) — `%Fleet.CapProfile{}` struct consumed + default
  roots via `app_dir` (cap-profiles canon, monks registry).
- `yaml_elixir ~> 2.12` — direct use (`Monk`, registry read via `YamlElixir.read_from_file/1`);
  declared explicitly, no longer a silent transitive resolution through `fleet_cap_profile`.
- `stream_data` (test only).
- `jason` — REMOVED (no `Jason.*` call in `lib/` or `test/`; the dep was declared without use).

## Canonical injection levels

- N0: model weights.
- N1: Anthropic server prompt.
- N2: `system-prompt.md` (`compose/3`).
- N2bis: `~/context/brief.md` (referenced, not composed).
- N3: `~/.claude/CLAUDE.md` (`compose_claude_md/3`).
- N3bis: `~/.claude/skills/` (`filter_skills/2`).

## Vendor boundary

Vendor-agnostic module: it **composes** the SP, it does not **inject** it.
Injection is done by the N1 boundary (`bin/claude_launch.sh`): the spawner
writes the composed SP to a FILE (`<pod_dir>/.lcars/system-prompt.md`), which the
launcher passes to `claude` via **`--system-prompt-file`** — OUT of argv. Rationale: the SP
in argv leaked through `/proc/<pid>/cmdline` and grazed `ARG_MAX`; file mode kills
both (`.lcars/` is readable in-sandbox, unlike `.claude/` masked by the creds
bind). Interactive RC only: no more `claude -p` (metered mode) and no
`fleet_claude_bridge` app — both removed at the pivot.
