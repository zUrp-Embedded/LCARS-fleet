# Fleet.Credentials — domain card

**Date**: 2026-07-11
**Last revised**: 2026-09-04
**Status**: active — domain card
**Referenced by**: —

Pod primitives. Credential + identity primitives for LCARS
pods: the auth model is the **native Anthropic claudeDir** (`~/.claude/.credentials.json`,
per-human, shared across a UID's pods) gated at the spawn-boundary — LCARS stores and
refreshes nothing (delegated to the `claude` binary). Also the single source of the
runtime human, the forge git identity/tokens, and the bounded system-side git wrapper.

**This file is a map, not the contract.** Each module owns its contract in its own
`@moduledoc` — read those (`h Fleet.Credentials.Gate` in IEx, or `lib/`). Nothing here is
restated, only pointed at. The auth-model doctrine (why native claudeDir, the Anthropic
credential precedence, the `NEVER` invariants) is applied by the spawner's
`Fleet.Spawner.Pod.LaunchEnv`, whose `@moduledoc` states it — this domain does not re-own it.

## Modules
- `Fleet.Credentials.Gate` — the single spawn-boundary entry point (`validate/1` = login-validity check: is the human logged in to Claude Code? `{:credentials_invalid, _}` on no login); where the claudeDir read physically lives; consumed by `Fleet.Spawner.Pod` (`LaunchEnv`)
- `Fleet.Credentials.ForgeAuth` — `git_env/0`: system-side git auth env (forge token off the argv, unconditional anti-prompt)
- `Fleet.Credentials.Shell` — `run/3`+`git/2`: external command bounded by construction (kill process-group + wall deadline) + `git_safe_config_args/0` (system-side git config neutralization)
- `Fleet.Credentials.ForgeIdentity` — deliverable git identity (author = human, role = verified `Co-authored-by` trailer); plus the commit-identity gate's `allowed_emails/2` and the system/role identity accessors
- `Fleet.Credentials.Human` — the SINGLE source of "the fleet's human" (`id -un`)
- `Fleet.Credentials.RoleToken` — `token/1`: forge token of a role's account (reports `nil` if absent/empty; policy-neutral, callers fail-closed via `RoleIdentity`)
- `Fleet.Credentials.RoleIdentity` — smart-constructor "act as role X on the forge": unbuildable without a verified token (the fail-closed policy over `RoleToken`)

Pure library domain — no supervisor.

## Config & deps
- Knob `:lcars_fleet, :credentials_forge_auth` (`%{url_prefix, account}`) — read by `ForgeAuth`, set by `runtime.exs` from the forge env. ⚠ It carries an ACCOUNT NAME, never a token: the credential is asked of the authority service at the instant it is used.
- Knob `:lcars_fleet, :credentials_authority_socket` — read by `Authority` (default `/run/lcars/authority/roles.sock`), overridable because a witness cannot bind in `/run`.
- ⚠ `:credentials_role_tokens_dir` — the BEAM opens no token file: it asks `roles.sock`, and the authority service resolves `<dir>/<account>.gitea_token` on its side. The knob's only BEAM reader is `RoleToken.path_for/1`, which NAMES the file for the test suite's fixtures; it otherwise steers `runtime.exs` and the authority double.
- Knob `:lcars_fleet, :credentials_forge_identity_override` — test seam read by `ForgeIdentity`, set by `test.exs`.
- Deps: the facade's `use Boundary` declaration (`lib/fleet/credentials.ex`).
