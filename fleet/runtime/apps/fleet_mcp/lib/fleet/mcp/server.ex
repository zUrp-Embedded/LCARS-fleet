defmodule Fleet.MCP.Server do
  @moduledoc """
  Boot guard of `fleet_mcp`: the MCP server is system-side, outside bwrap.

  **Containment invariant**: `fleet_mcp` must NEVER start on the pod side (the pod
  is a CLIENT of the server, not its host). This process, supervised by `Fleet.MCP.Supervisor`,
  carries the guard: `start_link/1` reads `:boot_environment` (priority opts > app env >
  default `:host`) and refuses (`{:error, :forbidden_in_pod}`) if `:pod` → the child fails
  → the supervisor fails → the app does not boot inside a pod. Assertable by a
  conformance test (`Process.whereis(Fleet.MCP.Server) == nil` on the pod side).

  ## Why this process exists (and is NOT removed)

  Its former `register_channel`/`list_channels` API (push-channel registry) is
  **removed** here (0 prod callers; the push channel is dead — Anthropic Channel PoC
  failed). BUT the containment guard above is **load-bearing** (tested by the
  conformance): we drop the husk, we KEEP the guard. The pod-facing drive
  (`get_work_item`/`submit_result`) lives in `Fleet.MCP.PodTools`, not here.

  **GenServer with no business state**: the process exists to be the supervised
  child whose `start_link` runs the guard at boot (idle thereafter).
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
  Effective boot environment: `opts[:boot_environment]` >
  `Application.get_env(:fleet_mcp, :boot_environment)` > `:host`.
  Exposed for the conformance test "zero MCP server on the pod side".
  """
  @spec boot_environment(keyword()) :: atom()
  def boot_environment(opts \\ []) do
    Keyword.get(opts, :boot_environment) ||
      Application.get_env(:fleet_mcp, :boot_environment, :host)
  end

  @impl GenServer
  def init(opts), do: {:ok, %{opts: opts}}
end
