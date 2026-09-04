# Fleet.SPBuilder — domain card

**Date**: 2026-07-13
**Last revised**: 2026-09-04
**Status**: active — System Prompt composer from blocks
**Referenced by**: —

System Prompt builder/composer (pod primitive): a pure data-transformer turning a
`%Fleet.CapProfile{}` + modop bundles + pod identifiers into a `system-prompt.md`,
a pod `CLAUDE.md`, and a filtered skills list. No process, no state.

**This file is a map, not the contract.** Each module owns its contract in its own
`@moduledoc`/`@spec` (`h Fleet.SPBuilder` in IEx, or `lib/`) — the 6 injection levels
(N0–N3bis), the vendor boundary, the sha256 determinism and every exit code live
there, not restated here.

## Modules
- `Fleet.SPBuilder` — the facade + `Composer` impl (`compose/3`, `compose_claude_md/3`, `filter_skills/2`, `resolve_monk_injection/2` defdelegate); EEx templating (`priv/catalogue/sp_builder/templates/*.eex`) + role-SP / modop reads + path resolution
- `Fleet.SPBuilder.Blocks` — block-based composition of the per-role SPs (`<catalogue>/sp_builder/sp_blocks/` + `sp-map.yaml`, i.e. `priv/catalogue/` and `priv/catalogue-system/`; `mix lcars.sp.gen` writes the flat drafts that `Fleet.Spawner.Pod.Assets` reads, N2); fail-loud no-fallback (no SP → no pod)
- `Fleet.SPBuilder.Monk` — monk-injection resolution (`resolve/2`, `resolve_or_empty/2`, `persona_section/1`); the composer's only YAML-registry I/O. NB: the monks are FROZEN — dormant by design, empty injection everywhere (its `@moduledoc`)
- `Fleet.SPBuilder.RepoSections` — markdown mini-parser lifting the target repo `CLAUDE.md` named sections into the pod `CLAUDE.md`
- `Fleet.SPBuilder.Composer` — the behaviour (test mock + future 2nd vendor)
- `Fleet.SPBuilder.Image` — versioned closed-world snapshot of all SP-builder prompt material, read at boot

## Config & deps
- Knob `:lcars_fleet, :sp_builder_modop_root` — read by the facade; config-overridable, bundled default (rationale on `modop_root/0`).
- Knob `:lcars_fleet, :sp_builder_monk_registry_root` — read by `Monk`; precedence + default in its `@moduledoc`.
- None set in `config/*.exs` or via env var — inline defaults only (tests override via `put_env`/opt).
- Deps: the facade's `use Boundary` declaration (`lib/fleet/sp_builder.ex`).

## Content filter posture (V2)

`Fleet.SPBuilder.RepoSections` lifts repo `CLAUDE.md` sections into the pod `CLAUDE.md` by name —
a closed list of **7**: `Stack`, `Build`, `Test`, `Doc`, `Conventions`, `Commands`, `Gotchas`
(`@repo_section_re`). Sections outside this list are silently dropped; a warning logs if none
matches.

**Content IS filtered.** Every kept section passes through `Fleet.ReceptionFilter.scan/1`
(`admit_section?/2`, BL-6-16): a matching section is **dropped whole** and logged at `error` — the
pod launches with LESS context, never with poison, and a spawn is never wedged over prose. The repo
file is authored OUTSIDE the trust boundary, and this is the door where its content becomes pod
DIRECTIVES. ⚠ `admit_section?/2` is therefore not a redundancy with any upstream check: nothing
else stands between that file and the pod's `CLAUDE.md`.

What this layer does NOT do: judge the legitimacy of the repo itself. The filter reads a
`CLAUDE.md` **section by section**; the adoption door of an externally cloned repo is elsewhere.
