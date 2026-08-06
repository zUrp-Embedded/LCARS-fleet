defmodule Fleet.Publish.InFlight do
  use Boundary, deps: [], exports: []

  @moduledoc """
  Zero-dependency per-pod fact protecting a live publish from deadline recovery's
  destructive workspace reset. `while_publishing/2` always clears its rare-write
  persistent mark in an `after` block.
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
