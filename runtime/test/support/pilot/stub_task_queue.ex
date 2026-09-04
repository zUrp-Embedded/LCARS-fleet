defmodule Fleet.Pilot.StubTaskQueue do
  @moduledoc """
  Neutral stub of the TaskQueue broker (the dispatcher / consumer / chain `task_queue:`
  seam) — B6 dedup: three local copies used to state the same contract under three
  names. Canonical name: `Stub<X>` for a neutral stub.

  `enqueue/2` always succeeds: signals `{:enqueued, pod_id, attrs}` to the test process
  (the caller runs in the same process) and returns the FIXED id `"corr-1"` — the gate
  escalation tests use it as the expected correlation_id (`{:escalate, "corr-1", _}`,
  `gate_evals` keys).

  `pod_status/1` reports a FREE pod (`{:ok, nil}`) — the immediate arch offer-then-wake of
  `freeze_to_arch` (ArchWake) probes it before enqueueing; a missing function here would make
  the rescue net silently swallow the immediate rail (false-green on the old no-kick contract).
  """
  def enqueue(pod_id, attrs) do
    send(self(), {:enqueued, pod_id, attrs})
    {:ok, %{id: "corr-1"}}
  end

  def pod_status(_pod_id), do: {:ok, nil}
end
