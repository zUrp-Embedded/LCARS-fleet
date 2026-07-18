defmodule Fleet.Starfleet.MCPWatcherTest do
  @moduledoc """
  MCPWatcher tests (weekly cron for the upstream MCP SDK).

  BL-021 — DN 13 Extensions V2.

  The Process.send_after timer is not observed directly (interval >>
  test duration). We exercise `handle_call(:check_now, ...)` which replays
  the timer's full code path.
  """

  use ExUnit.Case, async: false

  alias Fleet.EventRouter.Bus
  alias Fleet.Starfleet.MCPWatcher

  setup do
    Bus.subscribe()
    :ok
  end

  describe "check_now (sync trigger of the timer code path)" do
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

      # The alert's contract: `current` = the ex_mcp version ACTUALLY resolved locally (via
      # Application.spec, or nil if absent), NOT an arbitrary value. `is_binary or is_nil` would be
      # vacuous (always true). We compute the expected value IN this process → robust whether ex_mcp
      # is loaded (→ "0.9.1") or not (→ nil): a bogus/hard-coded current from the watcher breaks it.
      expected_current =
        case Application.spec(:ex_mcp, :vsn) do
          nil -> nil
          vsn -> List.to_string(vsn)
        end

      assert current == expected_current

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
