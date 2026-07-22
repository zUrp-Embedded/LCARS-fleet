defmodule Fleet.Pilot.Offload do
  @moduledoc """
  SINGLE source of the **supervised offload** idiom of the pilot's Bus consumers
  (`Fleet.Pilot.StepRunConsumer`, `Fleet.Pilot.IncidentConsumer`): run I/O work
  (git push, forge writes) in a `Task.Supervisor` so as NOT to block the singleton's
  mailbox, with a fail-loud spawn failure (never silent).

  Without this module each consumer would carry its own copy of `offload_async/1` (same sequence
  `Task.Supervisor.start_child` → `{:ok, :offloaded}` | log error + `{:error, {:offload_failed, _}}`).
  The skeleton is factored here; each consumer KEEPS:

    * **its supervisor** (`task_supervisor/0`, started by `application.ex` BEFORE the consumer —
      separate blast-radius: a burst of one concern does not saturate the other's tasks);
    * **its failure message** (the consequence of a failed offload differs: "completion lost"
      on the step_run side vs "incident NOT recorded" on the incidents side) — carried by `error_label`.

  The real outcome of the offloaded work is logged IN the task by the caller (the return
  `{:ok, :offloaded}` only says "the task was launched").

  **Last revised**: 2026-07-22
  """

  require Logger

  @doc """
  Starts `fun` in the `Task.Supervisor` named `supervisor_name`. Returns `{:ok, :offloaded}`
  (the real outcome is logged in the task by the caller). Spawn failure (e.g. `:max_children`
  reached) → fail-loud: logs `"<consumer>: offload Task failed (<reason>) — <consequence>"` +
  `{:error, {:offload_failed, reason}}` — the work was NOT launched, and it shows.

  `error_label` = `{consumer, consequence}`: the consumer name (log prefix) and the
  business consequence of the loss (log suffix), the only two points of divergence of the
  original copies.
  """
  @spec async(atom(), (-> any()), {String.t(), String.t()}) ::
          {:ok, :offloaded} | {:error, {:offload_failed, term()}}
  def async(supervisor_name, fun, {consumer, consequence} = label) do
    case start_monitored(supervisor_name, fun, label) do
      {:ok, :offloaded} = ok ->
        ok

      {:error, reason} ->
        Logger.error("#{consumer}: offload Task failed (#{inspect(reason)}) — #{consequence}")

        {:error, {:offload_failed, reason}}
    end
  end

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
  @spec async_or_inline(atom(), (-> any()), {String.t(), String.t()}) ::
          {:ok, :offloaded} | {:ok, :inline} | {:error, :inline_crashed}
  def async_or_inline(supervisor_name, fun, {consumer, consequence} = label) do
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
        end
    end
  end

  @doc """
  Routes a `:DOWN` received by a consumer: `:handled` if the ref belongs to one of ITS offloaded
  tasks (entry consumed — no leak), `:not_mine` otherwise (the consumer's catch-all takes over).
  A `:normal`/`:shutdown` exit is the nominal end (silent); anything else is the LOUD trace this
  mechanism exists for — the task died mid-work and its consequence is named.
  """
  @spec handle_down(reference(), pid(), term()) :: :handled | :not_mine
  def handle_down(ref, _pid, reason) do
    case Process.delete({__MODULE__, ref}) do
      nil ->
        :not_mine

      {consumer, consequence} ->
        case reason do
          :normal ->
            :ok

          :shutdown ->
            :ok

          {:shutdown, _} ->
            :ok

          # The task exited BEFORE the monitor attached (start_child → monitor is µs; only a
          # near-instant task fits that window, and the offloaded work is git/forge I/O that
          # takes ms+). :noproc cannot distinguish a normal from an abnormal pre-monitor exit —
          # treated as the nominal fast case rather than crying wolf on trivial tasks.
          :noproc ->
            :ok

          other ->
            Logger.error(
              "#{consumer}: offloaded task DIED mid-work (#{inspect(other)}) — #{consequence}"
            )
        end

        :handled
    end
  end
end
