defmodule Fleet.Spawner.PublishConsumer do
  @moduledoc """
  B10 C3 / #583 Sprint 1 — consumer `admin.spawn.request` broadcast.

  Subscribe `Fleet.EventRouter.Bus` topic `fleet.events`, filtre
  `:"admin.spawn.request"`, dispatche `Fleet.Spawner.spawn_pod/3`.

  Payload attendu (rest.ex:55 broadcast conn.body_params) :
    * `"cap_profile_name"` ou `"role"` — string, nom canon CapProfile (chargé via `Fleet.CapProfile.load/1`)
    * `"ticket_id"` — string (sinon ticket_id enveloppe Bus)
    * `"opts"` — map keyword (optionnel)

  Erreurs (load fail / spawn fail) → log warning, **pas de crash**
  (consumer reste alive, leçon D2 fail-loud non-fatal). Anti-fake-
  wired : la chaîne broadcast→consume→spawn est end-to-end ; sans
  consumer, /api/admin/spawn HTTP 202 mais zéro spawn — exactement
  le finding C3 PARTIAL B10.

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
  # BL-021 chantier 9 (B) — schema canon strict.
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

  # Z5 (#50/#51) — clause tuple legacy `{:"admin.spawn.request", event}` + catch-all tuple
  # RETIRÉES : post-ER-D2 plus AUCUN producteur n'émet le tuple `{atom, map}` (tous en
  # `%Fleet.Event{}`). Le chemin canon (clause struct ci-dessus) reçoit l'event ; les clauses
  # tuple étaient mortes. Le catch-all `_other` couvre tout message non-event.

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

  finding Vulcan (atom-leak DoS) : `String.to_atom` sur des clés POST arbitraires
  permettait d'épuiser la table d'atomes du BEAM. On n'accepte QUE les clés déjà
  connues comme atomes (`to_existing_atom`) ; toute clé inconnue est ignorée.
  Public pour test direct (le chemin via le consumer exige `CapProfile.load` + env
  global → non async-safe).
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

  def to_keyword(list) when is_list(list), do: list
  def to_keyword(_), do: []
end
