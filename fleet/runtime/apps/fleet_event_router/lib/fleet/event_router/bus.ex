defmodule Fleet.EventRouter.Bus do
  @moduledoc """
  Bus events Phoenix.PubSub instance `Fleet.PubSub` topic `fleet.events`.

  ## API — schema canon strict

    * `broadcast/2 (topic, %Fleet.Event{} = event)` — émet la struct directement
      (les subscribers reçoivent `%Fleet.Event{}`, pas un tuple). Fail-loud
      `Fleet.Event.UnregisteredError` si `event.type` hors registry events.yaml.

  ## Communs

    * `child_spec/1` — pour Application supervisor (instancie `Phoenix.PubSub`)
    * `main_topic/0` — le topic principal (`"fleet.events"`), autorité centrale du
      littéral. Producteurs/consommateurs passent par ici plutôt que de retaper la string.
    * `broadcast_main/1` — `broadcast(main_topic(), event)`, raccourci canon.
    * `emit/3` — `Fleet.Event.new(source, type, opts) |> broadcast_main()`, l'idiome
      producteur « construire un event canon + broadcaster main » en un appel.
    * `safe_emit/3-4` — variante PROTÉGÉE d'`emit/3` pour les émetteurs best-effort
      (observabilité/escalade) : politique d'erreur UNIFIÉE (boot-order toléré,
      bug de construction loggé, jamais un crash de l'émetteur).
    * `subscribe/1` / `unsubscribe/1` — gestion abonnements topic (défaut `main_topic/0`)
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

  require Logger

  @pubsub_name Fleet.PubSub
  @main_topic "fleet.events"

  @doc """
  Child spec Phoenix.PubSub pour Application supervisor.
  """
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_opts), do: Phoenix.PubSub.child_spec(name: @pubsub_name)

  @doc """
  Topic principal du bus (`"fleet.events"`) — l'unique substrat broadcast/subscribe.

  Autorité centrale du littéral : tout producteur (`broadcast_main/1`) et
  consommateur (`subscribe/0`) résout le topic ici plutôt que de retaper la string,
  ce qui garantit qu'un producteur et un consommateur matchent toujours le même topic.
  """
  @spec main_topic() :: String.t()
  def main_topic, do: @main_topic

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
  Diffuse un event sur le topic principal (`main_topic/0`) — raccourci
  `broadcast(main_topic(), event)`, même sémantique fail-loud registry que
  `broadcast/2`.

  À préférer partout où le topic est le topic principal (cas quasi-universel) :
  centralise le littéral `"fleet.events"` derrière l'autorité.
  """
  @spec broadcast_main(Fleet.Event.t()) :: :ok | {:error, term()}
  def broadcast_main(%Fleet.Event{} = event), do: broadcast(@main_topic, event)

  @doc """
  Construit un `%Fleet.Event{}` via `Fleet.Event.new/3` et le diffuse sur le topic
  principal via `broadcast_main/1` — un seul appel pour l'idiome producteur
  « construire l'enveloppe canon + broadcaster main », répété sur ~10 sites.

  Factorise UNIQUEMENT la construction + le broadcast : `emit/3` ne rescue rien, ne
  classe rien. Deux régimes d'erreur existent chez les producteurs :

    * **best-effort** (observabilité/escalade, fire-and-forget) — la politique est
      UNIFIÉE dans `safe_emit/3-4` ci-dessous. Ne PAS ré-implémenter un rescue local
      autour d'`emit/3` : c'est exactement la duplication que `safe_emit` a résorbée.
    * **spécifique à la surface** — le producteur garde SA politique AUTOUR d'`emit/3` :
      surface HTTP `{:error, msg}` côté API, propagation load-bearing côté spawner
      (`Fleet.Spawner.Pod.Events.required_broadcast/2`).

  Retour : celui de `broadcast_main/1` (`:ok | {:error, term()}`). Peut LEVER
  `Fleet.Event.UnregisteredError` (type hors registry) ou `ArgumentError`/`FunctionClauseError`
  (source hors enum, timestamp non-`%DateTime{}`) — délibérément non attrapées ici, à charge
  du caller qui décide de sa politique.
  """
  @spec emit(Fleet.Event.source(), atom(), keyword()) :: :ok | {:error, term()}
  def emit(source, type, opts \\ []) do
    event = Fleet.Event.new(source, type, opts)
    broadcast_main(event)
  end

  @doc """
  Variante PROTÉGÉE d'`emit/3` — le cœur UNIQUE de l'idiome « émission-Bus-protégée »,
  qui était dupliqué sur 7 sites / 3 apps (coord policies, starfleet cat5/boot/
  mcp_monitor/mcp_watcher, spawner pod events) avec des rescue locaux aux comportements
  INCOHÉRENTS (certains avalaient tout en silence, d'autres propageaient). Une seule
  autorité désormais : ici, Ring 0, à côté d'`emit/3` dont elle partage la signature.

  4e argument `safe_opts` :

    * `:on_unregistered` — politique face à `Fleet.Event.UnregisteredError` (type hors
      registry `events.yaml`, typiquement la fenêtre de boot où le registry n'est pas
      encore peuplé par `Catalog.load!/0`) :
        * `:log` (défaut) — `Logger.warning` puis `:ok` : l'event est perdu mais la
          perte reste VISIBLE.
        * `:silent` — `:ok` muet : pour les émetteurs dont la fenêtre boot-order est un
          cas NOMINAL (orchestrateur de boot, escalades pré-registry) — un warning à
          chaque boot serait du bruit, pas un signal.
    * `:context` — préfixe du message de log (ex. `"MCPMonitor: alerte mcp.server_crashed
      NON émise"`) : porte le contexte MÉTIER de l'émetteur dans le log centralisé, sans
      que chaque site ré-implémente son propre rescue juste pour personnaliser un message.

  ## Contrat d'erreur (le POURQUOI de chaque branche)

    * `Fleet.Event.UnregisteredError` → toléré selon `:on_unregistered` (boot-order),
      retourne `:ok`.
    * `ArgumentError` / `FunctionClauseError` → bug de CONSTRUCTION de l'event (source
      hors enum, timestamp non-`%DateTime{}`, opts non-keyword, nom de type jamais
      préregistré), PAS un aléa runtime : TOUJOURS `Logger.error` + `:ok`. Jamais avalé
      muet — une escalade/alerte qui disparaît en silence est indiagnosticable. Jamais
      propagé — l'émetteur best-effort (GenServer moniteur, Task de boot, gen_statem pod)
      ne doit JAMAIS crasher pour un défaut d'OBSERVABILITÉ : le laisser crasher ferait
      boucler son superviseur sur un producteur malformé.

  Le `type` accepte aussi un binaire, converti via `String.to_existing_atom/1` SOUS la
  protection du rescue (anti atom-leak) : un nom de type jamais préregistré est classé
  bug de construction (loggé), jamais un crash. C'est ce qui permet aux producteurs qui
  SYNTHÉTISENT le nom du type (`"starfleet.audit_cat5_\#{source}"`, `event_type` binaire
  côté pod) de ne garder AUCUN rescue local.

  Ce que `safe_emit` N'EST PAS : le chemin des events LOAD-BEARING. Un `pod.completed`
  aplati en `:ok` loggé serait indistinguable d'un succès et wedgerait le step_run
  (verrou forge à vie) — ce chemin doit PROPAGER l'échec à son appelant, cf.
  `Fleet.Spawner.Pod.Events.required_broadcast/2`, volontairement HORS de ce cœur.

  Retour : `:ok` (émis, ou échec toléré/loggé) | `{:error, reason}` (passthrough
  `Phoenix.PubSub.broadcast/3`).
  """
  @spec safe_emit(Fleet.Event.source(), atom() | String.t(), keyword(), keyword()) ::
          :ok | {:error, term()}
  def safe_emit(source, type, opts \\ [], safe_opts \\ []) do
    emit(source, coerce_type(type), opts)
  rescue
    e in Fleet.Event.UnregisteredError ->
      case Keyword.get(safe_opts, :on_unregistered, :log) do
        :silent ->
          :ok

        :log ->
          Logger.warning(
            "#{log_context(safe_opts)} — event #{inspect(type)} (source=#{inspect(source)}) " <>
              "non émis, type hors registry events.yaml : #{Exception.message(e)}"
          )

          :ok
      end

    e in [ArgumentError, FunctionClauseError] ->
      Logger.error(
        "#{log_context(safe_opts)} — event #{inspect(type)} (source=#{inspect(source)}) " <>
          "NON émis, event malformé (bug de construction) : #{inspect(e)}"
      )

      :ok
  end

  # Conversion du nom de type binaire → atome EXISTANT (anti atom-leak), appelée dans le corps
  # protégé de `safe_emit/4` : un nom jamais préregistré lève ArgumentError → classé bug de
  # construction (Logger.error + :ok), jamais un crash de l'émetteur.
  defp coerce_type(type) when is_atom(type), do: type
  defp coerce_type(type) when is_binary(type), do: String.to_existing_atom(type)

  defp log_context(safe_opts), do: Keyword.get(safe_opts, :context, "Bus.safe_emit")

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
