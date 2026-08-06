defmodule Fleet.Publish.InFlight do
  use Boundary, deps: [], exports: []

  @moduledoc """
  Per-pod "a deliverable publish is running" fact — a foundation primitive (`deps: []`) so BOTH
  the Pilot side that PERFORMS the publish and the Spawner side that owns the pod can reach it
  without a cross-domain dependency (Spawner ∌ Pilot).

  ## Why this exists

  A producer pod freezes its slot (`:publishing`) at submit; the Pilot completion then commits +
  pushes the pod's workspace. The pod's `:publish_deadline` fail-safe lifts that freeze after a
  fixed delay and, on the next re-brief, RESETS the workspace (`reset --hard`) — destructive. The
  delay was argued safe by an arithmetic on the git timeouts that does not hold (the composed
  publish budget exceeds it), so the reset could land on a LIVE git process still reading the
  workspace. The honest guard is not a bigger number: it is OBSERVING whether the publish is
  actually in flight. The completion marks THIS pod while it publishes; the deadline reads that
  mark and defers instead of resetting a running publish. The doubt becomes a fact.

  ## Mechanism (Iron Law: no process)

  A `:persistent_term` entry per pod (`{__MODULE__, pod_id}`). `mark/1` sets it, `clear/1` erases
  it, `in_flight?/1` reads it. Written once per publish (start) and erased once (end) — the
  `:persistent_term` profile (rare writes, hot reads), never a per-tick put. The completion MUST
  wrap its publish so the clear runs in an `after` (crash-safe): a publish that crashes still
  clears its mark, so a dead completion never keeps the pod frozen forever.
  """

  @doc "Marks `pod_id` as having a publish in flight. Idempotent."
  @spec mark(String.t()) :: :ok
  def mark(pod_id) when is_binary(pod_id) do
    :persistent_term.put(key(pod_id), true)
    :ok
  end

  @doc "Clears the in-flight mark for `pod_id`. Idempotent (no-op if absent)."
  @spec clear(String.t()) :: :ok
  def clear(pod_id) when is_binary(pod_id) do
    _ = :persistent_term.erase(key(pod_id))
    :ok
  end

  @doc "Is a publish currently in flight for `pod_id`?"
  @spec in_flight?(String.t()) :: boolean()
  def in_flight?(pod_id) when is_binary(pod_id) do
    :persistent_term.get(key(pod_id), false) == true
  end

  @doc """
  Runs `fun` with `pod_id` marked in-flight for its whole duration; the clear runs in an `after`,
  so a raised/exited publish still clears its mark (a dead completion never freezes the pod
  forever). Returns `fun`'s result.
  """
  @spec while_publishing(String.t(), (-> result)) :: result when result: var
  def while_publishing(pod_id, fun) when is_binary(pod_id) and is_function(fun, 0) do
    mark(pod_id)

    try do
      fun.()
    after
      clear(pod_id)
    end
  end

  defp key(pod_id), do: {__MODULE__, pod_id}
end
