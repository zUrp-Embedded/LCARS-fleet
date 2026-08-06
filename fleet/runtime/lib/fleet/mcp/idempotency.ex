defmodule Fleet.MCP.Idempotency do
  # A submodule of the `Fleet.MCP` boundary (reached only by the acceptor, same domain) — no own boundary.
  use GenServer

  @moduledoc """
  Core-owned SINGLE-FLIGHT de-duplication for the MCP mutation surface, keyed by the LOGICAL
  IDENTITY of a call. Concurrent duplicates of one in-flight call collapse onto it and receive its
  result; nothing is cached beyond that flight.

  **No memoize of completed results — deliberately removed.** It used to replay a finished result
  for 10 minutes, and that made this layer answer for CORRECTNESS: without it a retry arriving
  after the run completed would re-run the effect and duplicate it. The cost was a key derived
  from the SHAPE of a call (`{pod_id, tool, hash(args)}`) standing in for the INTENTION behind it,
  so a legitimate `create X` / `delete X` / `recreate X` inside the window got the memoized success
  of the FIRST create: two executions for three intentions, and a caller told "created" over a
  world where X does not exist. A cache that can hand back a wrong answer to save one forge
  round-trip on a rare path is a bad trade.

  What replaced it is not a shorter TTL but a different owner: EVERY mutation now CONVERGES on the
  world — `create_issue`/`comment_issue` on durable `<!-- lcars-op:… -->` markers read back from the
  artifact, `create_project`/`import_project` on their own proven end state, `delete_project` on the
  forge 404 plus the ownership proofs. A re-emit therefore re-runs and lands on the same place,
  answering truthfully, and the world itself distinguishes the intentions — with ZERO client
  cooperation, which is the doctrine below. This layer's remaining job is to keep a retry STORM from
  becoming N concurrent effects.

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

  `run/3` de-duplicates `fun` for a given `key`:

    * first caller for a free key → runs `fun`;
    * a concurrent caller (the retry that arrived while the first is still in flight) → BLOCKS on the
      first and returns ITS result — no second run;
    * a caller arriving after that flight ENDED → runs `fun` (which converges), never a replay.

  `succeeded?/1` (formerly `memoize?`, default: everything) decides whether the in-flight run's
  result is valid FOR THE WAITERS — not whether anything is cached. A result the caller rejects (an
  MCP `{:error, _, _}`: the mutation FAILED, its effect did not happen) RELEASES the key and promotes
  exactly ONE waiter to re-run, never a stampede. Same on a runner that crashes or exits, so a dead
  runner never wedges the retries — and a runner that dies mid-effect means the effect may run twice,
  which is exactly why the effects themselves must converge and no longer why a cache exists.

  Iron rule: the coordinator NEVER runs `fun` itself (a forge call would serialize every mutation
  behind one process) — it only arbitrates claim/publish; `fun` runs in the caller's connection Task.
  """

  # A retry that arrives while the first run is in flight blocks at most this long for its result.
  @default_wait_ms 180_000

  @typep key :: term()
  # entry: {:running, monitor_ref, runner_pid, [GenServer.from()]} — the ONLY shape. A key exists
  # exactly as long as its flight: there is no completed-result state to expire, hence no sweep.

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Runs `fun` under single-flight for `key`. Returns `fun`'s result (or the in-flight run's result
  for a CONCURRENT duplicate). A duplicate arriving after the flight ended runs `fun` again.

  Options:
    * `:server` — the coordinator (default `#{inspect(__MODULE__)}`);
    * `:wait_ms` — how long a duplicate blocks on the in-flight run (default #{@default_wait_ms});
    * `:succeeded?` — `(result -> boolean)` deciding whether the run's result is served to the
      waiters, or the key is released so ONE of them re-runs (default: every result counts).
  """
  @spec run(key(), (-> result), keyword()) :: result when result: term()
  def run(key, fun, opts \\ []) when is_function(fun, 0) do
    server = Keyword.get(opts, :server, __MODULE__)
    wait = Keyword.get(opts, :wait_ms, @default_wait_ms)
    succeeded? = Keyword.get(opts, :succeeded?, fn _ -> true end)

    # The claim BLOCKS a duplicate until the in-flight run publishes (that is the "wait") → the call
    # timeout must exceed the max run window; a generous margin above wait_ms.
    case GenServer.call(server, {:claim, key}, wait + 30_000) do
      :run -> run_and_publish(server, key, fun, succeeded?)
      {:done, result} -> result
    end
  end

  # The claimant runs fun, then publishes: a successful result is served to the waiters and the key
  # is freed; a rejected result RELEASES the key (one waiter is promoted to re-run). A raise/exit
  # releases too (so waiters never hang) and propagates to the caller's own rescue at the acceptor.
  defp run_and_publish(server, key, fun, succeeded?) do
    result = fun.()

    if succeeded?.(result),
      do: GenServer.cast(server, {:publish, key, result}),
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

  @impl true
  def init(_opts), do: {:ok, %{entries: %{}}}

  @impl true
  def handle_call({:claim, key}, {pid, _} = from, state) do
    case Map.get(state.entries, key) do
      {:running, ref, runner, waiters} ->
        # A duplicate arrived while the first run is in flight → hold its reply until the run publishes.
        {:noreply, put_entry(state, key, {:running, ref, runner, waiters ++ [from]})}

      # No live flight → this caller becomes the single runner (monitored so a crash releases). There
      # is no completed-result branch: a key outlives nothing, so a late duplicate re-runs and its
      # effect converges. The state cannot grow past the number of in-flight mutations.
      nil ->
        ref = Process.monitor(pid)
        {:reply, :run, put_entry(state, key, {:running, ref, pid, []})}
    end
  end

  @impl true
  def handle_cast({:publish, key, result}, state) do
    case Map.get(state.entries, key) do
      {:running, ref, _runner, waiters} ->
        Process.demonitor(ref, [:flush])
        Enum.each(waiters, &GenServer.reply(&1, {:done, result}))
        # Flight over, key FREED: the next caller runs for itself rather than inheriting a stale
        # answer to a question the world may have moved on from.
        {:noreply, %{state | entries: Map.delete(state.entries, key)}}

      nil ->
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

  # (No sweep: nothing accumulates. An entry lives exactly as long as its flight and is deleted at
  # publish or release, so there is no expired state for a periodic pass to reclaim.)
  def handle_info(_msg, state), do: {:noreply, state}

  # Releases a running key WITHOUT serving its result: promote exactly ONE waiter to re-run
  # (single-flight preserved — never reply :run to several), or clear the key if no one waits.
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
end
