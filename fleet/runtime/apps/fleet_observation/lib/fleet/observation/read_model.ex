defmodule Fleet.Observation.ReadModel do
  @moduledoc """
  Frontière read-model de l'observabilité.

  **Un seul** processus consomme le stream `%Fleet.Event{}` (abonné au bus
  `Fleet.EventRouter.Bus`, topic `fleet.events`) et maintient une **projection**
  lisible dans une table ETS qu'il possède. Les lecteurs (le `Deck` Ring 4)
  lisent la projection via `projection/0` — un **read ETS direct** qui *bypass*
  le GenServer (Iron Law OTP : les écritures sérialisent via le process, les
  lectures ne le touchent pas).

  Le ReadModel **n'introspecte jamais** l'état interne d'un GenServer tiers : il
  ne voit que les events publics. C'est la frontière read explicite du core.

  ## Projection (forme JSON-safe)

      %{
        total: n,                      # events vus depuis le boot
        counts: %{type => n},          # tally par type (BRIDGE + FLOW dérivent d'ici)
        stream: [summary, ...],        # 100 derniers (la colonne vertébrale)
        pipelines: [summary, ...],     # 20 derniers workflow_map.*
        gatekeeper: [summary, ...],    # 20 derniers audit.verdict / coord.escalation_*
        coordination: [summary, ...],  # 20 derniers coord.* / gitea.*
        diagnostics: [summary, ...]    # 20 derniers boot/oauth/mcp/sdk/signal/git
      }

  `summary = %{type, source, pod_id, correlation_id, ts}` — uniquement des
  champs encodables (jamais le `payload` brut, qui peut porter des termes
  non-JSON, cf. `Deck.pod_view/1`).

  ## Snapshot au boot

  Les decks event-dérivés démarrent vides (le bus est un flux, pas un store) ;
  les **pods** restent un snapshot *live* via `Spawner.list_pods/0` (endpoint
  `/api/pods`), car `pod.*` n'émet que des terminaux (completed/failed/drift),
  pas un lifecycle complet.

  ## Configuration

    * `:subscribe` (opt, default `true`) — s'abonner au bus. Les tests passent
      `false` et envoient les events via `send/2` (hermétique, pas de bus réel).
    * `:fleet_observation, :start_readmodel` (app env, default `true`) —
      `false` en `:test` (pas d'abonné parasite, invariant hermétique).
  """

  use GenServer
  require Logger

  alias Fleet.EventRouter.Bus

  @table :fleet_observation_projection
  @stream_max 100
  @deck_max 20
  @topic "fleet.events"

  # Catalogue de routage deck (DATA, pas mécanique) : préfixe de type → deck.
  # L'ordre compte (premier préfixe matché gagne). Une mécanique unique
  # (`String.starts_with?`), le catalogue varie.
  @deck_prefixes [
    {"workflow_map.", :pipelines},
    {"audit.verdict", :gatekeeper},
    {"coord.escalation", :gatekeeper},
    {"coord.", :coordination},
    {"gitea.", :coordination},
    {"fleet.boot", :diagnostics},
    {"oauth.", :diagnostics},
    {"mcp.server_crashed", :diagnostics},
    {"sdk.upstream_alert", :diagnostics},
    {"state.corrupt", :diagnostics},
    {"os.signal", :diagnostics},
    {"git.", :diagnostics}
  ]

  # ── Client ────────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Lit la projection courante. **Read ETS direct** — ne fait PAS de `GenServer.call`
  (bypass, Iron Law). Si le ReadModel n'est pas démarré (table absente), renvoie
  une projection vide — le deck ne crashe jamais sur un read-model éteint.
  """
  @spec projection() :: map()
  def projection do
    :ets.lookup_element(@table, :projection, 2)
  rescue
    ArgumentError -> empty()
  end

  # ── Server ──────────────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    # Table possédée par CE process (`:protected`) → reads concurrents bypass,
    # écritures via le GenServer. Auto-supprimée à la mort du process.
    :ets.new(@table, [:set, :protected, :named_table, read_concurrency: true])
    :ets.insert(@table, {:projection, empty()})

    {:ok, %{proj: empty(), subscribe?: Keyword.get(opts, :subscribe, true)},
     {:continue, :subscribe}}
  end

  @impl GenServer
  def handle_continue(:subscribe, %{subscribe?: true} = state) do
    case Bus.subscribe(@topic) do
      :ok ->
        :ok

      other ->
        Logger.warning("Observation.ReadModel: subscribe #{@topic} → #{inspect(other)}")
    end

    {:noreply, state}
  end

  def handle_continue(:subscribe, state), do: {:noreply, state}

  @impl GenServer
  def handle_info(%Fleet.Event{} = event, state) do
    proj = project(state.proj, event)
    :ets.insert(@table, {:projection, proj})
    {:noreply, %{state | proj: proj}}
  end

  # Défensif : un message non-`%Fleet.Event{}` est ignoré, jamais un crash.
  def handle_info(_other, state), do: {:noreply, state}

  # ── Projection (pure) ────────────────────────────────────────────────────────

  @doc false
  def project(proj, %Fleet.Event{} = event) do
    s = summarize(event)
    type = s.type

    proj
    |> Map.update!(:total, &(&1 + 1))
    |> update_in([:counts, type], fn
      nil -> 1
      n -> n + 1
    end)
    |> Map.update!(:stream, &cap([s | &1], @stream_max))
    |> route_deck(type, s)
  end

  defp route_deck(proj, type, summary) do
    case Enum.find(@deck_prefixes, fn {prefix, _deck} -> String.starts_with?(type, prefix) end) do
      {_prefix, deck} -> Map.update!(proj, deck, &cap([summary | &1], @deck_max))
      nil -> proj
    end
  end

  # `payload` exclu (peut porter des termes non-encodables) ; on ne garde que
  # des champs JSON-safe.
  defp summarize(%Fleet.Event{} = e) do
    %{
      type: to_string(e.type),
      source: to_string(e.source),
      pod_id: e.pod_id,
      correlation_id: e.correlation_id,
      ts: stringify_ts(e.timestamp)
    }
  end

  defp stringify_ts(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp stringify_ts(ts) when is_integer(ts) or is_binary(ts), do: ts
  defp stringify_ts(ts), do: inspect(ts)

  defp cap(list, max), do: Enum.take(list, max)

  defp empty do
    %{
      total: 0,
      counts: %{},
      stream: [],
      pipelines: [],
      gatekeeper: [],
      coordination: [],
      diagnostics: []
    }
  end
end
