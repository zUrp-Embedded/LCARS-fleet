# fleet_project_bootstrap

Pod-workspace provisioning (Ring 1, pod primitives): clone/reset the project repo
into the pod dir BEFORE spawn, so the agent boots on a vanilla workspace. Pure
functions (File / Path / git), no process.

**This file is a map, not the contract.** Each module owns its contract in its own
`@moduledoc` — read those (`h Fleet.ProjectBootstrap.Phase.Clone` in IEx, or `lib/`).
Nothing here is restated, only pointed at.

## Modules
- `Fleet.ProjectBootstrap.Phase` — bootstrap namespace; carries the only WIRED phase, `Clone`
- `Fleet.ProjectBootstrap.Phase.Clone` — pure clone/reset primitives called directly by `Fleet.Spawner.Pod` (`clone_or_skip/3`, `clone_work_doc/2`, `reset_in_place/3`)
- `Fleet.ProjectBootstrap.Application` — `[]`-children supervisor (umbrella OTP consistency, no process started; `Fleet.Coord.Application` pattern)

## Config & deps
- No app-env knob. The only calibration is the `:git_timeout_ms` opt of `clone_or_skip/3` (default = the `Fleet.Credentials.Shell.git/2` wrapper's 30s).
- Deps: see `mix.exs`.
