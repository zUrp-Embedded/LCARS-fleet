# fleet_credentials

Ring 1 (pod primitives + vendor boundary). Credential + identity primitives for LCARS
pods: the auth model is the **native Anthropic claudeDir** (`~/.claude/.credentials.json`,
per-human, shared across a UID's pods) gated at the spawn-boundary — LCARS stores and
refreshes nothing (delegated to the `claude` binary). Also the single source of the
runtime human, the forge git identity/tokens, and the bounded system-side git wrapper.

**This file is a map, not the contract.** Each module owns its contract in its own
`@moduledoc` — read those (`h Fleet.Credentials.Gate` in IEx, or `lib/`). Nothing here is
restated, only pointed at. The auth-model doctrine (why native claudeDir, the Anthropic
credential precedence, the `NEVER` invariants) is canonical in `adr-f`/`adr-g`/`adr-e`, the
reverse OAuth notes, and the spawner's `Fleet.Spawner.Pod.LaunchEnv` — this app does not re-own it.

## Modules
- `Fleet.Credentials.Gate` — the single spawn-boundary entry point (`validate/2` = scope then plan); where the claudeDir read physically lives; consumed by `Fleet.Spawner.Pod` (`LaunchEnv`)
- `Fleet.Credentials.ScopeValidator` — scope-coverage gate (`oauth_scopes ⊇ role_required_scopes`, per cap-profile flags)
- `Fleet.Credentials.PlanValidator` — paid-plan gate (`claudeAiOauth.subscriptionType`, no SDK/network)
- `Fleet.Credentials.ForgeAuth` — `git_env/0`: system-side git auth env (forge token off the argv, unconditional anti-prompt)
- `Fleet.Credentials.Shell` — `run/3`+`git/2`: external command bounded by construction (kill process-group + wall deadline) + `git_safe_config_args/0` (system-side git config neutralization)
- `Fleet.Credentials.ForgeIdentity` — deliverable git identity (author = human, role = verified `Co-authored-by` trailer); plus the commit-identity gate's `allowed_emails/2` and the system/role identity accessors
- `Fleet.Credentials.Human` — the SINGLE source of "the fleet's human" (`id -un`)
- `Fleet.Credentials.RoleToken` — `token/1`: forge token of a role's account (best-effort, system-token fallback)

Pure library app — no supervisor / `mod:`.

## Config & deps
- Knob `:forge_auth` (`%{url_prefix, token}`) — read by `ForgeAuth`, set by `runtime.exs` from the forge env.
- Knob `:role_tokens_dir` — read by `RoleToken` (default `/home/private`), set by `runtime.exs` from `FORGE_ROLE_TOKENS_DIR`.
- Knob `:forge_identity_override` — test seam read by `ForgeIdentity`, set by `test.exs`.
- Deps: see `mix.exs`.
