defmodule Fleet.Shutdown.Quiesce do
  use Boundary, deps: [], exports: []

  @moduledoc """
  Zero-dependency daemon quiescence primitive. Admission and respawn paths refuse
  new work while finalizers remain allowed to drain current work. Policy stays in
  `Fleet.Admiral`; this module only owns persistent flags and activity counters.
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

  require Logger

  # Synchronous finalizers are absent from broker/offload counts. Track them too, or drain can
  # conclude while a merge is still running. Store one atomics ref; counter updates need no process
  # or repeated persistent_term writes.

  @busy_key {__MODULE__, :busy}

  @doc false
  # Initialize at single-threaded boot before concurrent use; racing lazy init can orphan a counter.
  @spec init_busy!() :: :ok
  def init_busy! do
    _ = busy_ref()
    :ok
  end

  @doc """
  Counts a synchronous finalizer as in-flight and returns its result. The after block decrements
  on normal return, raise, throw or exit; it cannot run if the process is externally killed.
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
      ref -> report_if_negative(ref, :atomics.get(ref, 1))
    end
  end

  # Clamp negative counts for the drain but log the accounting defect: it can hide active work.
  # Slot 2 and compare_exchange limit logs to newly claimed lower floors across concurrent readers.
  # Error level denotes lost drain observability; logging every poll would obscure the failure.
  defp report_if_negative(_ref, raw) when raw >= 0, do: raw

  defp report_if_negative(ref, raw) do
    floor = :atomics.get(ref, 2)

    if raw < floor and :atomics.compare_exchange(ref, 2, floor, raw) == :ok do
      Logger.error(
        "Quiesce: busy_count NEGATIF (#{raw}) — desequilibre add/sub du compteur de quiescence. " <>
          "Le drain lit 0 (« rien en vol »), reponse conservatrice et correcte cote sortie, mais " <>
          "le compteur est FAUX de #{abs(raw)} et le restera : un `busy/1` en vol y sera invisible."
      )
    end

    0
  end

  # Slot 1 counts activity; slot 2 starts at zero and records the lowest reported negative count.
  defp busy_ref do
    case :persistent_term.get(@busy_key, nil) do
      nil ->
        ref = :atomics.new(2, signed: true)
        :persistent_term.put(@busy_key, ref)
        ref

      ref ->
        ref
    end
  end
end
