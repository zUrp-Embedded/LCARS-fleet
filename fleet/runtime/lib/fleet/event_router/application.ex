defmodule Fleet.EventRouter.Application do
  # Domain supervisor. Deliberately undocumented internal (`@moduledoc false`): the
  # domain's public contract lives in the `Fleet.EventRouter` facade and `Bus`.
  @moduledoc false

  use Supervisor

  # Gitea actions that `WebhooksGitea` can emit (`gitea.<action>`). SINGLE SOURCE:
  # both the atom pre-registration (preregister_event_atoms) AND the registry-coherence
  # guard (test `gitea_event_types/0 ⊆ events.yaml`). Adding an action here WITHOUT the
  # matching events.yaml key = a silent drop in prod → the test breaks (this coherence is
  # locked by the test).
  @gitea_event_types ~w(gitea.opened gitea.closed gitea.push gitea.unknown gitea.reopened
                        gitea.merged gitea.edited gitea.created gitea.synchronized gitea.deleted)

  @doc "Pre-registered gitea event types (= what WebhooksGitea can broadcast)."
  @spec gitea_event_types() :: [String.t()]
  def gitea_event_types, do: @gitea_event_types

  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl Supervisor
  def init(_init_arg) do
    preregister_event_atoms()
    # Loads the events.yaml registry → populates `authorized_event_types` (fail-loud broadcast
    # validation, on in prod, off in test). There is no dispatch GenServer: consumption happens
    # through direct PubSub subscribers, this registry is only an allow-list.
    Fleet.EventRouter.Catalog.load!()

    children =
      base_children() ++
        webhook_children() ++
        signals_children()

    # EXPLICIT restart bounds (aligned with the other app supervisors, e.g. TaskQueue 3/60):
    # past 3 crashes in 60s the child is in a crash loop (webhook listener / SignalsOS that
    # won't stay up) → we escalate to the root app supervisor rather than hammering a restart
    # that won't succeed. The OTP default (3/5) is too tight for a transient blip; we widen it
    # to 60s, made explicit so the window is a choice, not an implicit default.
    # `auto_shutdown: :any_significant`: the Bus escalation (see base_children/0) must reach
    # the NODE mechanically — the significant child's death shuts THIS supervisor down instead
    # of being resurrected into a deaf PubSub.
    Supervisor.init(children,
      strategy: :one_for_one,
      max_restarts: 3,
      max_seconds: 60,
      auto_shutdown: :any_significant
    )
  end

  # Pre-registers the known event_type atoms at boot (from events.yaml + the fixed
  # os.signal.<sig> set) so that dynamic emitters can resolve them via
  # `String.to_existing_atom` instead of `to_atom` — a type forged from the outside
  # therefore creates no atom (atom-leak DoS mitigation).
  defp preregister_event_atoms do
    # Parse events.yaml through the single source `Catalog.event_type_strings/0`
    # (no path-resolution + inline parse duplicated against `Catalog.do_load/0`).
    yaml_events = Fleet.EventRouter.Catalog.event_type_strings()

    signal_events = ~w(os.signal.sigusr1 os.signal.sigterm os.signal.sighup)

    # The gitea webhook broadcasts a dynamic `gitea.<action>` (action from the body or the
    # X-Gitea-Event header). We pre-register the types seen in practice so the canonical
    # `:gitea.<action>` atom resolves via `to_existing_atom`.
    # These types MUST also be events.yaml keys, otherwise `Bus.broadcast` fails loud with
    # `UnregisteredError` → a silent drop of the webhook. Guard: test
    # `gitea_event_types/0 ⊆ registry` (registry_gitea_test.exs).
    # (No `unknown_event` fallback atom: zero producer, zero consumer, zero events.yaml key —
    # the list stays aligned on the registry + the two dynamic families above.)
    Enum.each(
      yaml_events ++ signal_events ++ gitea_event_types(),
      fn event_type ->
        _ = String.to_atom(event_type)
      end
    )
  end

  # Public for the escalation-contract test (like webhook_children/0 for the bind test):
  # the child spec IS the invariant — restart/significant are what make the node-escalation real.
  @doc false
  def base_children do
    # The PubSub sits under a DEDICATED supervisor with `max_restarts: 0`. A LOCAL restart of
    # Phoenix.PubSub would lose ALL of the node's subscriptions: consumers alive but DEAF for
    # life (they only subscribe in init/1), and undetectable (probes test whereis, not the
    # subscription). A PubSub crash → escalation all the way to the node, MECHANICALLY:
    # `restart: :temporary` (a resurrected PubSub with an empty subscription registry would be
    # a success-shaped lie) + `significant: true` + parent `auto_shutdown: :any_significant`
    # → this child's death shuts the domain down → root supervisor `max_restarts: 0` → node.
    # (Assumed posture: a container restart is the only honest resubscription.)
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
  Child specs of the webhook Cowboy listener (public for the bind test: the `:ip` is a
  contract — loopback by default, surface override `LCARS_WEBHOOK_BIND_HOST`).
  Returns `[]` when `:start_webhooks` is `false`.
  """
  def webhook_children do
    if Application.get_env(:fleet_event_router, :start_webhooks, false) do
      port = Application.get_env(:fleet_event_router, :webhook_port, 8081)

      # Child-spec through the single source Fleet.EventRouter.Listener: loopback bind by
      # default applied BY CONSTRUCTION (runtime invariant: a listener does not listen on
      # 0.0.0.0 by accident). The webhook is the ONLY surface whose public exposure is a
      # legitimate need: if the Gitea forge is ON ANOTHER MACHINE, its POSTs cannot reach a
      # loopback. That is exactly the role of the surface override `LCARS_WEBHOOK_BIND_HOST`
      # (e.g. `0.0.0.0`) — a named opt-in that opens ONLY the webhook, not the command surfaces
      # (API, deck). Co-located forge (loopback) → no override needed. The protection stays
      # the HMAC SHA256 over the shared secret, independent of the bind.
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
