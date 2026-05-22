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
  def handle_info({:"admin.spawn.request", event}, state) when is_map(event) do
    # Bulletproof D2 : consumer ne crash JAMAIS sur input (load
    # peut raise selon contexte umbrella/standalone, schema invalide,
    # etc.). Toute exception → log + count, GenServer reste alive.
    try do
      handle_spawn_request(event, state)
    rescue
      e ->
        Logger.warning(
          "PublishConsumer: handle_spawn_request rescue (non-fatal) — " <>
            "#{Exception.message(e)}"
        )
    end

    {:noreply, %{state | count: state.count + 1}}
  end

  # autres events broadcasts sur fleet.events → ignore
  def handle_info({_other, _event}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  defp handle_spawn_request(event, state) do
    payload = Map.get(event, "payload", %{})
    name = Map.get(payload, "cap_profile_name") || Map.get(payload, "role")
    ticket_id = Map.get(event, "ticket_id") || Map.get(payload, "ticket_id") || ""
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

  defp to_keyword(map) when is_map(map),
    do: Enum.map(map, fn {k, v} -> {String.to_atom(to_string(k)), v} end)

  defp to_keyword(list) when is_list(list), do: list
  defp to_keyword(_), do: []
end
