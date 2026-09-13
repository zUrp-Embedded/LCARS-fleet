defmodule Fleet.API.Application do
  @moduledoc """
  Supervises the API's AF_UNIX control listener. Its own socket configuration
  enables it independently of the retired api_start_listener flag.
  Observation serves read views; build information also has an offline CLI reader.
  """

  use Supervisor

  @spec start_link(term()) :: Supervisor.on_start()
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
  Logs build information after the root supervisor starts; returns `:ok`.
  """
  @spec post_boot() :: :ok
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
  Returns the control child spec for a nonempty binary :api_control_socket,
  otherwise `[]`. Tests omit that setting rather than using a TCP-listener flag.
  """
  @spec listener_children() :: [Supervisor.child_spec() | module() | {module(), term()}]
  def listener_children, do: control_socket_child()

  defp control_socket_child do
    case Application.get_env(:lcars_fleet, :api_control_socket) do
      sock when is_binary(sock) and sock != "" -> [Fleet.API.ControlRouter.child_spec(sock)]
      _ -> []
    end
  end
end
