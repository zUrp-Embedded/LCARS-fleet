defmodule Fleet.MCP.Idempotency do
  use GenServer

  @moduledoc """
  Single-flight coordinator for MCP mutations. Concurrent calls with one logical
  key share a result; completed results are never cached, so later intentions run
  against the current world. Rejected results and dead runners promote exactly one
  waiter. Callers execute effects; this process only arbitrates ownership.
  """

  @default_wait_ms 180_000

  @typep key :: term()

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Runs a function under per-key single-flight. `:succeeded?` controls whether
  waiters receive its result or one waiter is promoted to retry.
  """
  @spec run(key(), (-> result), keyword()) :: result when result: term()
  def run(key, fun, opts \\ []) when is_function(fun, 0) do
    server = Keyword.get(opts, :server, __MODULE__)
    wait = Keyword.get(opts, :wait_ms, @default_wait_ms)
    succeeded? = Keyword.get(opts, :succeeded?, fn _ -> true end)

    case GenServer.call(server, {:claim, key}, wait + 30_000) do
      :run -> run_and_publish(server, key, fun, succeeded?)
      {:done, result} -> result
    end
  end

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

  @impl true
  def init(_opts), do: {:ok, %{entries: %{}}}

  @impl true
  def handle_call({:claim, key}, {pid, _} = from, state) do
    case Map.get(state.entries, key) do
      {:running, ref, runner, waiters} ->
        {:noreply, put_entry(state, key, {:running, ref, runner, waiters ++ [from]})}

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
        {:noreply, %{state | entries: Map.delete(state.entries, key)}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_cast({:release, key}, state), do: {:noreply, release_entry(state, key)}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state.entries, fn {_k, e} -> match?({:running, ^ref, _, _}, e) end) do
      {key, _} -> {:noreply, release_entry(state, key)}
      nil -> {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Promote one waiter on release; never create a retry stampede.
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
