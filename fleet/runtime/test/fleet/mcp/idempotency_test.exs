defmodule Fleet.MCP.IdempotencyTest do
  use ExUnit.Case, async: true

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

  test "memoize: a later duplicate within TTL replays the cached result, fun runs ONCE", %{
    server: s,
    counter: c
  } do
    fun = counting_fun(c, {:ok, :r})
    assert {:ok, :r} = Idempotency.run(:k, fun, server: s)
    assert {:ok, :r} = Idempotency.run(:k, fun, server: s)
    assert count(c) == 1
  end

  test "different keys are independent — each runs", %{server: s, counter: c} do
    fun = counting_fun(c, {:ok, :r})
    assert {:ok, :r} = Idempotency.run(:k1, fun, server: s)
    assert {:ok, :r} = Idempotency.run(:k2, fun, server: s)
    assert count(c) == 2
  end

  test "a result rejected by memoize? is NOT cached — a genuine retry re-runs", %{
    server: s,
    counter: c
  } do
    fun = counting_fun(c, {:error, :nope})
    keep_ok = &match?({:ok, _}, &1)
    assert {:error, :nope} = Idempotency.run(:k, fun, server: s, memoize?: keep_ok)
    assert {:error, :nope} = Idempotency.run(:k, fun, server: s, memoize?: keep_ok)
    assert count(c) == 2
  end

  test "ttl_ms: 0 → the result is immediately expired, the next call re-runs", %{
    server: s,
    counter: c
  } do
    fun = counting_fun(c, {:ok, :r})
    assert {:ok, :r} = Idempotency.run(:k, fun, server: s, ttl_ms: 0)
    assert {:ok, :r} = Idempotency.run(:k, fun, server: s, ttl_ms: 0)
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
