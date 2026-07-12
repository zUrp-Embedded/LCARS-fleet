defmodule Fleet.Spawner.McpSocketProvisioner do
  @moduledoc """
  Behaviour of the per-pod MCP socket provisioner — the CONTRACT of the runtime
  seam `:mcp_socket_provisioner`, consumed by `Fleet.Spawner.Pod.McpProvision`
  (`:projecting` states / the Pod's `terminate/3` safety net).

  ## Why a RUNTIME seam (and not a compile dep)

  `fleet_spawner` is Ring 1, `fleet_mcp` is Ring 2 (above): a mix.exs dep
  `fleet_spawner → fleet_mcp` would be an UPWARD dep (low ring → high ring),
  FORBIDDEN by the layering. The module is therefore resolved at RUNTIME (`resolved/0`:
  app-env + default as a literal atom → NO compile-time dep, hence no cycle).
  The umbrella starts all the apps → the real impl is live when a pod
  runs. Seam declared in `fleet_event_router/priv/allowed_graph.yaml`
  (`seams` section, `up` direction) — the contract lives HERE, at the CONSUMER.

  ## Implementations

    * `Fleet.MCP.PodSocketSupervisor` — REAL impl (canonical default). It lives in
      `fleet_mcp`, which does NOT depend on `fleet_spawner`: it CANNOT adopt
      this behaviour (`@behaviour` = a compile reference, would create the forbidden edge)
      and stays DUCK-TYPED, with a cross-reference comment in its moduledoc. This
      module is the SOURCE OF TRUTH of the contract — any evolution propagates
      to both sides by hand.
    * `Fleet.Spawner.MCPSocketStub` — test stub (same app → adopts the behaviour,
      the compiler checks conformance). Returns a path under tmp WITHOUT creating
      a socket; set by `config/test.exs` (mirror of `launch_backend: StubBackend`).
  """

  @doc """
  ENSURE (before the launch): creates this pod's listener + socket file and
  returns the HOST PATH of the socket file. Idempotent (re-call → same path,
  no duplicate). The file MUST exist on return: otherwise the bwrap bind would
  fail (the launcher mounts the socket into the pod's sandbox).
  """
  @callback ensure_pod_socket(pod_id :: String.t(), tools :: [String.t()]) ::
              {:ok, Path.t()} | {:error, term()}

  @doc """
  RELEASE (teardown): stops the listener AND removes the socket file (closing the
  socket frees the FD, NOT the file). Idempotent — releasing an already-freed
  pod returns `:ok`.
  """
  @callback release_pod_socket(pod_id :: String.t()) :: :ok

  # Canonical default: the real impl on the fleet_mcp side. Literal atom (not a
  # literal remote call) → no compile-time dep. Set HERE once.
  @default_provisioner Fleet.MCP.PodSocketSupervisor

  @doc """
  Resolved provisioner: config `:fleet_spawner, :mcp_socket_provisioner` otherwise the
  canonical default `Fleet.MCP.PodSocketSupervisor`. SINGLE SOURCE of the default (same
  pattern as `Fleet.Spawner.LaunchBackend.resolved/0`) — the only runtime reader
  is `Pod.McpProvision`, any future reader goes through here instead of re-declaring.
  """
  @spec resolved() :: module()
  def resolved do
    Application.get_env(:fleet_spawner, :mcp_socket_provisioner, @default_provisioner)
  end
end
