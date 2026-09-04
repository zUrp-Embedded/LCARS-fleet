defmodule Fleet.Spawner.Pod.Publishing do
  @moduledoc """
  Owns the `:publishing` condition and `:publish_deadline` actions used by `Fleet.Spawner.Pod`.

  A `git_native` pod is publishing between result submission and forge confirmation. The condition
  prevents reset/re-brief while the asynchronous publish reads its workspace. Payload pods never
  enter this condition. It is a condition on the pod's `:monitoring` state, not a gen_statem state.

  `Fleet.Spawner.Pod` owns the handlers. This module only transforms pod data and returns timer
  actions. A deadline is re-armed while `Fleet.Publish.InFlight` reports an active publish; otherwise
  it is the fail-safe that releases a lost confirmation. The delay is configured by
  `:lcars_fleet, :spawner_publish_deadline_ms` and defaults to 120 seconds.
  """

  @doc """
  Enters `:publishing` and arms its deadline for a `git_native` deliverable.

  Other deliverable modes return the input data and no action.
  """
  @spec maybe_enter_publishing(map()) :: {map(), [:gen_statem.action()]}
  def maybe_enter_publishing(data) do
    if Fleet.CapProfile.deliverable_mode(data.cap_profile) == "git_native" do
      {put_flag(data), [{{:timeout, :publish_deadline}, publish_deadline_ms(), :fire}]}
    else
      {data, []}
    end
  end

  @doc "Removes the `:publishing` condition. Timer cancellation is a separate action."
  @spec leave_publishing(map()) :: map()
  def leave_publishing(data),
    do: Map.update!(data, :conditions, &MapSet.delete(&1, :publishing))

  @doc "Returns whether the `:publishing` condition is set."
  @spec publishing?(map()) :: boolean()
  def publishing?(data), do: MapSet.member?(data.conditions, :publishing)

  @doc "Returns the gen_statem action that cancels `:publish_deadline`."
  @spec cancel_publish_deadline_action() :: :gen_statem.action()
  def cancel_publish_deadline_action, do: {{:timeout, :publish_deadline}, :infinity, :fire}

  @doc "Returns the action that re-arms `:publish_deadline` for a fresh window."
  @spec arm_publish_deadline_action(map()) :: :gen_statem.action()
  def arm_publish_deadline_action(_data),
    do: {{:timeout, :publish_deadline}, publish_deadline_ms(), :fire}

  @doc """
  Returns the configured `:publish_deadline` fail-safe delay in milliseconds.

  Safety while a publish is running comes from `Fleet.Publish.InFlight`, not from this duration.
  """
  @spec publish_deadline_ms() :: non_neg_integer()
  def publish_deadline_ms,
    do: Application.get_env(:lcars_fleet, :spawner_publish_deadline_ms, 120_000)

  defp put_flag(data),
    do: Map.update!(data, :conditions, &MapSet.put(&1, :publishing))
end
