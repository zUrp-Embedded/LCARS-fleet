defmodule Fleet.EventRouter.Bus do
  @moduledoc """
  Bus events Phoenix.PubSub instance `Fleet.PubSub` topic `fleet.events`.

  ## API — schema canon strict

    * `broadcast/2 (topic, %Fleet.Event{} = event)` — émet la struct directement
      (les subscribers reçoivent `%Fleet.Event{}`, pas un tuple). Fail-loud
      `Fleet.Event.UnregisteredError` si `event.type` hors registry events.yaml.

  ## Communs

    * `child_spec/1` — pour Application supervisor (instancie `Phoenix.PubSub`)
    * `subscribe/1` / `unsubscribe/1` — gestion abonnements topic
    * `authorized_event_types/0` — MapSet atoms chargé au boot par `Catalog.load!/0`
    * `set_authorized_event_types/1` — appelé par `Catalog.load!/0` au boot

  ## Pourquoi struct-only (pas de shim tuple)

  Il n'existe AUCUNE variante `broadcast(event_type, payload[, opts])` qui construirait
  un event + soft-validerait un JSON + émettrait un tuple `{atom, map}`. TOUS les
  producteurs (pod, executor, starfleet, coord, webhooks, signals) émettent la struct
  via `broadcast/2`. C'est pourquoi il n'y a ni `Fleet.Event.SchemaError` ni
  `Fleet.EventRouter.Schema` : pas de soft-validate JSON, la seule validation est le
  registry (`UnregisteredError`).

  ## Registry obligatoire

  Le set `authorized_event_types` est chargé par `Fleet.EventRouter.Catalog` au boot
  depuis `priv/events.yaml` via `:persistent_term`. Dès que peuplé, tout event hors
  set raise `UnregisteredError`.

  Le comportement quand le set est VIDE (boot précoce / test `load_event_registry:
  false`) est **explicite** via `:fleet_event_router, :permit_when_registry_empty` :
  `true` (défaut) = laisse passer (safety-net d'init voulu) ; `false` = fail-closed
  (raise tant que le registry n'est pas chargé). Voir `assert_authorized!/1`.
  """

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

  Fail-loud strict : raise `Fleet.Event.UnregisteredError` si `event.type`
  n'est pas dans le registry `events.yaml` (set chargé par
  `Fleet.EventRouter.Catalog` au boot).

  Émet la struct directement — les subscribers reçoivent `%Fleet.Event{}`,
  pas un tuple. Pattern match côté consumer :
  `handle_info(%Fleet.Event{type: :"pod.drift", payload: payload, correlation_id: cid}, state)`.
  """
  @spec broadcast(String.t(), Fleet.Event.t()) :: :ok | {:error, term()}
  def broadcast(topic, %Fleet.Event{} = event) when is_binary(topic) do
    assert_authorized!(event)
    Phoenix.PubSub.broadcast(@pubsub_name, topic, event)
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

  # Comportement quand le registry est VIDE — rendu EXPLICITE et configurable, plus un trou silencieux.
  #
  # Le registry est vide dans deux situations légitimes : (1) au boot, entre le démarrage du Bus et
  # `Catalog.load!/0` qui le peuple ; (2) en test avec `load_event_registry: false` (hermétisme — pas
  # de boot complet pour valider un type). Dans ces fenêtres, valider contre un set vide rejetterait
  # TOUT event. Le flag `:permit_when_registry_empty` choisit le régime :
  #
  #   * `true` (défaut) — registry vide ⇒ on LAISSE PASSER. Safety-net VOULU : ne pas casser le boot
  #     précoce ni forcer chaque test à peupler le registry à la main. Ce n'est PAS une validation
  #     désactivée — dès que le set est peuplé (`Catalog.load!` au boot, juste après le démarrage du
  #     Bus), la branche `type in types` tranche et tout event hors registry raise. Les producteurs
  #     émettent déjà tous le schema canon, et le rescue `UnregisteredError` côté appelants couvre le
  #     résidu. C'est une admission INTENTIONNELLE de la fenêtre d'init, pas un by-pass silencieux.
  #   * `false` — registry vide ⇒ FAIL-CLOSED (raise `UnregisteredError`). Pour un déploiement qui
  #     veut interdire tout broadcast tant que le registry n'est pas chargé (aucun event ne doit
  #     partir non validé, même au boot). À n'activer que si le boot garantit `Catalog.load!` AVANT
  #     le 1er broadcast, sinon le boot lui-même crashe.
  @permit_empty_default true

  defp assert_authorized!(%Fleet.Event{type: type} = event) do
    types = authorized_event_types()

    cond do
      MapSet.size(types) == 0 ->
        if permit_when_registry_empty?() do
          :ok
        else
          raise Fleet.Event.UnregisteredError,
                "registry events.yaml VIDE et :permit_when_registry_empty = false (fail-closed) — " <>
                  "broadcast de #{inspect(type)} (source=#{inspect(event.source)}) refusé tant que " <>
                  "le registry n'est pas chargé (Catalog.load!/0 doit tourner avant tout broadcast)."
        end

      type in types ->
        :ok

      true ->
        raise Fleet.Event.UnregisteredError,
              "event type #{inspect(type)} not in registry events.yaml " <>
                "(source=#{inspect(event.source)}). Add entry to events.yaml or " <>
                "use Fleet.EventRouter.Bus.set_authorized_event_types/1 in tests."
    end
  end

  # Flag de régime registry-vide. Défaut `true` (safety-net d'init voulu). Lu à chaque broadcast
  # (pas mémoïsé) → un test peut le flipper sans redémarrer le Bus.
  defp permit_when_registry_empty? do
    Application.get_env(:fleet_event_router, :permit_when_registry_empty, @permit_empty_default)
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
end
