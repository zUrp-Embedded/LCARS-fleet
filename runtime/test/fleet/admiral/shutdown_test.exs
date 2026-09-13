defmodule Fleet.Admiral.ShutdownTest do
  @moduledoc """
  Serial tests of the synchronous drain with a named Agent counter injected through
  opts[:dispatcher]. No real work drains. Both timeout and success reply :ok; only
  the debounce test explicitly checks the server's terminal status.
  """
  use ExUnit.Case, async: false
  import Fleet.Test.Barrier, only: [settle: 1]

  alias Fleet.Admiral.Shutdown

  @box Fleet.Admiral.ShutdownTest.Box

  defmodule StubDispatcher do
    @behaviour Fleet.Admiral.Shutdown.Dispatcher

    @impl true
    def refuse_new_jobs(_opts) do
      Agent.update(Fleet.Admiral.ShutdownTest.Box, fn s -> %{s | refused: true} end)
      :ok
    end

    @impl true
    def in_flight_count do
      Agent.get_and_update(Fleet.Admiral.ShutdownTest.Box, fn
        %{seq: [h | t]} = s -> {h, %{s | seq: t}}
        %{seq: []} = s -> {0, s}
      end)
    end
  end

  # ExUnit supervision waits for Agent termination, avoiding reuse of a lingering name
  # and a whereis/stop teardown race.
  defp box(seq) do
    start_supervised!(%{
      id: @box,
      start: {Agent, :start_link, [fn -> %{seq: seq, refused: false} end, [name: @box]]}
    })
  end

  defp start_sd(opts) do
    name = :"sd_#{System.unique_integer([:positive])}"

    {:ok, _} =
      start_supervised(
        {Fleet.Admiral.Shutdown, [name: name] ++ Keyword.put_new(opts, :poll_ms, 10)}
      )

    name
  end

  test "NoOp default → begin/drain :ok, immediate drain (0 in-flight)" do
    name = start_sd([])
    assert :ok = Shutdown.begin(name: name, grace_ms: 200)
    assert :ok = Shutdown.drain_in_flight(name: name, grace_ms: 200)
  end

  test "backend sequence [2,1,0] → real drain converges" do
    box([2, 1, 0])
    name = start_sd(dispatcher: StubDispatcher)
    assert :ok = Shutdown.drain_in_flight(name: name, grace_ms: 5_000)
    assert %{seq: []} = Agent.get(@box, & &1)
  end

  test "backend always >0 → drain times out but :reply :ok (shutdown proceeds)" do
    box(List.duplicate(3, 100))
    name = start_sd(dispatcher: StubDispatcher)
    assert :ok = Shutdown.drain_in_flight(name: name, grace_ms: 300)
  end

  test "debounce (CI-02): a LONE transient 0 does NOT conclude — needs N consecutive 0s" do
    # Consuming the entire sequence proves the isolated zero did not finish the drain.
    box([1, 0, 1, 0, 0, 0])
    name = start_sd(dispatcher: StubDispatcher, drain_confirmations: 3)
    assert :ok = Shutdown.drain_in_flight(name: name, grace_ms: 5_000)
    assert %{seq: []} = Agent.get(@box, & &1)
    assert %{status: :drained} = settle(name)
  end

  test "begin calls refuse_new_jobs" do
    box([0])
    name = start_sd(dispatcher: StubDispatcher)
    assert :ok = Shutdown.begin(name: name, grace_ms: 300)
    assert %{refused: true} = Agent.get(@box, & &1)
  end
end
