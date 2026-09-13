defmodule Fleet.Pilot.StepRunConsumer.GatekeeperEscalation do
  @moduledoc """
  Enqueues a synthesized gate evaluation, then spawns or wakes an issue-keyed gatekeeper.

  This path takes no forge lock and has no capacity deferral/rollback. Returned spawn
  or wake failures leave the enqueued item; unexpected results or exceptions can raise.
  Metadata carries the original payload and named card/step for resumption, but not a
  card snapshot or top-level repo key for the consumer's reconstruction loader.
  """

  require Logger

  alias Fleet.Pilot.StepDispatcher.Spawn

  defmodule Seams do
    @moduledoc """
    Broker, pod and forge dependencies used for gatekeeper dispatch.
    """
    @enforce_keys [:task_queue, :spawner, :repo, :forge, :forge_opts]
    defstruct [:task_queue, :spawner, :repo, :forge, :forge_opts, :loader, :wake_recovery]

    @type t :: %__MODULE__{
            task_queue: module(),
            spawner: module(),
            repo: String.t(),
            forge: module(),
            forge_opts: keyword(),
            loader: module() | nil,
            wake_recovery: (String.t(), (-> any()), keyword() -> :ok | {:error, term()}) | nil
          }
  end

  @doc """
  Enqueues an evaluation brief, then spawns or wakes its gatekeeper. Returns the task correlation
  identifier or the dispatch error.
  """
  @spec dispatch(
          map(),
          String.t(),
          term(),
          map(),
          integer(),
          String.t() | nil,
          Seams.t()
        ) :: {:ok, term()} | {:error, term()}
  def dispatch(workflow_map, step, outputs, payload, n, role, %Seams{} = seams) do
    gk_role = Fleet.Project.Roles.gatekeeper_role()
    pod_id = Fleet.PodId.for_issue(seams.repo, n, gk_role)

    gate = get_in(workflow_map, ["steps", step, "gate"])

    load_name = Map.get(payload, "workflow_map") || Map.get(workflow_map, "name")
    declared_name = Map.get(workflow_map, "name")

    brief =
      Fleet.Workflow.GateBrief.build(%{
        step: step,
        workflow_map_id: declared_name,
        gate: gate,
        outputs: outputs
      })

    attrs = %{
      role: gk_role,
      brief: brief,
      metadata: %{
        "gate_eval" => true,
        "step" => step,
        "workflow_map" => load_name,
        "gate" => gate,
        "outputs" => outputs,
        "resume_payload" => payload,
        "resume_n" => n,
        "resume_role" => role
      }
    }

    # Enqueue first so a live gatekeeper can pull the brief. A failed spawn leaves pending
    # work without an executor; reconciliation's @pulled_states excludes such admissions.
    # Reclamation still depends on liveness, reads and grace, not a fixed retry deadline.
    # No durable pending-eval outbox exists here; pending work can disappear with the broker.
    case seams.task_queue.enqueue(pod_id, attrs) do
      {:ok, %{id: corr}} ->
        case spawn_gatekeeper(seams, pod_id, brief) do
          :ok ->
            {:ok, corr}

          {:error, reason} ->
            Logger.error(
              "StepRunConsumer: one-shot gatekeeper spawn FAILED (pod=#{pod_id}, #{inspect(reason)}) — " <>
                "gate eval cannot proceed (brief enqueued but judge-less); fail-loud upstream"
            )

            {:error, {:gatekeeper_spawn, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp spawn_gatekeeper(%Seams{} = seams, pod_id, brief) do
    loader = seams.loader || Fleet.CapProfile
    gk_role = Fleet.Project.Roles.gatekeeper_role()

    with {:ok, cap} <- Fleet.CapProfile.resolve(loader, gk_role) do
      # Inline synthesized gate/outputs, not an authored ops document with a pin to mount.
      # Profile resolution uses defaults; this path forwards no project catalogue root.
      spawn_opts = [
        pod_id: pod_id,
        repo: seams.repo,
        repo_id: Spawn.resolve_repo_id(seams.forge, seams.repo, seams.forge_opts),
        brief: brief
      ]

      seams.spawner.spawn_pod(cap, pod_id, spawn_opts)
      |> spawned_or_woken(seams, cap, pod_id, spawn_opts)
    end
  end

  # A stable issue identity may already exist; wake it so the queued evaluation can be pulled.
  defp spawned_or_woken({:ok, _pid}, _seams, _cap, _pod_id, _spawn_opts), do: :ok

  defp spawned_or_woken({:error, {:already_started, _pid}}, seams, cap, pod_id, spawn_opts) do
    wake_recovery = seams.wake_recovery || (&Fleet.Pilot.WakeRecovery.wake/3)

    wake_recovery.(
      pod_id,
      fn -> seams.spawner.spawn_pod(cap, pod_id, spawn_opts) end,
      wake_fun: fn pod -> seams.spawner.wake_pod(pod) end,
      op: "gatekeeper-wake"
    )
  end

  defp spawned_or_woken({:error, _reason} = err, _seams, _cap, _pod_id, _spawn_opts), do: err
end
