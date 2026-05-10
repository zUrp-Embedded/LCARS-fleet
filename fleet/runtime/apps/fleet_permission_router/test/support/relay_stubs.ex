defmodule Fleet.PermissionRouter.RelayStubs do
  @moduledoc """
  Stubs `RelayBackend` pour tests step 4 relay.

    * `Capture` — capture le request dans le mailbox du target pid
      (`Application.get_env :relay_capture_target`). Le test simule
      la réponse via `send(router_pid, {:permission_relay_response, ...})`.
    * `AutoAllow` — envoie immédiatement `:permission_relay_response`
      `:allow` au caller (capture le caller via `Process.get` set
      avant relay).
  """

  defmodule Capture do
    @behaviour Fleet.PermissionRouter.RelayBackend

    @impl Fleet.PermissionRouter.RelayBackend
    def relay_request(ref, payload) do
      case Application.get_env(:fleet_permission_router, :relay_capture_target) do
        pid when is_pid(pid) -> send(pid, {:relay_request, ref, payload})
        _ -> :ok
      end

      :ok
    end
  end

  defmodule AutoAllow do
    @moduledoc """
    Stub `RelayBackend` qui répond immédiatement `:permission_relay_response`
    avec décision `:allow` au caller (le PermissionRouter GenServer process).

    Le caller pid est récupéré via
    `Application.get_env(:fleet_permission_router, :relay_caller_pid)` —
    le test setup doit faire `Application.put_env(:fleet_permission_router,
    :relay_caller_pid, Process.whereis(Fleet.PermissionRouter))` après
    `start_link/1`.
    """

    @behaviour Fleet.PermissionRouter.RelayBackend

    @impl Fleet.PermissionRouter.RelayBackend
    def relay_request(ref, _payload) do
      case Application.get_env(:fleet_permission_router, :relay_caller_pid) do
        pid when is_pid(pid) ->
          send(pid, {:permission_relay_response, %{ref: ref, decision: :allow}})

        _ ->
          :ok
      end

      :ok
    end
  end
end
