# fleet_sp_builder

System Prompt builder/composer (Ring 1): a pure data-transformer turning a
`%Fleet.CapProfile{}` + modop bundles + pod identifiers into a `system-prompt.md`,
a pod `CLAUDE.md`, and a filtered skills list. No process, no state.

**This file is a map, not the contract.** Each module owns its contract in its own
`@moduledoc`/`@spec` (`h Fleet.SPBuilder` in IEx, or `lib/`) — the 6 injection levels
(N0–N3bis), the vendor boundary, the sha256 determinism and every exit code live
there, not restated here.

## Modules
- `Fleet.SPBuilder` — the facade + `Composer` impl (`compose/3`, `compose_claude_md/3`, `filter_skills/2`, `resolve_monk_injection/2` defdelegate); EEx templating (`priv/templates/*.eex`) + role-SP / modop reads + path resolution
- `Fleet.SPBuilder.Monk` — monk-injection resolution (`resolve/2`, `resolve_or_empty/2`, `persona_section/1`); the composer's only YAML-registry I/O
- `Fleet.SPBuilder.RepoSections` — markdown mini-parser lifting the target repo `CLAUDE.md` named sections into the pod `CLAUDE.md`
- `Fleet.SPBuilder.Composer` — the behaviour (test mock + future 2nd vendor)

## Config & deps
- Knob `:fleet_sp_builder, :sp_role_root` — read by the facade; default = bundled cap-profiles canon (rationale on `sp_role_root/0`).
- Knob `:fleet_sp_builder, :modop_root` — read by the facade; config-mandatory fail-loud (rationale on `modop_root/0`).
- Knob `:fleet_sp_builder, :monk_registry_root` — read by `Monk`; precedence + default in its `@moduledoc`.
- None set in `config/*.exs` or via env var — inline defaults only (tests override via `put_env`/opt).
- Deps: see `mix.exs`.
