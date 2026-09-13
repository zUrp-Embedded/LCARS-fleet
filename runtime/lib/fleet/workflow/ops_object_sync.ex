defmodule Fleet.Workflow.OpsObjectSync do
  @moduledoc """
  Serializes cooperating ops writers through one node-global GenServer, including
  best-effort push. work_dir is payload, not a routing key: unrelated projects queue
  behind each other. Direct OpsObject callers and separate server instances bypass
  this serialization.

  Calls return the artifact SHA synchronously. Pilot.Application supervises the
  singleton independently of step dispatch; the test configuration disables it.
  An unregistered atom name falls back to a direct write, with a warning when
  pilot_start_ops_object_sync is truthy. A dead PID instead follows exit recovery.

  Call timeout does not cancel queued work. Recovery probes up to 50 path-history
  commits, then tries an ordered drain and probes again. A matching version yields
  :unknown publication state: it need not have been written by this invocation.
  Read errors, history limits and concurrent external changes can produce misses
  even after drain; the logs' definitive-failure claims are stronger than the probe.

  Call and drain budgets default to 60 seconds each; Git probes have their own
  per-command budgets, so recovery is not bounded by one call timeout.
  """

  use GenServer
  require Logger

  alias Fleet.Workflow.OpsObject

  # One transaction includes best-effort network push.
  @default_call_timeout 60_000

  # Test-configurable timeout budget.
  defp call_timeout,
    do: Application.get_env(:lcars_fleet, :workflow_ops_sync_call_timeout, @default_call_timeout)

  # Test-configurable ordered drain-confirm budget.
  defp drain_timeout,
    do: Application.get_env(:lcars_fleet, :workflow_ops_sync_drain_timeout, call_timeout())

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Calls the singleton, or writes directly when its name is unregistered.
  Returns the engine result, with :unknown push state for recovered history hits.
  """
  @spec commit_object(Path.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t(), OpsObject.push_state() | :unknown} | {:error, term()}
  def commit_object(work_dir, ref, content, opts),
    do: commit_object(__MODULE__, work_dir, ref, content, opts)

  @doc """
  Accepts an atom name or PID for an isolated serializer. An unregistered name
  uses the direct fallback; a dead PID triggers readback and may return
  :ops_sync_unavailable. Other GenServer address forms are not implemented.
  """
  @spec commit_object(GenServer.server(), Path.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t(), OpsObject.push_state() | :unknown} | {:error, term()}
  def commit_object(server, work_dir, ref, content, opts)
      when is_binary(work_dir) and is_binary(ref) and is_binary(content) do
    case resolve(server) do
      nil ->
        # A configured-but-missing serializer is visible; explicit direct modes stay quiet.
        if Application.get_env(:lcars_fleet, :pilot_start_ops_object_sync, true) do
          Logger.warning(
            "OpsObjectSync: serializer NOT registered — direct OpsObject write " <>
              "(cross-writer serialization skipped; restart window or crash loop)"
          )
        end

        OpsObject.commit_object(work_dir, ref, content, opts)

      pid ->
        try do
          GenServer.call(pid, {:commit, work_dir, ref, content, opts}, call_timeout())
        catch
          # A timeout does not cancel server work; readback then ordered drain avoids unsafe retry.
          :exit, {:timeout, _} = reason ->
            confirm_after_timeout(pid, work_dir, ref, content, reason)

          # Server exit may follow a landed transaction; read back before classifying unavailable.
          :exit, reason ->
            case OpsObject.committed_sha(work_dir, ref, content) do
              {:ok, sha} ->
                Logger.warning(
                  "OpsObjectSync: serializer exited (#{inspect(reason)}) but #{ref} is committed " <>
                    "(#{String.slice(sha, 0, 12)}) — transaction LANDED before the exit"
                )

                {:ok, sha, :unknown}

              :not_committed ->
                {:error, {:ops_sync_unavailable, reason}}
            end
        end
    end
  end

  # A lost reply loses push outcome. History can establish matching committed content
  # only. The drain is ordered after this caller's original request, but a negative
  # bounded probe still does not prove that the request never committed.
  defp confirm_after_timeout(pid, work_dir, ref, content, reason) do
    case OpsObject.committed_sha(work_dir, ref, content) do
      {:ok, sha} ->
        Logger.warning(
          "OpsObjectSync: call timed out but #{ref} is already committed (#{String.slice(sha, 0, 12)}) " <>
            "— transaction LANDED, confirmed by read-only readback (no retry, no race)"
        )

        {:ok, sha, :unknown}

      :not_committed ->
        try do
          :drained = GenServer.call(pid, :drain_confirm, drain_timeout())

          case OpsObject.committed_sha(work_dir, ref, content) do
            {:ok, sha} ->
              Logger.warning(
                "OpsObjectSync: call timed out, #{ref} LANDED during drain-confirm " <>
                  "(#{String.slice(sha, 0, 12)}) — late but definitive, no false failure"
              )

              {:ok, sha, :unknown}

            :not_committed ->
              Logger.warning(
                "OpsObjectSync: drain-confirm complete and #{ref} NOT committed — the transaction " <>
                  "ran and failed server-side (definitive, not ambiguous)"
              )

              {:error, {:ops_sync_timeout, reason}}
          end
        catch
          :exit, _drain_exit ->
            # Failed drain leaves the transaction genuinely ambiguous.
            {:error, {:ops_sync_timeout, reason}}
        end
    end
  end

  defp resolve(pid) when is_pid(pid), do: pid
  defp resolve(name) when is_atom(name), do: Process.whereis(name)

  @impl GenServer
  def init(opts) do
    # Test seam for deterministic timeout and drain paths.
    {:ok, %{commit_fun: Keyword.get(opts, :commit_fun, &OpsObject.commit_object/4)}}
  end

  # One message at a time; engine logic remains in OpsObject.
  @impl GenServer
  def handle_call({:commit, work_dir, ref, content, opts}, _from, state) do
    {:reply, state.commit_fun.(work_dir, ref, content, opts), state}
  end

  # The same caller's drain request follows its earlier commit request.
  def handle_call(:drain_confirm, _from, state), do: {:reply, :drained, state}
end
