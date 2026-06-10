defmodule Fleet.Event do
  @moduledoc """
  Schema canon CIBLE des events publiés sur Phoenix.PubSub topic `fleet.events`.

  ⚠️ Dual-stack en cours (audit deep-02) : les NOUVEAUX producteurs (ex. `Fleet.TaskQueue`) émettent
  cette struct, mais le `Fleet.EventRouter.Bus` legacy émet encore des tuples `{atom, map}`. « Subscribe
  à `fleet.events` » ne garantit donc PAS une forme unique tant que l'unification (un seul envelope OU un
  adapter explicite) n'est pas faite. Cible : tout producteur utilise cette struct.

  Cf. DN méta `architecture-canonical-references.md` §1.7 (schema canon
  `%Fleet.Event{}` + enum closed list `source`).

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

  # Enum closed list (DN méta §1.7). Étendre = amender la DN méta + entrée events.yaml.
  @canonical_sources ~w(spawner task_queue mcp coord pipeline starfleet event_router credentials capprofile spbuilder doctrine api)a

  @doc "Sources canoniques (enum closed list, DN méta §1.7)."
  @spec canonical_sources() :: [source()]
  def canonical_sources, do: @canonical_sources

  @doc "Vrai si la source appartient à l'enum closed list canonique."
  @spec valid_source?(atom()) :: boolean()
  def valid_source?(source), do: source in @canonical_sources

  @doc """
  Représentation canonique à clés string de l'enveloppe (payload **nested**, pas
  hoisté). Pour les consommateurs dual-stack qui lisent encore `event["…"]` : un
  struct n'implémente pas `Access`, donc `event["event_type"]` y rendrait `nil`
  (cause du skip silencieux webhook→pipeline, B8 e2e). Le `payload` garde ses
  propres clés (déjà string côté webhook JSON). Helper canonique ici plutôt
  qu'une copie par consommateur. (Réf historique `Fleet.MCP.Bridge` retirée —
  Z7.3 husk mort.)
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
    @moduledoc "Event publié hors registry `events.yaml` (fail-loud strict, DN méta §1.7)."
    defexception [:message]
  end

  defmodule SchemaError do
    @moduledoc "Event ne respectant pas le schema canon `%Fleet.Event{}` (fail-loud strict, DN méta §1.7)."
    defexception [:message]
  end
end
