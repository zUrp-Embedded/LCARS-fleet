defmodule Fleet.MCP.Server do
  @moduledoc """
  Boot guard of `fleet_mcp`: the MCP server is system-side, outside bwrap.

  **Containment invariant**: `fleet_mcp` must NEVER start on the pod side (the pod
  is a CLIENT of the server, not its host). This process, supervised by `Fleet.MCP.Supervisor`,
  carries the guard: `start_link/1` reads `:boot_environment` (priority opts > app env >
  default **`:pod`**, FAIL-CLOSED) and refuses (`{:error, :forbidden_in_pod}`) on `:pod` → the child
  fails → the supervisor fails → the app does not boot. The HOST declares itself POSITIVELY
  (`config :fleet_mcp, boot_environment: :host` in `runtime.exs` on the daemon boot, and in
  `config/test.exs`); a boot that does NOT declare `:host` is refused BY OMISSION, never started
  permissively. Assertable by a conformance test (`Process.whereis(Fleet.MCP.Server) == nil` pod-side).
  (Residual, wire-time: a pod running the full lcars_fleet BEAM would still run `runtime.exs` → `:host`;
  pods run a `claude` REPL + `bridge.py`, NOT the BEAM, so this is latent — a per-boot host signal from
  `bin/fleet_v2` would harden it further.)

  ## Why this process exists (and is NOT removed)

  Its former `register_channel`/`list_channels` API (push-channel registry) is
  **removed** here (0 prod callers; the push channel is dead — Anthropic Channel PoC
  failed). BUT the containment guard above is **load-bearing** (tested by the
  conformance): we drop the husk, we KEEP the guard. The pod-facing drive
  (`get_work_item`/`submit_result`) lives in `Fleet.MCP.PodTools`, not here.

  **GenServer with no business state**: the process exists to be the supervised
  child whose `start_link` runs the guard at boot (idle thereafter).

  **Last revised**: 2026-07-18
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
  `Application.get_env(:fleet_mcp, :boot_environment)` > **`:pod`** (fail-closed default: absence of
  any positive `:host` declaration → refuse). Exposed for the conformance test "zero MCP server pod-side".
  """
  @spec boot_environment(keyword()) :: atom()
  def boot_environment(opts \\ []) do
    Keyword.get(opts, :boot_environment) ||
      Application.get_env(:fleet_mcp, :boot_environment, :pod)
  end

  @impl GenServer
  def init(opts), do: {:ok, %{opts: opts}}
end
