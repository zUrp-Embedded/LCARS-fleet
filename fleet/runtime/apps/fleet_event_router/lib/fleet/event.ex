defmodule Fleet.Event do
  @moduledoc """
  Schema canon des events publiés sur Phoenix.PubSub topic `fleet.events`.
  Tout module LCARS qui publie un event DOIT utiliser cette struct.

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
          | :starfleet
          | :event_router
          | :credentials
          | :capprofile
          | :spbuilder
          | :doctrine

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
  @canonical_sources ~w(spawner task_queue mcp coord starfleet event_router credentials capprofile spbuilder doctrine)a

  @doc "Sources canoniques (enum closed list, DN méta §1.7)."
  @spec canonical_sources() :: [source()]
  def canonical_sources, do: @canonical_sources

  @doc "Vrai si la source appartient à l'enum closed list canonique."
  @spec valid_source?(atom()) :: boolean()
  def valid_source?(source), do: source in @canonical_sources

  defmodule UnregisteredError do
    @moduledoc "Event publié hors registry `events.yaml` (fail-loud strict, DN méta §1.7)."
    defexception [:message]
  end

  defmodule SchemaError do
    @moduledoc "Event ne respectant pas le schema canon `%Fleet.Event{}` (fail-loud strict, DN méta §1.7)."
    defexception [:message]
  end
end
