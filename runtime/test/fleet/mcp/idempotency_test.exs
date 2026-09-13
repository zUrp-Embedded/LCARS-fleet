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
    # Caching completed results broke create/delete/recreate within its TTL. Only concurrent
    # duplicates share results; later calls must observe the current world.
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

    # Block the runner so the calls can overlap.
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

    spawn(fn -> send(test, {:b, Idempotency.run(:k, fun, server: s)}) end)
    refute_receive {:started, _}, 200

    send(a_fun, :proceed)
    assert_receive {:a, {:ok, :the_result}}, 1_000
    assert_receive {:b, {:ok, :the_result}}, 1_000
    assert_receive :ran, 1_000
    refute_receive :ran, 200
  end

  test "no monotonic growth, and no sweep needed: a key dies with its flight", %{server: s} do
    # Assert entries disappear after both publication and rejection; no completed-result TTL remains.
    for i <- 1..5 do
      assert {:ok, :r} = Idempotency.run(:"k#{i}", fn -> {:ok, :r} end, server: s)
    end

    assert map_size(settle(s).entries) == 0

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

    # There is no barrier proving B claimed before A dies; this also permits a fresh claim after death.
    Process.exit(a, :kill)

    assert_receive :b_ran, 1_000
    assert_receive {:b, {:ok, :from_b}}, 1_000
  end
end
