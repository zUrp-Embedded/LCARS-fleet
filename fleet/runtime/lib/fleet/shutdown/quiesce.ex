defmodule Fleet.Shutdown.Quiesce do
  use Boundary, deps: [], exports: []

  @moduledoc """
  Zero-dependency daemon quiescence primitive. Admission and respawn paths refuse
  new work while finalizers remain allowed to drain current work. Policy stays in
  Starfleet; this module only owns persistent flags and activity counters.
  """

  @key {__MODULE__, :quiescing}

  @doc "Does the daemon refuse new top-level work (drain in progress)?"
  @spec quiescing?() :: boolean()
  def quiescing?, do: :persistent_term.get(@key, false)

  @doc "Enables quiescence — called by `Shutdown.refuse_new_jobs/1`. Idempotent."
  @spec refuse!() :: :ok
  def refuse! do
    :persistent_term.put(@key, true)
    :ok
  end

  @doc "Lifts quiescence (resumes admission). Idempotent."
  @spec resume!() :: :ok
  def resume! do
    :persistent_term.put(@key, false)
    :ok
  end

  # ── Synchronous-finalizer activity counter (drain visibility) ──
  #
  # The drain's aggregate counts the broker's work-items and the completion offloads —
  # but a finalizer running SYNCHRONOUSLY inside a singleton (the poller tick's
  # review/merge work, a completion handler between event reception and its offload)
  # was invisible: three zero reads could conclude :drained while a merge was in
  # flight. `busy/1` makes that window countable. Iron Law kept: an `:atomics` ref,
  # no process (and no per-write `:persistent_term` put — the ref is stored once).

  @busy_key {__MODULE__, :busy}

  @doc false
  # Boot hook (`Fleet.Application.start`, single-threaded): materializes the counter ref
  # before any concurrent first use (two concurrent lazy inits would orphan one ref and
  # undercount its wrap).
  def init_busy! do
    _ = busy_ref()
    :ok
  end

  @doc """
  Wraps a SYNCHRONOUS finalizer so the drain counts it as in-flight for the wrap's
  duration. Crash-safe: the decrement runs in `after` — a raised finalizer never
  freezes the drain. Returns the fun's result.
  """
  @spec busy((-> result)) :: result when result: var
  def busy(fun) when is_function(fun, 0) do
    ref = busy_ref()
    :atomics.add(ref, 1, 1)

    try do
      fun.()
    after
      :atomics.sub(ref, 1, 1)
    end
  end

  @doc "Number of synchronous finalizers currently inside `busy/1` — summed into the drain's in-flight."
  @spec busy_count() :: non_neg_integer()
  def busy_count do
    case :persistent_term.get(@busy_key, nil) do
      nil -> 0
      ref -> max(0, :atomics.get(ref, 1))
    end
  end

  defp busy_ref do
    case :persistent_term.get(@busy_key, nil) do
      nil ->
        ref = :atomics.new(1, signed: true)
        :persistent_term.put(@busy_key, ref)
        ref

      ref ->
        ref
    end
  end
end
