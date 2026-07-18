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

  **Last revised**: 2026-07-18
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
  def async(supervisor_name, fun, {consumer, consequence}) do
    case Task.Supervisor.start_child(supervisor_name, fun) do
      {:ok, _pid} ->
        {:ok, :offloaded}

      {:error, reason} ->
        Logger.error("#{consumer}: offload Task failed (#{inspect(reason)}) — #{consequence}")

        {:error, {:offload_failed, reason}}
    end
  end
end
