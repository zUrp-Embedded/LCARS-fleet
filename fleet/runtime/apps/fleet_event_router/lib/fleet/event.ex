defmodule Fleet.Event do
  @moduledoc """
  Schema canon des events publiés sur Phoenix.PubSub topic `fleet.events`.

  Wire format UNIQUE : tous les producteurs émettent cette struct `%Fleet.Event{}`. Le `Bus` n'expose
  pas de shim 3-arité `{atom, map}` — « Subscribe à `fleet.events` » garantit donc une forme unique,
  pas un tuple à dé-wrapper côté consommateur.

  Le `source` est une **enum closed list** (le type `source()` ci-dessous). L'étendre = amender cette
  liste ET ajouter l'entrée correspondante dans `events.yaml` (sinon l'event part hors registry).

  Convention de nommage d'un event = `<source>.<type>` (ex. `:spawner.pod_degraded`,
  `:task_queue.task_completed`). Matching consommateur :
  `handle_info(%Fleet.Event{source: :task_queue, type: :task_completed} = ev, state)`.
  """

  @type source ::
          :spawner
          | :task_queue
          | :mcp
          | :coord
          | :pipeline
          | :starfleet
          | :event_router
          | :credentials
          | :capprofile
          | :spbuilder
          | :doctrine
          | :api

  @type t :: %__MODULE__{
          source: source(),
          type: atom(),
          timestamp: DateTime.t(),
          pod_id: String.t() | nil,
          correlation_id: String.t() | nil,
          payload: map()
        }

  @enforce_keys [:source, :type, :timestamp]
  defstruct [:source, :type, :timestamp, :pod_id, :correlation_id, payload: %{}]

  # Enum closed list des sources. Étendre = amender cette liste + l'entrée events.yaml correspondante.
  @canonical_sources ~w(spawner task_queue mcp coord pipeline starfleet event_router credentials capprofile spbuilder doctrine api)a

  @doc "Sources canoniques (enum closed list)."
  @spec canonical_sources() :: [source()]
  def canonical_sources, do: @canonical_sources

  @doc "Vrai si la source appartient à l'enum closed list canonique."
  @spec valid_source?(atom()) :: boolean()
  def valid_source?(source), do: source in @canonical_sources

  @doc """
  Représentation canonique à clés string de l'enveloppe (payload **nested**, pas
  hoisté). Pour les consommateurs dual-stack qui lisent encore `event["…"]` : un
  struct n'implémente pas `Access`, donc `event["event_type"]` y rendrait `nil`
  (c'était la cause d'un skip silencieux webhook→pipeline). Le `payload` garde ses
  propres clés (déjà string côté webhook JSON). Helper canonique fourni ici plutôt
  que recopié par chaque consommateur, pour que la forme à clés string reste unique
  et ne dérive pas.
  """
  @spec to_string_map(t()) :: %{optional(String.t()) => any()}
  def to_string_map(%__MODULE__{} = e) do
    %{
      "event_type" => Atom.to_string(e.type),
      "type" => Atom.to_string(e.type),
      "source" => to_string(e.source),
      "pod_id" => e.pod_id,
      "correlation_id" => e.correlation_id,
      "timestamp" => e.timestamp,
      "payload" => e.payload || %{}
    }
  end

  defmodule UnregisteredError do
    @moduledoc "Event publié hors registry `events.yaml` (fail-loud strict)."
    defexception [:message]
  end

  # Pas de `SchemaError` ici : le chemin canon `Bus.broadcast/2` ne valide aucun schema JSON, il
  # pattern-matche `%Fleet.Event{}` et vérifie le registry → la seule erreur de validation est
  # `UnregisteredError`. (Un event mal formé ne compile/ne matche simplement pas la struct.)
end
