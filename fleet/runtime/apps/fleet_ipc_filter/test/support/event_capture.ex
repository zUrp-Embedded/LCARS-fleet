defmodule Fleet.IpcFilter.EventCapture do
  @moduledoc """
  Stub `EventBackend` capturant les broadcasts dans le mailbox du
  process listener configuré via `Application.put_env(:fleet_ipc_filter,
  :event_capture_target, self())`.

  Format message : `{:ipc_event, event_name, payload}`.
  """

  @behaviour Fleet.IpcFilter.EventBackend

  @impl Fleet.IpcFilter.EventBackend
  def broadcast(event, payload) do
    case Application.get_env(:fleet_ipc_filter, :event_capture_target) do
      pid when is_pid(pid) -> send(pid, {:ipc_event, event, payload})
      _ -> :ok
    end

    :ok
  end
end
