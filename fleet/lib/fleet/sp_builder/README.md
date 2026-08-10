# Fleet.SPBuilder — domain card

**Date**: 2026-07-13
**Last revised**: 2026-08-10
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
- `Fleet.SPBuilder.Blocks` — block-based composition of the per-role SPs (`priv/sp_builder/sp_blocks/` + `sp-map.yaml`; `mix lcars.sp.gen` writes the flat drafts that `Fleet.Spawner.Pod.Assets` reads, N2); fail-loud no-fallback (no SP → no pod)
- `Fleet.SPBuilder.Monk` — monk-injection resolution (`resolve/2`, `resolve_or_empty/2`, `persona_section/1`); the composer's only YAML-registry I/O. NB: the monks are FROZEN — dormant by design, empty injection everywhere (its `@moduledoc`)
- `Fleet.SPBuilder.RepoSections` — markdown mini-parser lifting the target repo `CLAUDE.md` named sections into the pod `CLAUDE.md`
- `Fleet.SPBuilder.Composer` — the behaviour (test mock + future 2nd vendor)

## Config & deps
- Knob `:fleet_sp_builder, :modop_root` — read by the facade; config-overridable, bundled default (rationale on `modop_root/0`).
- Knob `:fleet_sp_builder, :monk_registry_root` — read by `Monk`; precedence + default in its `@moduledoc`.
- None set in `config/*.exs` or via env var — inline defaults only (tests override via `put_env`/opt).
- Deps: the facade's `use Boundary` declaration (`lib/fleet/sp_builder.ex`).

## Content filter posture (V2)

`Fleet.SPBuilder.RepoSections` lifts repo `CLAUDE.md` sections into the pod `CLAUDE.md` by
**name only** — a closed list of 6: `Stack`, `Build`, `Test`, `Conventions`, `Commands`,
`Gotchas` (regex `@repo_section_re` in `repo_sections.ex:28`). Sections outside this list are
silently dropped; a warning logs if none of the 6 matches.

**Content is not filtered.** Any text inside a matching section is forwarded verbatim into the
pod `CLAUDE.md`. V1 applied a regex doctrinal filter (`ipc-reception-filter.md`); V2 does not —
the NAME whitelist is the boundary, not content inspection.

**This is a KNOWN HOLE, not an assumed posture.** An earlier revision of this file claimed the
absence was deliberate ("the repo CLAUDE.md is operator-controlled"). That claim was never
arbitrated by anyone, and the doctrine it contradicts is still ACTIVE: `ipc-reception-filter.md`
carries status "doctrine active" in the corpus, and its threat vector V3 is verbatim "prompt
injection via contenu projet". A filter mandated by live doctrine and absent from the code is a
regression that was lost in the V1 -> V2 rewrite, not a decision.

Arbitrated 2026-07-29: an externally cloned repo must be filtered and onboarded BEFORE its
content can reach a pod — the trust boundary is the adoption of the repo, not the network it
came from. Until that gate exists, the hole stands as stated here. The closure does NOT belong
at this layer alone (a length cap and a raw `^#` rejection would only blunt the SP-hierarchy
override, leaving a hostile instruction inside a section intact); it belongs at repo adoption.
