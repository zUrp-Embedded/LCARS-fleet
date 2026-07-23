defmodule Fleet.MCP.Idempotency do
  # A submodule of the `Fleet.MCP` boundary (reached only by the acceptor, same domain) — no own boundary.
  use GenServer

  @moduledoc """
  Core-owned single-flight de-duplication for the MCP mutation surface — at-most-once delivery
  for a *published* result; a runner that crashes before publish releases the key so ONE waiter
  re-runs the effect (at-least-once across a mid-effect crash). Short-TTL memoize keyed by the
  LOGICAL IDENTITY of a call.

  ## Why this exists (doctrine)

  The stdio bridge times a tools/call response out at 30s, but central's worker + the forge POST keep
  running; a mutation that overruns (a physicalize + push, an onboard) returns an ERROR to the agent
  while its effect completes. The agent re-emits the SAME tool call and a bare handler would run the
  mutation a SECOND time — a duplicate the forge does not prevent (issues carry no uniqueness).

  The guarantee against that duplicate must live in the CORE, not in the agent's cognition: the core
  owns retries, and a critical property is only held when a mechanical layer enforces it (never a
  prompt instruction to "resend the same id"). So this layer sits at the single tool-call choke point
  and dedups on a key DERIVED from the call (`{pod_id, tool, hash(args)}`) — a deterministic function
  of the logical operation, the house idempotency pattern, needing zero client cooperation.

  ## Mechanism

  `run/3` de-duplicates `fun` for a given `key` (single-flight + memoize):

    * first caller for a live key → runs `fun` (single-flight);
    * a concurrent caller (the retry that arrived while the first is still in flight) → BLOCKS on the
      first and returns ITS result — no second run;
    * a later caller within the TTL → returns the MEMOIZED result;
    * a caller past the TTL / for a never-seen key → runs `fun`.

  Only results the caller marks memoizable (`memoize?/1`, default: everything) are cached; a result
  the caller rejects (e.g. an MCP `{:error, _, _}` — the mutation FAILED, its effect did not happen)
  is NOT cached and RELEASES the key so a genuine retry re-runs. Single-flight is preserved across a
  runner that crashes or fails: the coordinator promotes exactly ONE waiter to re-run (never a
  stampede), so a dead runner never wedges the retries — but a runner that dies BEFORE publishing
  its result releases the key so the waiter re-runs the effect (at-least-once across a mid-effect
  crash; at-most-once is only guaranteed for a *published* result).

  Iron rule: the coordinator NEVER runs `fun` itself (a forge call would serialize every mutation
  behind one process) — it only arbitrates claim/publish; `fun` runs in the caller's connection Task.

  **Last revised**: 2026-07-23
  """

  # A completed result is replayable to a retry for this long (covers the agent's re-emit window).
  @default_ttl_ms 600_000
  # A retry that arrives while the first run is in flight blocks at most this long for its result.
  @default_wait_ms 180_000

  @typep key :: term()
  # entry: {:running, monitor_ref, runner_pid, [GenServer.from()]} | {:done, term(), integer()}

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Runs `fun` under single-flight + memoize for `key`. Returns `fun`'s result (or the memoized /
  in-flight run's result for a duplicate key).

  Options:
    * `:server` — the coordinator (default `#{inspect(__MODULE__)}`);
    * `:ttl_ms` — memoize duration for a kept result (default #{@default_ttl_ms});
    * `:wait_ms` — how long a duplicate blocks on the in-flight run (default #{@default_wait_ms});
    * `:memoize?` — `(result -> boolean)` deciding if a result is cached + replayed (default: keep all).
  """
  @spec run(key(), (-> result), keyword()) :: result when result: term()
  def run(key, fun, opts \\ []) when is_function(fun, 0) do
    server = Keyword.get(opts, :server, __MODULE__)
    ttl = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    wait = Keyword.get(opts, :wait_ms, @default_wait_ms)
    memoize? = Keyword.get(opts, :memoize?, fn _ -> true end)

    # The claim BLOCKS a duplicate until the in-flight run publishes (that is the "wait") → the call
    # timeout must exceed the max run window; a generous margin above wait_ms.
    case GenServer.call(server, {:claim, key}, wait + 30_000) do
      :run -> run_and_publish(server, key, fun, ttl, memoize?)
      {:done, result} -> result
    end
  end

  # The claimant runs fun, then publishes: a memoizable result is cached + replayed to waiters; a
  # rejected result RELEASES the key (a waiter is promoted to re-run). A raise/exit releases too (so
  # waiters never hang) and propagates to the caller's own rescue at the acceptor.
  defp run_and_publish(server, key, fun, ttl, memoize?) do
    result = fun.()

    if memoize?.(result),
      do: GenServer.cast(server, {:publish, key, result, ttl}),
      else: GenServer.cast(server, {:release, key})

    result
  rescue
    e ->
      GenServer.cast(server, {:release, key})
      reraise e, __STACKTRACE__
  catch
    kind, reason ->
      GenServer.cast(server, {:release, key})
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  # ---- coordinator ----

  @sweep_interval_ms 60_000

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :sweep_interval_ms, @sweep_interval_ms)
    _ = if interval > 0, do: Process.send_after(self(), :sweep, interval)
    {:ok, %{entries: %{}, sweep_interval_ms: interval}}
  end

  @impl true
  def handle_call({:claim, key}, {pid, _} = from, state) do
    now = mono_ms()

    case Map.get(state.entries, key) do
      {:done, result, expiry} when expiry > now ->
        {:reply, {:done, result}, state}

      {:running, ref, runner, waiters} ->
        # A duplicate arrived while the first run is in flight → hold its reply until the run publishes.
        {:noreply, put_entry(state, key, {:running, ref, runner, waiters ++ [from]})}

      # absent or expired → this caller becomes the single runner (monitored so a crash releases).
      _ ->
        ref = Process.monitor(pid)
        {:reply, :run, put_entry(state, key, {:running, ref, pid, []})}
    end
  end

  @impl true
  def handle_cast({:publish, key, result, ttl}, state) do
    case Map.get(state.entries, key) do
      {:running, ref, _runner, waiters} ->
        Process.demonitor(ref, [:flush])
        Enum.each(waiters, &GenServer.reply(&1, {:done, result}))
        {:noreply, put_entry(state, key, {:done, result, mono_ms() + ttl})}

      _ ->
        {:noreply, state}
    end
  end

  def handle_cast({:release, key}, state), do: {:noreply, release_entry(state, key)}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    # A runner died before publishing (its connection Task crashed / the socket dropped). Find its
    # entry and release it — promoting a waiter, never leaving the retries wedged.
    case Enum.find(state.entries, fn {_k, e} -> match?({:running, ^ref, _, _}, e) end) do
      {key, _} -> {:noreply, release_entry(state, key)}
      nil -> {:noreply, state}
    end
  end

  def handle_info(:sweep, %{sweep_interval_ms: interval} = state) do
    now = mono_ms()

    entries =
      Map.filter(state.entries, fn
        {_, {:done, _, expiry}} -> expiry > now
        _ -> true
      end)

    _ = if interval > 0, do: Process.send_after(self(), :sweep, interval)
    {:noreply, %{state | entries: entries}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Releases a running key WITHOUT a kept result: promote exactly ONE waiter to re-run (single-flight
  # preserved — never reply :run to several), or clear the key if no one waits. A :done key is left as
  # is (its TTL expiry does the eviction lazily at the next claim).
  defp release_entry(state, key) do
    case Map.get(state.entries, key) do
      {:running, ref, _runner, []} ->
        safe_demonitor(ref)
        %{state | entries: Map.delete(state.entries, key)}

      {:running, ref, _runner, [{next_pid, _} = next_from | rest]} ->
        safe_demonitor(ref)
        new_ref = Process.monitor(next_pid)
        GenServer.reply(next_from, :run)
        put_entry(state, key, {:running, new_ref, next_pid, rest})

      _ ->
        state
    end
  end

  defp put_entry(state, key, entry), do: %{state | entries: Map.put(state.entries, key, entry)}
  defp safe_demonitor(ref), do: Process.demonitor(ref, [:flush])
  defp mono_ms, do: System.monotonic_time(:millisecond)
end
