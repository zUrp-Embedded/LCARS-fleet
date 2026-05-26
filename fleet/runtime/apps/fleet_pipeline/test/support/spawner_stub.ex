defmodule Fleet.Pipeline.SpawnerStub do
  @moduledoc """
  Stub `Fleet.Spawner` pour tests — intercepte `wake_pod/1` et
  `kill_pod/1` sans appeler le spawner réel.

  Compatible chantier engineer long-lived (StageRunner réutilisation
  pipe + Executor cleanup pipe pods). Les appels sont stockés dans un
  Agent process pour assertion test-side via `wake_calls/0` /
  `kill_calls/0`.
  """

  @agent __MODULE__

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{wake: [], kill: []} end, name: @agent)
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def wake_pod(pod_id) when is_binary(pod_id) do
    Agent.update(@agent, fn s -> %{s | wake: s.wake ++ [pod_id]} end)
    :ok
  end

  def kill_pod(pod_id) when is_binary(pod_id) do
    Agent.update(@agent, fn s -> %{s | kill: s.kill ++ [pod_id]} end)
    :ok
  end

  @doc "Liste ordonnée des pod_ids passés à wake_pod/1."
  def wake_calls, do: Agent.get(@agent, & &1.wake)

  @doc "Liste ordonnée des pod_ids passés à kill_pod/1."
  def kill_calls, do: Agent.get(@agent, & &1.kill)

  def reset, do: Agent.update(@agent, fn _ -> %{wake: [], kill: []} end)
end
