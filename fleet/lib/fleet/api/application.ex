defmodule Fleet.API.Application do
  @moduledoc """
  Supervises the API domain's TCP read/WebSocket listener and optional AF_UNIX
  control listener.

  `:http_port` is required when `:start_listener` is true. The TCP dispatch
  sends `/ws` to `Fleet.API.WS` and all other requests to `Fleet.API.Rest`.
  `:control_socket`, when set, adds the sole admin-write listener.
  """

  use Supervisor

  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl Supervisor
  def init(_init_arg) do
    children = listener_children()

    opts = [strategy: :one_for_one, max_restarts: 3, max_seconds: 60]

    Supervisor.init(children, opts)
  end

  @doc """
  Logs build information after the root supervisor has started. Always returns
  `:ok`.
  """
  def post_boot do
    log_build_info()
    :ok
  end

  defp log_build_info do
    info = Fleet.API.BuildInfo.current()
    dirty = if info.dirty, do: "-dirty", else: ""
    require Logger

    Logger.info(
      "API: LCARS fleet — build #{info.sha}#{dirty} ref=#{info.ref} (source=#{info.source})"
    )
  end

  @doc """
  Returns the configured TCP and control listener child specs, or `[]` when
  listener startup is disabled.
  """
  def listener_children do
    if Application.get_env(:lcars_fleet, :api_start_listener, true) do
      port = Application.fetch_env!(:lcars_fleet, :api_http_port)

      dispatch = [
        {:_,
         [
           {"/ws", Fleet.API.WS, []},
           {:_, Plug.Cowboy.Handler, {Fleet.API.Rest, []}}
         ]}
      ]

      tcp =
        Fleet.EventRouter.Listener.cowboy_child(
          plug: Fleet.API.Rest,
          port: port,
          dispatch: dispatch
        )

      [tcp | control_socket_child()]
    else
      []
    end
  end

  defp control_socket_child do
    case Application.get_env(:lcars_fleet, :api_control_socket) do
      sock when is_binary(sock) and sock != "" -> [Fleet.API.ControlRouter.child_spec(sock)]
      _ -> []
    end
  end
end
