defmodule Fleet.EventRouter.Bus do
  @moduledoc """
  Bus events Phoenix.PubSub instance `Fleet.PubSub` topic
  `fleet.events` + sous-topics `fleet.events.<scope>.<id>` (ex relay
  ch10 `fleet.events.relay.<ref>`).

  ## API — Dual stack pendant migration BL-021 chantier 1

  **Schema canon strict (CIBLE post-migration, DN 11 C3.1+C3.2)** :

    * `broadcast/2 (topic, %Fleet.Event{} = event)` — fail-loud
      `Fleet.Event.SchemaError` si pas struct, `Fleet.Event.UnregisteredError`
      si event.type hors registry events.yaml. Émet la struct directement
      (les subscribers reçoivent `%Fleet.Event{}`, pas un tuple).

  **Compat shim legacy (à retirer chantier 3 BL-021)** :

    * `broadcast/3 (event_type, payload, opts)` — soft validate JSON schema,
      émet `{event_atom, map}` tuple. Conservé pour ne pas casser les
      producteurs/consommateurs avant leur migration.

  **Communs** :

    * `child_spec/1` — pour Application supervisor (instancie `Phoenix.PubSub`)
    * `subscribe/1` / `unsubscribe/1` — gestion abonnements topic
    * `broadcast_subtopic/2` — sous-topics `fleet.events.<scope>.<id>`
    * `authorized_event_types/0` — MapSet atoms chargé au boot par `Catalog.load!/0`
    * `set_authorized_event_types/1` — appelé par `Catalog.load!/0` au boot

  ## Registry obligatoire (C3.2)

  Le set `authorized_event_types` est chargé par `Fleet.EventRouter.Catalog` au boot
  depuis `priv/events.yaml` via `:persistent_term`. Tant que le set
  est vide (boot order), `broadcast/2` laisse passer sans check (initialisation).
  Dès que peuplé, tout event hors set raise `UnregisteredError`.
  """

  require Logger

  @pubsub_name Fleet.PubSub
  @main_topic "fleet.events"

  @doc """
  Child spec Phoenix.PubSub pour Application supervisor.
  """
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_opts), do: Phoenix.PubSub.child_spec(name: @pubsub_name)

  @doc """
  Diffuse un event au schema canon strict `%Fleet.Event{}` sur le topic
  donné (typiquement `"fleet.events"`).

  Fail-loud strict (DN 11 C3.1+C3.2) :

    * raise `Fleet.Event.SchemaError` si event n'est pas une struct `%Fleet.Event{}`
    * raise `Fleet.Event.UnregisteredError` si `event.type` n'est pas dans
      le registry `events.yaml` (set chargé par `Fleet.EventRouter.Catalog` au boot)

  Émet la struct directement — les subscribers reçoivent `%Fleet.Event{}`,
  pas un tuple. Pattern match côté consumer :
  `handle_info(%Fleet.Event{type: :"pod.drift", payload: payload, correlation_id: cid}, state)`.

  ## Returns

    * `:ok` — broadcast effectué
  """
  @spec broadcast(String.t(), Fleet.Event.t() | map()) :: :ok | {:error, term()}
  def broadcast(topic, %Fleet.Event{} = event) when is_binary(topic) do
    assert_authorized!(event)
    Phoenix.PubSub.broadcast(@pubsub_name, topic, event)
  end

  def broadcast(event_type, payload) when is_binary(event_type) and is_map(payload) do
    # Compat shim legacy 2-arity — équivalent à broadcast/3 avec opts = [].
    # ⚠️ Retiré au chantier 3 BL-021 (post-migration tous producteurs vers
    # broadcast/2 (topic, %Fleet.Event{})).
    broadcast(event_type, payload, [])
  end

  @doc """
  Compat shim legacy 3-arity — diffuse un event sur le topic principal `fleet.events`.

  ⚠️ Retiré au chantier 3 BL-021 (post-migration tous producteurs vers
  `broadcast/2 (topic, %Fleet.Event{})`).

  ## Inputs

    * `event_type` — string (ex: `"pod.allocate"`, `"refuse_pattern_match"`)
    * `payload` — map JSON-encodable
    * `opts` :
      * `:ticket_id` — string optionnel
      * `:pod_id` — string optionnel
      * `:attempt_id` — string optionnel
      * `:trace_id` — string optionnel (généré si absent)

  ## Returns

    * `:ok` — broadcast effectué
    * `{:error, reason}` — schema invalide (logged, pas crash)
  """
  @spec broadcast(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def broadcast(event_type, payload, opts)
      when is_binary(event_type) and is_map(payload) and is_list(opts) do
    event = build_event(event_type, payload, opts)

    case validate(event) do
      :ok ->
        Phoenix.PubSub.broadcast(
          @pubsub_name,
          @main_topic,
          {to_event_atom(event_type), event}
        )

      {:error, reason} ->
        Logger.error(
          "fleet_event_router schema invalide: #{inspect(reason)} event_type=#{inspect(event_type)}"
        )

        {:error, reason}
    end
  end

  @doc """
  Set de types d'events autorisés (MapSet d'atomes), chargé depuis
  `events.yaml` au boot par `Fleet.EventRouter.Catalog`.

  Vide tant que le boot n'a pas peuplé le set. `broadcast/2` laisse passer
  sans check tant que vide (initialisation), raise `UnregisteredError`
  dès que peuplé pour tout event hors set.
  """
  @spec authorized_event_types() :: MapSet.t()
  def authorized_event_types do
    :persistent_term.get({__MODULE__, :authorized_event_types}, MapSet.new())
  end

  @doc """
  Set authorized event types (MapSet d'atomes) — appelé par
  `Fleet.EventRouter.Catalog.load!/0` au boot après lecture `events.yaml`.

  Idempotent — peut être ré-appelé via `Fleet.EventRouter.Catalog.load!/0`.
  """
  @spec set_authorized_event_types(MapSet.t()) :: :ok
  def set_authorized_event_types(%MapSet{} = set) do
    :persistent_term.put({__MODULE__, :authorized_event_types}, set)
    :ok
  end

  defp assert_authorized!(%Fleet.Event{type: type} = event) do
    types = authorized_event_types()

    cond do
      MapSet.size(types) == 0 ->
        # Registry pas encore chargé (boot order ou test sans Dispatch) — pass.
        # BL-021 chantier 9 (B) — l'escape hatch est CONSERVÉ comme safety net
        # de boot order. Le flip strict_canon (raise même si registry vide) a
        # été tenté mais nécessite que Dispatch démarre dans TOUS les contextes
        # de test (ou que chaque test setup peuple le registry manuellement) —
        # coût test élevé pour bénéfice marginal (les producteurs sont déjà
        # migrés au schema canon, et le rescue UnregisteredError des appelants
        # protège déjà du raise si un type inconnu passait).
        :ok

      type in types ->
        :ok

      true ->
        raise Fleet.Event.UnregisteredError,
              "event type #{inspect(type)} not in registry events.yaml " <>
                "(source=#{inspect(event.source)}). Add entry to events.yaml or " <>
                "use Fleet.EventRouter.Bus.set_authorized_event_types/1 in tests."
    end
  end

  @doc """
  S'abonne à un topic Phoenix.PubSub. Default `"fleet.events"`.
  """
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(topic \\ @main_topic) when is_binary(topic) do
    Phoenix.PubSub.subscribe(@pubsub_name, topic)
  end

  @doc """
  Désabonne du topic.
  """
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(topic \\ @main_topic) when is_binary(topic) do
    Phoenix.PubSub.unsubscribe(@pubsub_name, topic)
  end

  @doc """
  Diffuse un event vers un sous-topic `fleet.events.<scope>.<id>`
  (ex `fleet.events.relay.<ref>` pour ch10 step 4 relay matching ref).
  """
  @spec broadcast_subtopic(String.t(), term()) :: :ok | {:error, term()}
  def broadcast_subtopic(subtopic, message) when is_binary(subtopic) do
    Phoenix.PubSub.broadcast(@pubsub_name, "#{@main_topic}.#{subtopic}", message)
  end

  defp build_event(event_type, payload, opts) do
    %{
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "event_type" => event_type,
      "ticket_id" => opts[:ticket_id],
      "pod_id" => opts[:pod_id],
      "attempt_id" => opts[:attempt_id],
      "node_id" => Node.self() |> Atom.to_string(),
      "trace_id" => opts[:trace_id] || generate_trace_id(),
      "payload" => payload
    }
  end

  defp validate(event) do
    ExJsonSchema.Validator.validate(resolved_schema(), event)
  end

  defp resolved_schema do
    case :persistent_term.get({__MODULE__, :resolved_schema}, :undefined) do
      :undefined ->
        resolved = ExJsonSchema.Schema.resolve(Fleet.EventRouter.Schema.schema())
        :persistent_term.put({__MODULE__, :resolved_schema}, resolved)
        resolved

      resolved ->
        resolved
    end
  end

  defp to_event_atom(event_type) when is_binary(event_type) do
    String.to_existing_atom(event_type)
  rescue
    ArgumentError ->
      require Logger

      Logger.warning(
        "fleet_event_router unknown event_type atom: #{inspect(event_type)} — using :unknown_event fallback"
      )

      :unknown_event
  end

  @doc """
  Génère un `trace_id` 16-hex (8 bytes crypto strong).
  """
  @spec generate_trace_id() :: String.t()
  def generate_trace_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
