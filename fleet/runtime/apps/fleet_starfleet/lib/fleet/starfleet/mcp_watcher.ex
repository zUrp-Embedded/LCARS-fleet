defmodule Fleet.Starfleet.MCPWatcher do
  @moduledoc """
  Cron passif qui surveille la version upstream du SDK MCP Elixir (`ex_mcp`)
  sur Hex.pm et alerte si un drift est observé entre la version installée
  localement et la dernière publiée upstream.

  DN 13 `orchestration/fleet_starfleet.md` §Extensions V2 (BL-021 chantier 8).

  ## Mécanique

  GenServer + `Process.send_after/3` récursif (pattern canon Elixir natif —
  pas de dep Quantum/Oban). Une seule échéance armée à tout instant : à
  l'expiration, `handle_info(:check_upstream, _)` exécute le check puis
  re-arme la prochaine. La plomberie (start_link nommé, tick + ré-armement,
  hook test `:check_now`) est PARTAGÉE avec `MCPMonitor` via
  `Fleet.Starfleet.PeriodicCheck` ; ce module garde son état, son
  `do_check/1` et la forme de sa réponse (`:ok`).

  ## Configuration

    * `:fleet_starfleet, :mcp_watcher_check_interval_ms` — interval (default
      hebdomadaire `:timer.hours(168)`)
    * `:fleet_starfleet, :mcp_watcher_package` — nom du package Hex.pm
      (default `"ex_mcp"`)
    * `:fleet_starfleet, :mcp_watcher_upstream_fetcher` — `{:ok, version_str}
      | {:error, reason}` callback override (default `nil` → fetch Hex.pm
      API via Req). Permet aux tests d'injecter une réponse déterministe.

  ## Event broadcast

  Schema canon `%Fleet.Event{source: :starfleet, type: :"sdk.upstream_alert",
  payload: %{current, upstream, package}, correlation_id: nil}`. Émis SSI
  current != upstream. Erreur de fetch ou versions identiques → no-op
  (log debug seulement).

  ## Iron Law (otp-thinking)

  GenServer = justifié : timer récursif + état partagé minimal (last_check
  + last_status). Le check lui-même n'est PAS sur le hot path (hebdomadaire).
  """

  use GenServer
  require Logger

  alias Fleet.EventRouter.Bus
  alias Fleet.Starfleet.PeriodicCheck

  @default_interval_ms :timer.hours(168)
  @default_package "ex_mcp"
  @hex_pm_api_base "https://hex.pm/api/packages"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: PeriodicCheck.start_link(__MODULE__, opts)

  @impl GenServer
  def init(opts) do
    state = %{
      package: Keyword.get(opts, :package) || config_package(),
      interval_ms: Keyword.get(opts, :interval_ms) || config_interval_ms(),
      fetcher: Keyword.get(opts, :upstream_fetcher) || config_upstream_fetcher(),
      last_check: nil,
      last_current: nil,
      last_upstream: nil
    }

    _ = PeriodicCheck.schedule(:check_upstream, state.interval_ms)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:check_upstream, state),
    do: PeriodicCheck.tick(state, :check_upstream, &do_check/1)

  def handle_info(_other, state), do: {:noreply, state}

  # Hook test : déclenche un check immédiat sync (équivalent au timer). La réponse est un `:ok` nu
  # (pas de statut à exposer, contrairement au MCPMonitor).
  @impl GenServer
  def handle_call(:check_now, _from, state),
    do: PeriodicCheck.check_now(state, &do_check/1, fn _ -> :ok end)

  defp do_check(state) do
    current = current_version(state.package)

    case fetch_upstream_version(state) do
      {:ok, upstream} ->
        _ =
          if current != upstream do
            Logger.warning(
              "MCPWatcher: drift detected package=#{state.package} current=#{inspect(current)} upstream=#{inspect(upstream)}"
            )

            broadcast_alert(state.package, current, upstream)
          else
            Logger.debug("MCPWatcher: package=#{state.package} aligned (#{inspect(current)})")
          end

        %{state | last_check: DateTime.utc_now(), last_current: current, last_upstream: upstream}

      {:error, reason} ->
        Logger.warning(
          "MCPWatcher: upstream fetch failed package=#{state.package} reason=#{inspect(reason)} — skip (no alert)"
        )

        %{state | last_check: DateTime.utc_now(), last_current: current}
    end
  end

  defp current_version(package) when is_binary(package) do
    case Application.spec(String.to_atom(package), :vsn) do
      nil -> nil
      vsn -> List.to_string(vsn)
    end
  end

  defp fetch_upstream_version(%{fetcher: fetcher} = state) when is_function(fetcher, 1) do
    fetcher.(state.package)
  end

  defp fetch_upstream_version(state) do
    fetch_hex_pm(state.package)
  end

  defp fetch_hex_pm(package) do
    url = "#{@hex_pm_api_base}/#{package}"

    case Req.get(url, receive_timeout: 5_000) do
      {:ok, %{status: 200, body: %{"latest_stable_version" => v}}} when is_binary(v) ->
        {:ok, v}

      {:ok, %{status: 200, body: %{"latest_version" => v}}} when is_binary(v) ->
        {:ok, v}

      {:ok, %{status: 200, body: %{"releases" => [%{"version" => v} | _]}}} when is_binary(v) ->
        {:ok, v}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, {:exception, e}}
  end

  # Émission via le cœur protégé `Bus.safe_emit/4` (rescue local dupliqué retiré — la politique
  # best-effort a UNE autorité, Ring 0, ce qui clôt la dérive « jumeaux désalignés » : ce module
  # avait été le seul des 4 à masquer un event malformé). `:silent` : UnregisteredError =
  # boot-order toléré (registry pas encore peuplé), comme MCPMonitor. Un event MALFORMÉ (bug de
  # construction) est loggé ERROR par safe_emit puis neutralisé — laisser crasher redémarrerait
  # le watcher et re-fetcherait Hex.pm en boucle.
  defp broadcast_alert(package, current, upstream) do
    Bus.safe_emit(
      :starfleet,
      :"sdk.upstream_alert",
      [
        payload: %{
          "package" => package,
          "current" => current,
          "upstream" => upstream
        }
      ],
      on_unregistered: :silent,
      context: "MCPWatcher: alerte sdk.upstream_alert NON émise"
    )
  end

  defp config_interval_ms do
    Application.get_env(:fleet_starfleet, :mcp_watcher_check_interval_ms, @default_interval_ms)
  end

  defp config_package do
    Application.get_env(:fleet_starfleet, :mcp_watcher_package, @default_package)
  end

  defp config_upstream_fetcher do
    Application.get_env(:fleet_starfleet, :mcp_watcher_upstream_fetcher)
  end
end
