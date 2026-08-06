defmodule Fleet.EventRouter.Application do
  @moduledoc false

  use Supervisor

  @gitea_event_types ~w(gitea.opened gitea.closed gitea.push gitea.unknown gitea.reopened
                        gitea.merged gitea.edited gitea.created gitea.synchronized gitea.deleted)

  @doc "Gitea event types pre-registered by this application."
  @spec gitea_event_types() :: [String.t()]
  def gitea_event_types, do: @gitea_event_types

  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl Supervisor
  def init(_init_arg) do
    preregister_event_atoms()
    Fleet.EventRouter.Catalog.load!()

    children =
      base_children() ++
        webhook_children() ++
        signals_children()

    Supervisor.init(children,
      strategy: :one_for_one,
      max_restarts: 3,
      max_seconds: 60,
      auto_shutdown: :any_significant
    )
  end

  defp preregister_event_atoms do
    yaml_events = Fleet.EventRouter.Catalog.event_type_strings()

    signal_events = ~w(os.signal.sigusr1 os.signal.sigterm os.signal.sighup)

    Enum.each(
      yaml_events ++ signal_events ++ gitea_event_types(),
      fn event_type ->
        _ = String.to_atom(event_type)
      end
    )
  end

  @doc false
  def base_children do
    [
      %{
        id: Fleet.EventRouter.Bus.EscalatingSupervisor,
        type: :supervisor,
        restart: :temporary,
        significant: true,
        start:
          {Supervisor, :start_link,
           [
             [Fleet.EventRouter.Bus],
             [
               strategy: :one_for_one,
               max_restarts: 0,
               name: Fleet.EventRouter.Bus.EscalatingSupervisor
             ]
           ]}
      }
    ]
  end

  @doc """
  Returns the webhook listener child specs, or `[]` when webhooks are disabled.

  The listener binds to loopback unless `LCARS_WEBHOOK_BIND_HOST` overrides it.
  """
  def webhook_children do
    if Application.get_env(:fleet_event_router, :start_webhooks, false) do
      port = Application.get_env(:fleet_event_router, :webhook_port, 8081)

      [
        Fleet.EventRouter.Listener.cowboy_child(
          plug: Fleet.EventRouter.WebhooksGitea,
          port: port,
          surface_env: "LCARS_WEBHOOK_BIND_HOST"
        )
      ]
    else
      []
    end
  end

  defp signals_children do
    if Application.get_env(:fleet_event_router, :start_signals, false) do
      [Fleet.EventRouter.SignalsOS]
    else
      []
    end
  end
end
