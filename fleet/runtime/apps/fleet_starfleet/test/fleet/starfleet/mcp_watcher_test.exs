defmodule Fleet.Starfleet.MCPWatcherTest do
  @moduledoc """
  Tests MCPWatcher (cron hebdo SDK MCP upstream).

  BL-021 chantier 8 — DN 13 Extensions V2.

  Le timer Process.send_after n'est pas observé directement (interval >>
  durée test). On exerce `handle_call(:check_now, ...)` qui rejoue le code
  path complet du timer.
  """

  use ExUnit.Case, async: false

  alias Fleet.EventRouter.Bus
  alias Fleet.Starfleet.MCPWatcher

  setup do
    Bus.subscribe()
    :ok
  end

  describe "check_now (sync trigger du code path timer)" do
    test "mismatch current vs upstream → broadcast %Fleet.Event{sdk.upstream_alert}" do
      fetcher = fn "ex_mcp" -> {:ok, "9.9.9-fake-upstream"} end

      {:ok, pid} =
        MCPWatcher.start_link(
          name: :mcp_watcher_mismatch,
          interval_ms: 60_000,
          upstream_fetcher: fetcher
        )

      assert :ok = GenServer.call(pid, :check_now)

      assert_receive %Fleet.Event{
                       source: :starfleet,
                       type: :"sdk.upstream_alert",
                       payload: %{
                         "package" => "ex_mcp",
                         "upstream" => "9.9.9-fake-upstream",
                         "current" => current
                       }
                     },
                     500

      assert is_binary(current) or is_nil(current)

      state = :sys.get_state(pid)
      assert state.last_upstream == "9.9.9-fake-upstream"
      assert %DateTime{} = state.last_check
      GenServer.stop(pid)
    end

    test "current == upstream → no broadcast" do
      current = Application.spec(:ex_mcp, :vsn)
      fetcher = fn "ex_mcp" -> {:ok, current && List.to_string(current)} end

      {:ok, pid} =
        MCPWatcher.start_link(
          name: :mcp_watcher_aligned,
          interval_ms: 60_000,
          upstream_fetcher: fetcher
        )

      assert :ok = GenServer.call(pid, :check_now)

      refute_receive %Fleet.Event{type: :"sdk.upstream_alert"}, 200
      GenServer.stop(pid)
    end

    test "fetcher {:error, reason} → log warn + no broadcast" do
      fetcher = fn "ex_mcp" -> {:error, :network_unreachable} end

      {:ok, pid} =
        MCPWatcher.start_link(
          name: :mcp_watcher_fetcherr,
          interval_ms: 60_000,
          upstream_fetcher: fetcher
        )

      assert :ok = GenServer.call(pid, :check_now)

      refute_receive %Fleet.Event{type: :"sdk.upstream_alert"}, 200
      GenServer.stop(pid)
    end

    test "package override via opts" do
      fetcher = fn "custom_pkg" -> {:ok, "1.2.3-fake"} end

      {:ok, pid} =
        MCPWatcher.start_link(
          name: :mcp_watcher_custompkg,
          interval_ms: 60_000,
          package: "custom_pkg",
          upstream_fetcher: fetcher
        )

      assert :ok = GenServer.call(pid, :check_now)

      assert_receive %Fleet.Event{
                       type: :"sdk.upstream_alert",
                       payload: %{"package" => "custom_pkg", "upstream" => "1.2.3-fake"}
                     },
                     500

      GenServer.stop(pid)
    end
  end
end
