defmodule Fleet.Starfleet.ShutdownTest do
  @moduledoc """
  DN ring0/lcars-fleet_service §Fleet.Starfleet.Shutdown. `async: false`:
  the stub backend models a singleton dispatcher (named Agent, read
  cross-process by the GenServer). Deliberate, coherent global coupling.
  The backend is injected via the `:shutdown_dispatcher` seam (behaviour
  `Shutdown.Dispatcher`) — default `NoOpDispatcher`, prod `AggregateDispatcher`.
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
    # Fast poll for tests (prod default 500ms); the debounce (drain_confirmations, default 3) still applies.
    {:ok, _} = start_supervised({Fleet.Starfleet.Shutdown, [name: name] ++ Keyword.put_new(opts, :poll_ms, 10)})
    name
  end

  test "NoOp default → begin/drain :ok, immediate drain (0 in-flight)" do
    name = start_sd([])
    assert :ok = Fleet.Starfleet.Shutdown.begin(name: name, grace_ms: 200)
    assert :ok = Fleet.Starfleet.Shutdown.drain_in_flight(name: name, grace_ms: 200)
  end

  test "backend sequence [2,1,0] → real drain converges" do
    box([2, 1, 0])
    name = start_sd(dispatcher: StubDispatcher)
    assert :ok = Fleet.Starfleet.Shutdown.drain_in_flight(name: name, grace_ms: 5_000)
    assert %{seq: []} = Agent.get(@box, & &1)
  end

  test "backend always >0 → drain times out but :reply :ok (shutdown proceeds)" do
    box(List.duplicate(3, 100))
    name = start_sd(dispatcher: StubDispatcher)
    assert :ok = Fleet.Starfleet.Shutdown.drain_in_flight(name: name, grace_ms: 300)
  end

  test "debounce (CI-02): a LONE transient 0 does NOT conclude — needs N consecutive 0s" do
    # A 0 at position 2 is followed by a 1 (reset) → the drain must NOT stop there (pre-CI-02, one 0-read
    # concluded → the pod.completed→offload handoff window would cut the completion). It concludes only on
    # the final 3 consecutive 0s. Proof: the WHOLE seq is consumed — had the middle 0 concluded, [1,0,0,0]
    # would remain.
    box([1, 0, 1, 0, 0, 0])
    name = start_sd(dispatcher: StubDispatcher, drain_confirmations: 3)
    assert :ok = Fleet.Starfleet.Shutdown.drain_in_flight(name: name, grace_ms: 5_000)
    assert %{seq: []} = Agent.get(@box, & &1)
    assert %{status: :drained} = :sys.get_state(name)
  end

  test "begin calls refuse_new_jobs" do
    box([0])
    name = start_sd(dispatcher: StubDispatcher)
    assert :ok = Fleet.Starfleet.Shutdown.begin(name: name, grace_ms: 300)
    assert %{refused: true} = Agent.get(@box, & &1)
  end
end
