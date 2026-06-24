defmodule Fleet.Spawner.PublishConsumer do
  @moduledoc """
  Consumer du broadcast `admin.spawn.request`.

  Subscribe `Fleet.EventRouter.Bus` topic `fleet.events`, filtre
  `:"admin.spawn.request"`, dispatche `Fleet.Spawner.spawn_pod/3`.

  Payload attendu (rest.ex broadcast les conn.body_params) :
    * `"cap_profile_name"` ou `"role"` — string, nom canon CapProfile (chargé via `Fleet.CapProfile.load/1`)
    * `"ticket_id"` — string (sinon ticket_id enveloppe Bus)
    * `"opts"` — map keyword (optionnel)

  Erreurs (load fail / spawn fail) → log warning, **pas de crash**
  (consumer reste alive, fail-loud non-fatal). La chaîne doit être
  câblée bout-à-bout : broadcast→consume→spawn est end-to-end ; sans
  consumer, /api/admin/spawn renvoie HTTP 202 mais ne spawne rien
  (succès affiché, zéro pod).

  Test-seam : `:subscribe` (default true) + `:spawner` backend
  (default `Fleet.Spawner`, overridable pour mock).
  """

  use GenServer
  require Logger

  alias Fleet.EventRouter.Bus

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    if Keyword.get(opts, :subscribe, true), do: Bus.subscribe()
    spawner = Keyword.get(opts, :spawner, Fleet.Spawner)
    {:ok, %{spawner: spawner, count: 0}}
  end

  @impl true
  # Schema canon strict.
  def handle_info(
        %Fleet.Event{source: :api, type: :"admin.spawn.request", payload: payload},
        state
      )
      when is_map(payload) do
    try do
      handle_spawn_request(payload, payload, state)
    rescue
      e ->
        Logger.warning(
          "PublishConsumer: handle_spawn_request rescue (non-fatal) — #{Exception.message(e)}"
        )
    end

    {:noreply, %{state | count: state.count + 1}}
  end

  # Pas de clause tuple legacy `{:"admin.spawn.request", event}` : AUCUN producteur n'émet le
  # tuple `{atom, map}` (tous en `%Fleet.Event{}`). Le chemin canon (clause struct ci-dessus)
  # reçoit l'event ; une clause tuple serait morte. Le catch-all `_other` couvre tout message
  # non-event.

  # autres events broadcasts sur fleet.events → ignore
  def handle_info(%Fleet.Event{}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  # `payload` = map applicative ; `envelope` = struct/map qui peut porter `ticket_id`
  # à la racine (cas legacy tuple — la struct canon le porte dans le payload aussi).
  defp handle_spawn_request(payload, envelope, state) do
    name = Map.get(payload, "cap_profile_name") || Map.get(payload, "role")

    ticket_id =
      Map.get(payload, "ticket_id") ||
        (is_map(envelope) and Map.get(envelope, "ticket_id")) ||
        ""

    opts = Map.get(payload, "opts", []) |> to_keyword()

    cond do
      not is_binary(name) or name == "" ->
        Logger.warning(
          "PublishConsumer: admin.spawn.request invalide — name manquant/vide " <>
            "(payload=#{inspect(payload)})"
        )

      true ->
        case Fleet.CapProfile.load(name) do
          {:ok, cap_profile} ->
            case state.spawner.spawn_pod(cap_profile, to_string(ticket_id), opts) do
              {:ok, _pod_ref} ->
                Logger.info("PublishConsumer: spawn dispatché name=#{name} ticket=#{ticket_id}")

              {:error, reason} ->
                Logger.warning(
                  "PublishConsumer: spawn_pod fail name=#{name} ticket=#{ticket_id} " <>
                    "reason=#{inspect(reason)}"
                )
            end

          {:error, reason} ->
            Logger.warning(
              "PublishConsumer: CapProfile.load fail name=#{name} reason=#{inspect(reason)}"
            )
        end
    end
  end

  @doc """
  Convertit une map de payload (clés string) en keyword list pour `spawn_pod`.

  (atom-leak DoS) : `String.to_atom` sur des clés POST arbitraires
  permettrait d'épuiser la table d'atomes du BEAM. On n'accepte QUE les clés déjà
  connues comme atomes (`to_existing_atom`) ; toute clé inconnue est ignorée.
  Public pour test direct (le chemin via le consumer exige `CapProfile.load` + env
  global → non async-safe).

  Défense en profondeur : une LISTE n'est rendue telle quelle que si c'est déjà une keyword-list propre
  (paires `{atom, _}`). Une liste issue d'un tableau JSON décodé n'en est jamais une (clés string → liste
  de maps/scalaires) — elle serait donc filtrée à `[]` plutôt que gobée brute comme opts du spawner.
  Le verrou principal reste l'allowlist d'admission de `/api/admin/spawn` (Fleet.API.Rest) ; ceci en double.
  """
  def to_keyword(map) when is_map(map) do
    Enum.flat_map(map, fn {k, v} ->
      try do
        [{String.to_existing_atom(to_string(k)), v}]
      rescue
        ArgumentError -> []
      end
    end)
  end

  def to_keyword(list) when is_list(list) do
    if Keyword.keyword?(list), do: list, else: []
  end

  def to_keyword(_), do: []
end
