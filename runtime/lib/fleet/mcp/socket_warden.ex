defmodule Fleet.MCP.SocketWarden do
  @moduledoc """
  Reconciles owned acceptors against live pods, and socket paths against acceptors.
  The first comparison releases orphaned acceptors after two observations. The
  second emits pod.deaf for unmatched paths without deleting or repairing them;
  it does not establish that the corresponding pod is alive.

  Deaf-path detection runs even if live-pod enumeration fails. Each source failure
  preserves its state. PeriodicCheck catches remaining check failures and re-arms
  after the check, but already performed effects are not rolled back.

  Options: :name (module by default, nil for unnamed), :interval_ms (60_000),
  :live_pods_fun, :owned_fun, :release_fun, :deaf_fun and :emit_fun. Functions default
  to the production readers/effects below. Grace counts observations, not elapsed time.
  """

  use GenServer
  require Logger

  alias Fleet.EventRouter.Bus
  alias Fleet.Grace
  alias Fleet.PeriodicCheck

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: PeriodicCheck.start_link(__MODULE__, opts)

  @doc """
  Runs a synchronous check and returns both suspect sets. This advances grace
  without changing timer cadence; failures outside the source wrappers propagate.
  """
  @spec check_now(GenServer.server()) ::
          {:ok, %{suspects: MapSet.t(), deaf_suspects: MapSet.t()}}
  def check_now(server \\ __MODULE__), do: GenServer.call(server, :check_now)

  @impl GenServer
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, 60_000),
      live_pods_fun: Keyword.get(opts, :live_pods_fun, &default_live_pods/0),
      owned_fun: Keyword.get(opts, :owned_fun, &Fleet.MCP.PodSocketSupervisor.live_pod_ids/0),
      release_fun:
        Keyword.get(opts, :release_fun, &Fleet.MCP.PodSocketSupervisor.release_pod_socket/1),
      deaf_fun: Keyword.get(opts, :deaf_fun, &Fleet.MCP.Supervisor.deaf_pods/0),
      emit_fun: Keyword.get(opts, :emit_fun, &Bus.safe_emit/4),
      suspects: MapSet.new(),
      deaf_suspects: MapSet.new(),
      # Suppress repeated emissions while a path stays deaf so incident recurrence
      # does not count the warden's polling cadence.
      deaf_reported: MapSet.new()
    }

    _ = PeriodicCheck.schedule(:reap, state.interval_ms)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:reap, state), do: PeriodicCheck.tick(state, :reap, &do_check/1)
  def handle_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def handle_call(:check_now, _from, state),
    do:
      PeriodicCheck.check_now(
        state,
        &do_check/1,
        &{:ok, %{suspects: &1.suspects, deaf_suspects: &1.deaf_suspects}}
      )

  defp do_check(state) do
    # Deaf-path detection does not depend on live-pod enumeration.
    state = report_deaf_pods(state)

    case live_pod_ids(state) do
      :error ->
        # Unknown is not an empty live set.
        state

      live ->
        orphans = state.owned_fun.() |> MapSet.new() |> MapSet.difference(live)
        {confirmed, suspects} = Grace.two_tick(orphans, state.suspects)

        for pod_id <- confirmed do
          Logger.warning(
            "SocketWarden: MCP socket of pod #{pod_id} ORPHANED (pod gone without releasing — " <>
              "brutal teardown?) → released"
          )

          _ = state.release_fun.(pod_id)
        end

        %{state | suspects: suspects}
    end
  end

  # Preserve unmatched paths as evidence; restarting acceptors is a lifecycle decision.
  # Emission is an incident input, not proof of durable receipt. Its return is ignored
  # and the subject is marked reported even when the emitter returns an error.
  defp report_deaf_pods(state) do
    case safe_deaf(state) do
      :error ->
        # Preserve reported subjects on read failure to avoid spurious re-emissions.
        state

      deaf ->
        {confirmed, deaf_suspects} = Grace.two_tick(deaf, state.deaf_suspects)
        fresh = MapSet.difference(confirmed, state.deaf_reported)

        for pod_id <- fresh do
          Logger.error(
            "SocketWarden: pod #{pod_id} is DEAF — socket file present, NO acceptor behind it " <>
              "(cascade?). The pod keeps writing into it and reports nothing."
          )

          _ =
            state.emit_fun.(
              :mcp,
              :"pod.deaf",
              [payload: %{"pod_id" => pod_id, "reason" => "acceptor_absent"}],
              context: "SocketWarden"
            )
        end

        %{
          state
          | deaf_suspects: deaf_suspects,
            # Forget recovered paths so a later recurrence can be reported.
            deaf_reported: MapSet.intersection(MapSet.union(state.deaf_reported, fresh), deaf)
        }
    end
  end

  defp safe_deaf(state) do
    case state.deaf_fun.() do
      {:ok, ids} ->
        MapSet.new(ids)

      {:error, reason} ->
        Logger.warning(
          "SocketWarden: deaf-pod cross-check could not run (#{inspect(reason)}) — nothing raised " <>
            "this tick; an unreadable socket dir is NOT an empty one"
        )

        :error
    end
  rescue
    e ->
      Logger.warning("SocketWarden: deaf-pod cross-check raised (#{inspect(e)}) — nothing raised")
      :error
  catch
    _, _ -> :error
  end

  defp live_pod_ids(state) do
    MapSet.new(state.live_pods_fun.())
  rescue
    e ->
      Logger.warning(
        "SocketWarden: live-pod enumeration failed (#{inspect(e)}) — nothing reaped this tick"
      )

      :error
  catch
    _, _ -> :error
  end

  defp default_live_pods do
    Enum.map(Fleet.Spawner.list_pods(), & &1[:pod_id])
  end
end
