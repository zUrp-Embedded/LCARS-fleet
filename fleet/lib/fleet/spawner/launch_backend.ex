defmodule Fleet.Spawner.LaunchBackend do
  @moduledoc """
  Launch-backend boundary for interactive pods. The configured default opens the selected
  N0 launcher with resolved environment and returns the owned Port immediately.

  Vendor launchers, not `Fleet.Spawner.Pod`, own `.claude.json` projection before exec,
  including onboarding, remote-control, and real-CWD project keys.
  """

  @doc """
  Launches a pod from resolved paths and a string environment.

  Returns an owned Port and optional tmux session immediately, or a typed error. Response
  deadlines belong to the Pod state machine rather than this interactive backend.
  """
  @callback launch(args :: map(), env :: %{String.t() => String.t()}) ::
              {:ok, %{required(atom()) => any()}} | {:error, term()}

  @default_backend Fleet.Spawner.LaunchBackend.LauncherPortBackend

  @doc "Returns the configured backend or the canonical Port backend."
  @spec resolved() :: module()
  def resolved do
    Application.get_env(:lcars_fleet, :spawner_launch_backend, @default_backend)
  end

  @doc """
  Resolves the backend and verifies that it exports `launch/2` before dispatch.

  Misconfiguration returns `{:error, {:launch_backend_misconfigured, module}}`.
  """
  @spec resolved_conforming() ::
          {:ok, module()} | {:error, {:launch_backend_misconfigured, term()}}
  def resolved_conforming do
    mod = resolved()

    _ = Code.ensure_loaded(mod)

    # F-C041
    if function_exported?(mod, :launch, 2) do
      {:ok, mod}
    else
      {:error, {:launch_backend_misconfigured, mod}}
    end
  end
end
