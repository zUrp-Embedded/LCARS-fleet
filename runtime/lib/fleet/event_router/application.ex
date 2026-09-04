defmodule Fleet.EventRouter.Application do
  @moduledoc false

  use Supervisor

  @gitea_event_types ~w(gitea.opened gitea.closed gitea.push gitea.unknown gitea.reopened
                        gitea.merged gitea.edited gitea.created gitea.synchronized gitea.deleted)

  @doc "Gitea event types pre-registered by this application."
  @spec gitea_event_types() :: [String.t()]
  def gitea_event_types, do: @gitea_event_types

  # THE ONE INVARIANT THE COMPLETION RAIL RESTS ON, AND THE ONE SEAM THAT CAN TURN IT OFF.
  #
  # `Broadcast.required/3` treats an `{:error, _}` from the bus as "ZERO subscriber was delivered",
  # and the whole non-commit-on-failed-broadcast discipline (CI-03) depends on that being true. It
  # holds on the mono-node Phoenix.PubSub because both of its failure modes are pre-dispatch.
  #
  # `:broadcast_fun` replaces that bus with an arbitrary 3-arity function, read HOT on every
  # broadcast, with no environment guard. A function that DELIVERS and then returns `{:error, _}`
  # reproduces partial delivery exactly: the item is not committed, the downstream already left,
  # and the honest re-submit sends it a second time. It is a test seam, and nothing stopped it from
  # being declared in a config file.
  #
  # Checked at BOOT and not per-call, deliberately: the dangerous form is the one DECLARED in
  # config, and it is the only one visible here. A test that sets it with `put_env` after boot
  # stays silent, and that is the intent — a line on every broadcast would be noise nobody reads,
  # which is the same as no line at all.
  #
  # It LOGS and boots rather than refusing: the seam is legitimate machinery, and a node that will
  # because someone left a debug hook is a worse failure than one that says so loudly.
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

    # NO hard-coded signal atoms here (BL-6-43). Pre-registering `os.signal.*` for a producer that
    # does not exist creates atoms at EVERY boot for a broadcast nothing can emit — and a
    # transitively-dormant key outlives the reason anyone could name for it. Whoever lands the real
    # producer adds its types IN THE SAME GESTURE, which is the only moment their presence means
    # anything.
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

  The listener binds to loopback unless `LCARS_WEBHOOK_BIND_HOST` overrides it.
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
