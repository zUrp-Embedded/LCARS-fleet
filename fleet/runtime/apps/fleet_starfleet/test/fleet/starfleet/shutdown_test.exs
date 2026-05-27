defmodule Fleet.Starfleet.ShutdownTest do
  @moduledoc """
  DN ring0/lcars-fleet_service §Fleet.Starfleet.Shutdown. `async: false` :
  le backend stub modélise un dispatcher singleton (Agent nommé,
  lu cross-process par le GenServer). Couplage global assumé et
  cohérent (le vrai Fleet.Dispatcher futur sera lui aussi singleton).
  Seam #P5 : Fleet.Dispatcher absent → behaviour injecté.
  """
  use ExUnit.Case, async: false

  @box Fleet.Starfleet.ShutdownTest.Box

  defmodule StubDispatcher do
    @behaviour Fleet.Starfleet.Shutdown.Dispatcher

    @impl true
    def refuse_new_jobs(_opts) do
      Agent.update(Fleet.Starfleet.ShutdownTest.Box, fn s -> %{s | refused: true} end)
      :ok
    end

    @impl true
    def in_flight_count do
      Agent.get_and_update(Fleet.Starfleet.ShutdownTest.Box, fn
        %{seq: [h | t]} = s -> {h, %{s | seq: t}}
        %{seq: []} = s -> {0, s}
      end)
    end
  end

  defp box(seq) do
    {:ok, _} = Agent.start_link(fn -> %{seq: seq, refused: false} end, name: @box)
    on_exit(fn -> if Process.whereis(@box), do: Agent.stop(@box) end)
  end

  defp start_sd(opts) do
    name = :"sd_#{System.unique_integer([:positive])}"
    {:ok, _} = start_supervised({Fleet.Starfleet.Shutdown, [name: name] ++ opts})
    name
  end

  test "NoOp default → begin/drain :ok, drain immédiat (0 in-flight)" do
    name = start_sd([])
    assert :ok = Fleet.Starfleet.Shutdown.begin(name: name, grace_ms: 200)
    assert :ok = Fleet.Starfleet.Shutdown.drain_in_flight(name: name, grace_ms: 200)
  end

  test "backend séquence [2,1,0] → drain réel converge" do
    box([2, 1, 0])
    name = start_sd(dispatcher: StubDispatcher)
    assert :ok = Fleet.Starfleet.Shutdown.drain_in_flight(name: name, grace_ms: 5_000)
    assert %{seq: []} = Agent.get(@box, & &1)
  end

  test "backend toujours >0 → drain timeout mais :reply :ok (shutdown continue)" do
    box(List.duplicate(3, 100))
    name = start_sd(dispatcher: StubDispatcher)
    assert :ok = Fleet.Starfleet.Shutdown.drain_in_flight(name: name, grace_ms: 300)
  end

  test "begin appelle refuse_new_jobs" do
    box([0])
    name = start_sd(dispatcher: StubDispatcher)
    assert :ok = Fleet.Starfleet.Shutdown.begin(name: name, grace_ms: 300)
    assert %{refused: true} = Agent.get(@box, & &1)
  end
end
