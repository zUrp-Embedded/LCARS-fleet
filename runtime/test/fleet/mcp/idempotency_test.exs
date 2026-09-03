defmodule Fleet.MCP.IdempotencyTest do
  use ExUnit.Case, async: true
  import Fleet.Test.Barrier, only: [settle: 1]

  alias Fleet.MCP.Idempotency

  setup do
    name = :"idem_#{System.unique_integer([:positive])}"
    start_supervised!({Idempotency, name: name})

    counter =
      start_supervised!({Agent, fn -> 0 end}, id: :"c_#{System.unique_integer([:positive])}")

    %{server: name, counter: counter}
  end

  defp count(agent), do: Agent.get(agent, & &1)

  defp counting_fun(agent, result) do
    fn ->
      Agent.update(agent, &(&1 + 1))
      result
    end
  end

  test "a LATE duplicate re-runs — a finished result is never replayed", %{server: s, counter: c} do
    # The removed memoize: it replayed a completed result for 10 minutes, so a legitimate
    # create X / delete X / recreate X inside that window got the FIRST create's success back and
    # the recreate never happened. Correctness moved to the effects (they converge on the world);
    # this layer only collapses CONCURRENT duplicates, so a call arriving after the flight ended
    # runs for itself.
    fun = counting_fun(c, {:ok, :r})
    assert {:ok, :r} = Idempotency.run(:k, fun, server: s)
    assert {:ok, :r} = Idempotency.run(:k, fun, server: s)
    assert count(c) == 2
  end

  test "different keys are independent — each runs", %{server: s, counter: c} do
    fun = counting_fun(c, {:ok, :r})
    assert {:ok, :r} = Idempotency.run(:k1, fun, server: s)
    assert {:ok, :r} = Idempotency.run(:k2, fun, server: s)
    assert count(c) == 2
  end

  test "a result rejected by succeeded?/1 releases the key — a genuine retry re-runs", %{
    server: s,
    counter: c
  } do
    fun = counting_fun(c, {:error, :nope})
    keep_ok = &match?({:ok, _}, &1)
    assert {:error, :nope} = Idempotency.run(:k, fun, server: s, succeeded?: keep_ok)
    assert {:error, :nope} = Idempotency.run(:k, fun, server: s, succeeded?: keep_ok)
    assert count(c) == 2
  end

  test "single-flight: a concurrent duplicate WAITS on the in-flight run and gets ITS result — fun runs ONCE",
       %{server: s} do
    test = self()

    # fun signals when it starts, then blocks until told to proceed — so both callers overlap in time.
    fun = fn ->
      send(test, {:started, self()})

      receive do
        :proceed -> :ok
      end

      send(test, :ran)
      {:ok, :the_result}
    end

    spawn(fn -> send(test, {:a, Idempotency.run(:k, fun, server: s)}) end)
    assert_receive {:started, a_fun}, 1_000

    # B is a concurrent duplicate: it must BLOCK on A, not start a second run.
    spawn(fn -> send(test, {:b, Idempotency.run(:k, fun, server: s)}) end)
    refute_receive {:started, _}, 200

    # Let A's run finish; B must then receive A's result WITHOUT ever running fun.
    send(a_fun, :proceed)
    assert_receive {:a, {:ok, :the_result}}, 1_000
    assert_receive {:b, {:ok, :the_result}}, 1_000
    assert_receive :ran, 1_000
    refute_receive :ran, 200
  end

  test "no monotonic growth, and no sweep needed: a key dies with its flight", %{server: s} do
    # DPF-15 was "expired entries are never reclaimed", and the answer then was a periodic sweep.
    # With no completed-result state there is nothing to expire: the entry is deleted at publish or
    # release, so the map cannot exceed the number of IN-FLIGHT mutations. The invariant became
    # structural instead of maintained — asserted here so a re-introduced cache cannot pass silently.
    for i <- 1..5 do
      assert {:ok, :r} = Idempotency.run(:"k#{i}", fn -> {:ok, :r} end, server: s)
    end

    assert map_size(settle(s).entries) == 0

    # A rejected result takes the release path — also leaves nothing behind.
    assert {:error, :no} =
             Idempotency.run(:rejected, fn -> {:error, :no} end,
               server: s,
               succeeded?: &match?({:ok, _}, &1)
             )

    assert map_size(settle(s).entries) == 0
  end

  test "a runner that DIES before publishing promotes a waiting duplicate — no wedge, still single-flight",
       %{server: s} do
    test = self()

    block_fun = fn ->
      send(test, {:a_started, self()})
      Process.sleep(:infinity)
    end

    a = spawn(fn -> Idempotency.run(:k, block_fun, server: s) end)
    assert_receive {:a_started, _}, 1_000

    b_fun = fn ->
      send(test, :b_ran)
      {:ok, :from_b}
    end

    spawn(fn -> send(test, {:b, Idempotency.run(:k, b_fun, server: s)}) end)
    # B is now waiting behind A. Killing A must release the key and PROMOTE B (not wedge it).
    Process.exit(a, :kill)

    assert_receive :b_ran, 1_000
    assert_receive {:b, {:ok, :from_b}}, 1_000
  end
end
