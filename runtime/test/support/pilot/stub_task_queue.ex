defmodule Fleet.Pilot.StubTaskQueue do
  @moduledoc """
  Stateless TaskQueue stub. `enqueue/2` sends to the caller and always returns
  `"corr-1"`, the correlation id expected by gate escalation tests and `gate_evals`.
  Direct calls from tests deliver the spy message to the test mailbox.

  `pod_status/1` always reports free, including after enqueue; this enables the
  ArchWake offer path without modeling broker state.
  """
  def enqueue(pod_id, attrs) do
    send(self(), {:enqueued, pod_id, attrs})
    {:ok, %{id: "corr-1"}}
  end

  def pod_status(_pod_id), do: {:ok, nil}
end
