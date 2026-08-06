defmodule Fleet.Pilot.Offload do
  @moduledoc """
  Shared supervised offload primitive for pilot Bus consumers. Each consumer owns
  its pool and consequence label; monitored task death is routed back to the caller.
  `async_or_inline/3` preserves work when a pool refuses admission.
  """

  require Logger

  @doc """
  Starts `fun` in the `Task.Supervisor` named `supervisor_name`. Returns `{:ok, :offloaded}`
  (the real outcome is logged in the task by the caller). Spawn failure (e.g. `:max_children`
  reached) → fail-loud: logs `"<consumer>: offload Task failed (<reason>) — <consequence>"` +
  `{:error, {:offload_failed, reason}}` — the work was NOT launched, and it shows.

  `error_label` = `{consumer, consequence}` or `{consumer, consequence, meta}`: the consumer
  name (log prefix), the business consequence of the loss (log suffix), and optionally `meta` —
  a map of business context (e.g. `%{pod_id: _}`) returned by `handle_down/3` on an abnormal
  death so the consumer can ACT on the loss (BL-6-03 S2), not only log it.
  """
  @spec async(
          atom(),
          (-> any()),
          {String.t(), String.t()} | {String.t(), String.t(), map()}
        ) ::
          {:ok, :offloaded} | {:error, {:offload_failed, term()}}
  def async(supervisor_name, fun, label) do
    {consumer, consequence} = consumer_consequence(label)

    case start_monitored(supervisor_name, fun, label) do
      {:ok, :offloaded} = ok ->
        ok

      {:error, reason} ->
        Logger.error("#{consumer}: offload Task failed (#{inspect(reason)}) — #{consequence}")

        {:error, {:offload_failed, reason}}
    end
  end

  # One label vocabulary, two shapes: the 2-tuple stays valid (meta-less consumers), the 3-tuple
  # adds the business context `handle_down/3` hands back on an abnormal death.
  defp consumer_consequence({consumer, consequence}), do: {consumer, consequence}
  defp consumer_consequence({consumer, consequence, _meta}), do: {consumer, consequence}

  defp label_meta({_consumer, _consequence}), do: %{}
  defp label_meta({_consumer, _consequence, meta}) when is_map(meta), do: meta

  # Spawns + MONITORS the task (shared by async/3 and async_or_inline/3, no logging here — each
  # entry point states ITS truth: dropped vs falling back). The task's DEATH is observed: before
  # this, an offloaded task that DIED mid-work (raise past the caller's own rescue, kill, brutal
  # shutdown) vanished — nobody owned the :DOWN, the consumer's catch-all swallowed it, and the
  # only trace of a lost completion was the pod's publish deadline expiring 120s later for an
  # unknown reason. The monitor is created IN the calling consumer (this runs in its GenServer),
  # so the :DOWN lands in that consumer's mailbox: each consumer routes it to `handle_down/3`
  # BEFORE its catch-all. The label rides in the caller's process dictionary keyed by the monitor
  # ref — bounded (one entry per in-flight task, deleted at :DOWN), no state plumbing through two
  # consumers, no extra process.
  defp start_monitored(supervisor_name, fun, label) do
    case Task.Supervisor.start_child(supervisor_name, fun) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        Process.put({__MODULE__, ref}, label)
        {:ok, :offloaded}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  `async/3` with the INLINE fallback: on a REFUSED offload (`:max_children` saturation, supervisor
  down) the work runs in the calling consumer instead of being dropped — a lost completion wedges
  the issue downstream and a lost incident erases the escalation, both worse than blocking the
  singleton for ONE bounded unit (the offloaded work is deadline-bounded git/forge I/O). The inline
  crash is isolated (rescued, LOUD, typed) — the consumer never dies for a fallback. ONE policy for
  both consumers (StepRunConsumer + IncidentConsumer) — never a re-implemented local copy.
  """
  @spec async_or_inline(
          atom(),
          (-> any()),
          {String.t(), String.t()} | {String.t(), String.t(), map()}
        ) ::
          {:ok, :offloaded} | {:ok, :inline} | {:error, :inline_crashed}
  def async_or_inline(supervisor_name, fun, label) do
    {consumer, consequence} = consumer_consequence(label)

    case start_monitored(supervisor_name, fun, label) do
      {:ok, :offloaded} = ok ->
        ok

      {:error, reason} ->
        # ONE honest trace: the offload was refused AND the work runs anyway — never the drop-log
        # (whose consequence would be false here) followed by a silent save.
        Logger.warning(
          "#{consumer}: offload refused (#{inspect(reason)}) → falls back to INLINE " <>
            "(bounded; #{consequence} avoided)"
        )

        try do
          fun.()
          {:ok, :inline}
        rescue
          e ->
            Logger.error(
              "#{consumer}: INLINE fallback crashed (#{Exception.message(e)}) — #{consequence}"
            )

            {:error, :inline_crashed}
        catch
          kind, reason ->
            Logger.error(
              "#{consumer}: INLINE fallback crashed (#{kind} #{inspect(reason)}) — #{consequence}"
            )

            {:error, :inline_crashed}
        end
    end
  end

  @doc """
  Routes a `:DOWN` received by a consumer: `:not_mine` if the ref is not one of ITS offloaded
  tasks (the consumer's catch-all takes over); otherwise the entry is consumed (no leak) and the
  outcome is TYPED so the consumer can act on it (BL-6-03 S2), not only read a log:

    * `{:handled, :nominal}` — `:normal`/`:shutdown` exit, the nominal end (silent).
    * `{:handled, {:died, reason, meta}}` — the task died mid-work: the LOUD trace this
      mechanism exists for, plus the label's `meta` (business context — e.g. the `pod_id` whose
      `:publishing` flag now waits on a confirmation that will never come). Logging stays HERE
      (one voice); ACTING on the loss is the consumer's.
  """
  @spec handle_down(reference(), pid(), term()) ::
          :not_mine | {:handled, :nominal} | {:handled, {:died, term(), map()}}
  def handle_down(ref, _pid, reason) do
    case Process.delete({__MODULE__, ref}) do
      nil ->
        :not_mine

      label ->
        {consumer, consequence} = consumer_consequence(label)

        case reason do
          :normal ->
            {:handled, :nominal}

          :shutdown ->
            {:handled, :nominal}

          {:shutdown, _} ->
            {:handled, :nominal}

          # The task exited BEFORE the monitor attached. On the offload path (git/forge I/O)
          # this window is µs vs ms+ work → near-instant exit almost always means the task
          # crashed before any real work happened. Treat as LOUD (cry wolf once, never silently
          # drop a mid-work death).
          :noproc ->
            Logger.error(
              "#{consumer}: offloaded task DIED mid-work (:noproc — exited before monitor) — #{consequence}"
            )

            {:handled, {:died, :noproc, label_meta(label)}}

          other ->
            Logger.error(
              "#{consumer}: offloaded task DIED mid-work (#{inspect(other)}) — #{consequence}"
            )

            {:handled, {:died, other, label_meta(label)}}
        end
    end
  end
end
