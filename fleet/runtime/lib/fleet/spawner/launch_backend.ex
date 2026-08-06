defmodule Fleet.Spawner.LaunchBackend do
  @moduledoc """
  Behaviour to execute `bin/bwrap_launch.sh` → `bin/claude_launch.sh`
  with resolved OAuth ENV vars.

  The default `Fleet.Spawner.LaunchBackend.LauncherPortBackend` uses
  `Port.open/2` (`:spawn_executable`) and returns immediately (interactive
  model, no NDJSON stream to read). Tests swap in
  `Fleet.Spawner.LaunchBackend.StubBackend` to return a canned Port.

  Configurable via:

      config :fleet_spawner, :launch_backend,
        Fleet.Spawner.LaunchBackend.LauncherPortBackend

  ## N1 contract — `.claude.json`

  The N0 projection (`Fleet.Spawner.Pod`) NO LONGER writes `<pod_dir>/.claude.json`: that is
  vendor-schema knowledge. **Every vendor launcher** (`claude_launch.sh` and any future
  `<vendor>_launch.sh`) MUST write `<pod_dir>/.claude.json` BEFORE the exec, with at minimum
  `hasCompletedOnboarding: true` + the 3 remote-control keys
  (`remoteControlAtStartup`/`hasUsedRemoteControl`/`remoteDialogSeen`) — otherwise the RC dialog blocks
  the pod at boot. The `projects` key must be the agent's real CWD (`LCARS_POD_CWD`).

  **Last revised**: 2026-07-18
  """

  @doc """
  Launches a pod via the bwrap_launch → claude_launch chain.

  ## Inputs

    * `args` — map with:
      * `:role` — string
      * `:pod_id` — string
      * `:pod_dir` — absolute pod path
      * `:launcher_path` — absolute path of the N0 launcher chosen by containment
        (`bwrap_launch.sh` default | `host_launch.sh` if containment: none)
      * `:claude_launch_path` — absolute path of `claude_launch.sh`
    * `env` — map of ENV vars to inject (OAuth + custom)

  No `:budget_sec`/`:budget_usd`. The response timeout
  is handled Pod-side (gen_statem) via the native state_timeout `:result_deadline`
  (default per lifetime_scope); no API = no USD budget.

  ## Returns

    * `{:ok, %{port: port, tmux_session: String.t() | nil}}`
      — pod launched (Port opened immediately, interactive model under a PTY)
    * `{:error, reason}` — failure
  """
  @callback launch(args :: map(), env :: %{String.t() => String.t()}) ::
              {:ok, %{required(atom()) => any()}} | {:error, term()}

  # Canonical default: the real spawn backend (Port → bwrap_launch → claude_launch).
  # Set HERE once; tests swap it via config `:launch_backend` (StubBackend).
  @default_backend Fleet.Spawner.LaunchBackend.LauncherPortBackend

  @doc """
  Resolved launch backend: config `:fleet_spawner, :launch_backend`, otherwise the canonical
  default `LauncherPortBackend`. SINGLE SOURCE of the default — the spawner (at spawn time)
  and the readiness check (anti-hollow-green probe) read here; neither re-declares the default,
  so no drift is possible between "what launches" and "what readiness believes is launched".
  """
  @spec resolved() :: module()
  def resolved do
    Application.get_env(:fleet_spawner, :launch_backend, @default_backend)
  end

  @doc """
  `resolved/0` GUARDED (F-C041) — verifies the backend module exports `launch/2` BEFORE it is
  dispatched. A typo'd/absent/`nil` module → `{:error, {:launch_backend_misconfigured, mod}}` (a CLEAR
  deploy-error the caller folds onto `transition_failed`), instead of an `UndefinedFunctionError` raised
  deep in `:launching` that crashes the pod gen_statem WITH NO transition (orphan task + stale state.json).
  `resolved/0` stays a bare-module accessor (Readiness + the MCP path consume it as such) — the conformity
  guard lives HERE, at the dispatch seam. Mirror of `Pod.McpProvision`'s `conforming_provisioner`.
  """
  @spec resolved_conforming() ::
          {:ok, module()} | {:error, {:launch_backend_misconfigured, term()}}
  def resolved_conforming do
    mod = resolved()

    # Side-effect only (trigger load); the real check is `function_exported?` below → discard explicitly.
    _ = Code.ensure_loaded(mod)

    # No `is_atom(mod)` guard: `resolved/0` is typed `module()`, so Dialyzer proves `is_atom`
    # always true → dead `false` branch → RED gate. `function_exported?` alone covers
    # typo/absent/nil (all atoms) — EXACT mirror of `Pod.McpProvision.conforming_provisioner`.
    if function_exported?(mod, :launch, 2) do
      {:ok, mod}
    else
      {:error, {:launch_backend_misconfigured, mod}}
    end
  end
end
