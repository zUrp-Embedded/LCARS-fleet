defmodule Fleet.MCP.Server do
  @moduledoc """
  Supervised boot guard, idle after initialization. PodTools owns tool dispatch.

  Boot environment resolves from options, then :mcp_boot_environment, then :pod.
  start_link rejects :pod; other values currently start the process, not just :host.
  The default therefore refuses an undeclared boot, but this is a configuration
  guard rather than proof of process origin.

  runtime.exs declares host only with LCARS_HOST_BOOT=1, exported by bin/fleet and
  absent from LaunchEnv's pod whitelist. A direct daemon boot must set it explicitly
  (LCARS_HOST_BOOT=1 iex -S mix); config/test.exs declares host for tests.
  """

  use GenServer

  @name __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start() | {:error, :forbidden_in_pod}
  def start_link(opts \\ []) do
    case boot_environment(opts) do
      :pod -> {:error, :forbidden_in_pod}
      _host -> GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
    end
  end

  @doc """
  Resolves option, application environment, then the fail-closed `:pod` default.
  """
  @spec boot_environment(keyword()) :: atom()
  def boot_environment(opts \\ []) do
    Keyword.get(opts, :boot_environment) ||
      Application.get_env(:lcars_fleet, :mcp_boot_environment, :pod)
  end

  @impl GenServer
  def init(opts), do: {:ok, %{opts: opts}}
end
