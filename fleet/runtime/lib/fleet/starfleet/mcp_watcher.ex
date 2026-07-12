defmodule Fleet.Starfleet.MCPWatcher do
  @moduledoc """
  Passive cron that watches the upstream version of the Elixir MCP SDK
  (`ex_mcp`) on Hex.pm and alerts if a drift is observed between the version
  installed locally and the latest published upstream.

  Design note `orchestration/fleet_starfleet.md` §Extensions V2.

  ## Mechanics

  GenServer + recursive `Process.send_after/3` (canonical native-Elixir
  pattern — no Quantum/Oban dep). A single deadline armed at any instant: on
  expiry, `handle_info(:check_upstream, _)` runs the check then re-arms the
  next. The plumbing (named start_link, tick + re-arming, test hook
  `:check_now`) is SHARED with `MCPMonitor` via
  `Fleet.Starfleet.PeriodicCheck`; this module keeps its state, its
  `do_check/1` and the shape of its reply (`:ok`).

  ## Configuration

    * `:fleet_starfleet, :mcp_watcher_check_interval_ms` — interval (default
      weekly `:timer.hours(168)`)
    * `:fleet_starfleet, :mcp_watcher_package` — Hex.pm package name
      (default `"ex_mcp"`)
    * `:fleet_starfleet, :mcp_watcher_upstream_fetcher` — `{:ok, version_str}
      | {:error, reason}` callback override (default `nil` → fetch Hex.pm
      API via Req). Lets tests inject a deterministic response.

  ## Event broadcast

  Canonical schema `%Fleet.Event{source: :starfleet, type: :"sdk.upstream_alert",
  payload: %{current, upstream, package}, correlation_id: nil}`. Emitted IFF
  current != upstream. Fetch error or identical versions → no-op
  (debug log only).

  ## Iron Law (otp-thinking)

  GenServer = justified: recursive timer + minimal shared state (last_check
  + last_status). The check itself is NOT on the hot path (weekly).
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

  # Test hook: triggers an immediate sync check (equivalent to the timer). The reply is a bare `:ok`
  # (no status to expose, unlike MCPMonitor).
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
    # `to_existing_atom` (not `to_atom`): a package name that has never been an atom is by construction
    # NOT a loaded app → no local version (nil), same result as `Application.spec` on an unknown app —
    # but WITHOUT minting a junk atom for a mistyped/upstream-only package (atom-leak hygiene, R2-13).
    # `ArgumentError` = "no such atom" → nil (behavior-preserving vs the old `to_atom`).
    case Application.spec(String.to_existing_atom(package), :vsn) do
      nil -> nil
      vsn -> List.to_string(vsn)
    end
  rescue
    ArgumentError -> nil
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

  # Emission via the protected core `Bus.safe_emit/4` (duplicated local rescue removed — the
  # protected-emission policy has ONE authority, Ring 0, which closes the "misaligned twins" drift: this
  # module had been the only one of the 4 to mask a malformed event). `:silent`: UnregisteredError =
  # boot-order tolerated (registry not yet populated), like MCPMonitor. A MALFORMED event
  # (construction bug) is logged ERROR by safe_emit then neutralized — letting it crash would
  # restart the watcher and re-fetch Hex.pm in a loop.
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
      context: "MCPWatcher: sdk.upstream_alert alert NOT emitted"
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
