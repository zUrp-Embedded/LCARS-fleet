defmodule Fleet.EventRouter.Application do
  @moduledoc false

  use Supervisor

  @gitea_event_types ~w(gitea.opened gitea.closed gitea.push gitea.unknown gitea.reopened
                        gitea.merged gitea.edited gitea.created gitea.synchronized gitea.deleted)

  @doc "Gitea event types pre-registered by this application."
  @spec gitea_event_types() :: [String.t()]
  def gitea_event_types, do: @gitea_event_types

  # An injected function can deliver then return an error, causing completion retries to
  # duplicate downstream work. Warn once at init rather than per emission; the bus reads the
  # seam hot, so later changes are not announced. Any non-nil value warns, even if not callable.
  # This warning permits boot and does not establish atomic delivery across main/pod broadcasts.
  defp warn_if_broadcast_seam_declared do
    case Application.get_env(:lcars_fleet, :event_router_broadcast_fun) do
      nil ->
        :ok

      other ->
        require Logger

        Logger.error(
          "EventRouter: `:broadcast_fun` is DECLARED at boot (#{inspect(other)}) — the bus is " <>
            "replaced by an injected function. This is a TEST seam: if it delivers and then " <>
            "returns {:error, _}, the completion rail's all-or-nothing assumption (CI-03) is " <>
            "false, work items are not committed while downstream already ran, and honest " <>
            "re-submits duplicate that work. Remove it from the deployed config."
        )
    end
  end

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl Supervisor
  def init(_init_arg) do
    preregister_event_atoms()
    warn_if_broadcast_seam_declared()
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

    # Pre-register trusted catalogue/webhook names for to_existing_atom consumers. Add OS
    # signal types with their producer, not speculatively; these atoms are not garbage-collected.
    Enum.each(
      yaml_events ++ gitea_event_types(),
      fn event_type ->
        _ = String.to_atom(event_type)
      end
    )
  end

  @doc false
  @spec base_children() :: [Supervisor.child_spec() | module() | {module(), term()}]
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

  BindAddress chooses loopback by default; LCARS_WEBHOOK_BIND_HOST takes precedence over
  the global LCARS_BIND_HOST override.
  """
  @spec webhook_children() :: [Supervisor.child_spec() | module() | {module(), term()}]
  def webhook_children do
    if Application.get_env(:lcars_fleet, :event_router_start_webhooks, false) do
      port = Application.get_env(:lcars_fleet, :event_router_webhook_port, 8081)

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
    if Application.get_env(:lcars_fleet, :event_router_start_signals, false) do
      [Fleet.EventRouter.SignalsOS]
    else
      []
    end
  end
end
