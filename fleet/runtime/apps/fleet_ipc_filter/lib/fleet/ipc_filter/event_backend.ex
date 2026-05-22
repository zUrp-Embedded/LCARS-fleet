defmodule Fleet.IpcFilter.EventBackend do
  @moduledoc """
  Behaviour wrap autour de la diffusion events `:refuse_pattern_match`
  + `:pod_drift` vers le bus PubSub fleet_event_router (chantier 11).

  Permet de différer la dep `:phoenix_pubsub` jusqu'au câblage chantier
  11 — cohérent pattern Backend ch3/ch6/ch8 PROMOTED.
  """

  @callback broadcast(event :: atom(), payload :: map()) :: :ok | {:error, term()}
end

defmodule Fleet.IpcFilter.EventBackend.NotWiredYet do
  @moduledoc """
  Backend placeholder hermétique (défaut env `:test`). Retourne `:ok`
  sans effet de bord — `fleet_ipc_filter` reste fonctionnel sans bus
  câblé (decision allow/deny correcte, pas de broadcast cross-pod).
  """

  @behaviour Fleet.IpcFilter.EventBackend

  @impl Fleet.IpcFilter.EventBackend
  def broadcast(_event, _payload), do: :ok
end

defmodule Fleet.IpcFilter.EventBackend.PubSub do
  @moduledoc """
  Backend RÉEL (B4 #576, chantier 11 wiré) — diffuse vers
  `Fleet.EventRouter.Bus` (Phoenix.PubSub `Fleet.PubSub`, topic
  `fleet.events`). Défaut prod/dev via `config/config.exs` ; `:test`
  override → `NotWiredYet` (hermétique, `config/test.exs`).

  Le behaviour ipc_filter passe `event :: atom()` interne
  (`:refuse_pattern_match` / `:pod_drift`). `Bus.broadcast/3` attend
  l'`event_type` **canonique du catalogue** `events.yaml` ; sinon
  `Bus.to_event_atom` (`String.to_existing_atom`) tombe en
  `:unknown_event` → routing consumers cassé (fake-wired). Mapping
  **explicite** vers les clés catalogue (anti-M1 #P5 : irrégulier —
  `:pod_drift` → `pod.drift`, PAS un transform algorithmique) :

    * `:refuse_pattern_match` → `"pod.refuse_pattern_match"`
    * `:pod_drift`            → `"pod.drift"`

  Extraction `pod_id`/`ticket_id` (clés atom OU string, défensif)
  pour l'enveloppe Bus.
  """

  @behaviour Fleet.IpcFilter.EventBackend

  # Mapping atome interne ipc_filter → event_type canon events.yaml.
  @event_type %{
    refuse_pattern_match: "pod.refuse_pattern_match",
    pod_drift: "pod.drift"
  }

  @impl Fleet.IpcFilter.EventBackend
  def broadcast(event, payload) when is_atom(event) and is_map(payload) do
    case Map.fetch(@event_type, event) do
      {:ok, event_type} ->
        Fleet.EventRouter.Bus.broadcast(event_type, payload,
          pod_id: fetch(payload, :pod_id),
          ticket_id: fetch(payload, :ticket_id)
        )

      :error ->
        # Défensif : ipc_filter n'émet que ces 2 events (vérifié
        # ipc_filter.ex:127/187). Un event inattendu = bug amont,
        # signalé non-silencieux plutôt que fake-broadcast.
        {:error, {:unmapped_event, event}}
    end
  end

  defp fetch(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
