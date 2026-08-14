defmodule Fleet.Pilot.StepRunConsumer.GatekeeperEscalation do
  @moduledoc """
  Dispatches a one-shot per-project gatekeeper for an undecidable gate. The eval brief is enqueued
  before spawn or wake, and its metadata contains the complete resumption context. Spawn and wake
  failures are returned to the caller.

  This completion-triggered rail is lockless and never capacity-deferred; it is distinct from the
  poller-driven worker dispatch rail.
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

    # Enqueue before spawn or wake.
    #
    # ⚠ CET ORDRE LAISSE UN BRIEF SANS JUGE SI LE SPAWN ECHOUE, ET RIEN ICI NE LE RATTRAPE — ni
    # `clear`, ni retry, ni ecriture durable. La branche d'echec ci-dessous est honnete sur l'instant
    # (« brief enqueued but judge-less ») et MUETTE sur la suite, ce qui se lit comme une impasse.
    #
    # CE N'EN EST PAS UNE : le rattrapage existe, chez la reconciliation du poller, et il est ecrit
    # la-bas pour CE cas precis. Un eval enfile mais JAMAIS TIRE (`:pending`) est « an admission
    # WITHOUT an executor » et NE POSSEDE PAS le verrou de son issue — la propriete se lit sur
    # `@pulled_states [:assigned]`, le pull etant l'ACK durable qu'un executeur a active. Donc :
    #
    #   spawn rate -> eval `:pending`, aucun pod -> le verrou n'est possede par personne -> suspect
    #   -> grace de 2 ticks (~60 s) -> `reclaim_lock` -> le re-dispatch RE-ESCALADE UN EVAL FRAIS,
    #   dont l'enqueue supersede l'eval reste. Auto-repare, borne par le budget de rework.
    #
    # C'est la meme reprise que pour un wake perdu, et elle est epinglee : « a gate-eval stuck
    # `:pending` (never pulled — no executor) does NOT hold the lock: reclaimed at the 2nd tick ».
    #
    # Ce qui suit du coup de l'action « prouver/spawn le pod AVANT l'enqueue » : elle deplacerait la
    # fenetre sans la fermer (le pod peut mourir entre la preuve et l'enqueue) et couterait un spawn
    # sur chaque eval, y compris ceux qu'un gatekeeper deja vivant aurait servis. L'outbox
    # `gate_eval_pending`, elle, est le mecanisme absent que trois autres fiches attendent deja :
    # une seule question, pas un quatrieme demi-mecanisme.
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
      spawn_opts = [
        pod_id: pod_id,
        repo: seams.repo,
        repo_id: Spawn.resolve_repo_id(seams.forge, seams.repo, seams.forge_opts),
        brief: brief
      ]

      case seams.spawner.spawn_pod(cap, pod_id, spawn_opts) do
        {:ok, _pid} ->
          :ok

        {:error, {:already_started, _pid}} ->
          wake_recovery = seams.wake_recovery || (&Fleet.Pilot.WakeRecovery.wake/3)

          wake_recovery.(
            pod_id,
            fn -> seams.spawner.spawn_pod(cap, pod_id, spawn_opts) end,
            wake_fun: &seams.spawner.wake_pod/1,
            op: "gatekeeper-wake"
          )

        {:error, _reason} = err ->
          err
      end
    end
  end
end
