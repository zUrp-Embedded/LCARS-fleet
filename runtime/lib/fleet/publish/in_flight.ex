defmodule Fleet.Publish.InFlight do
  use Boundary, deps: [], exports: []

  @moduledoc """
  Zero-dependency per-pod fact protecting a live publish from deadline recovery's
  destructive workspace reset. This VM-local boolean is not a lock or reference count:
  concurrent/nested publishers for the same pod can clear each other's mark. Callers must serialize.
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
  Marks pod_id, runs fun and clears in after, returning its result. Local raises, throws
  and exit/1 unwind through cleanup; external process termination can leave the mark set.
  It survives an individual publisher's death until cleared or the VM restarts.
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
