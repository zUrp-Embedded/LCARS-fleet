defmodule Fleet.Pilot.StepRunConsumer.TerminalEscalation do
  @moduledoc """
  Routes selected gate failures and blocked producers to the architect through await_arch.

  freeze_to_arch delegates execution to the consumer's run_completion closure. After
  await_arch returns ok, it offers/wakes the architect; an offload admission return
  does not itself confirm forge writes. The awaits-arch label excludes worker dispatch,
  and ArchWake/Poller provide further notification opportunities subject to their guards.

  kick_architect instead sends abandonment content after successful closure; a bare
  wake fallback loses that content. Both notification helpers rescue exceptions and
  exits, not throws. Their success is not proof the architect received or acted.

  terminal_escalate? selects policy categories, not proof of permanent failure:
  unreadable budgets/profiles can be repairable. Other errors propagate to their caller.
  This module is one member of the escalation family documented in Fleet.Pilot.
  """

  require Logger

  alias Fleet.Pilot.StepRunConsumer.Verdict

  defmodule Seams do
    @moduledoc """
    Forge completion and architect-notification dependencies for an escalation.
    """
    @enforce_keys [
      :repo,
      :step_run_completer,
      :completer_opts,
      :spawner,
      :task_queue,
      :run_completion
    ]
    defstruct [
      :repo,
      :step_run_completer,
      :completer_opts,
      :spawner,
      :task_queue,
      :run_completion
    ]

    @type t :: %__MODULE__{
            repo: String.t() | nil,
            step_run_completer: module(),
            completer_opts: keyword(),
            spawner: module(),
            task_queue: module(),
            run_completion: (String.t(), (-> term()) -> term())
          }
  end

  @doc """
  Whether an unwrapped producer result explicitly reports that it is blocked.
  """
  @spec blocked_flag?(term()) :: boolean()
  def blocked_flag?(m) when is_map(m), do: m["blocked"] == true
  def blocked_flag?(_), do: false

  @doc """
  Whether this error category is routed to human arbitration by the consumer.
  """
  @spec terminal_escalate?(term()) :: boolean()
  def terminal_escalate?({:rework_exhausted, _}), do: true
  def terminal_escalate?({:rework_budget_unreadable, _}), do: true
  def terminal_escalate?({:gate_fail_unsigned, _}), do: true
  def terminal_escalate?({:human_approval_required, _}), do: true

  def terminal_escalate?(:cap_profile_unloadable), do: true
  def terminal_escalate?(_), do: false

  @doc """
  Escalates a blocked producer with its summary as the human-facing reason.
  """
  @spec escalate_blocked_producer(map(), pos_integer(), String.t(), Seams.t()) :: term()
  def escalate_blocked_producer(payload, n, role, %Seams{} = seams) do
    reason = Verdict.eng_summary(payload)

    lead =
      if reason == "",
        do: "🚧 **#{role} BLOQUÉ** (dépendance/info manquante) — motif non fourni.",
        else: "🚧 **#{role} BLOQUÉ** (dépendance/info manquante) :\n\n#{reason}"

    freeze_to_arch(n, role, :blocked_dep, lead, seams)
  end

  @doc """
  Escalates a terminal error with a reason-specific human message.
  """
  @spec escalate_terminal_error(term(), pos_integer(), String.t(), Seams.t()) :: term()
  def escalate_terminal_error(reason, n, role, %Seams{} = seams),
    do: freeze_to_arch(n, role, :terminal_error, terminal_error_message(reason, role), seams)

  @doc """
  Runs await_arch then offers/wakes after its ok result, within the supplied execution closure.
  Returns the runner's result, which may indicate offload admission rather than completion.
  """
  # Decisions include atoms and verdict strings; preserve them in the completion data.
  @spec freeze_to_arch(pos_integer(), String.t(), atom() | String.t(), String.t(), Seams.t()) ::
          term()
  def freeze_to_arch(n, role, decision, comment_body, %Seams{} = seams) do
    step_run = %{
      repo: seams.repo,
      issue_number: n,
      role: role,
      decision: decision,
      comment_body: comment_body
    }

    seams.run_completion.(label(n, decision), fn ->
      case seams.step_run_completer.await_arch(step_run, seams.completer_opts) do
        {:ok, _} = committed ->
          safe_offer_then_wake(seams, n)
          committed

        {:error, _} = failed ->
          failed
      end
    end)
  end

  defp safe_offer_then_wake(%Seams{} = seams, n) do
    _ =
      Fleet.Pilot.ArchWake.offer_then_wake(
        seams.task_queue,
        seams.spawner,
        {seams.repo, n},
        "immediate"
      )

    :ok
  rescue
    e ->
      Logger.warning(
        "StepRunConsumer: immediate arch offer-then-wake raised #{inspect(e)} (non-blocking — " <>
          "label intact, Poller net retries)"
      )

      :ok
  catch
    :exit, reason ->
      Logger.warning(
        "StepRunConsumer: immediate arch offer-then-wake exited #{inspect(reason)} (non-blocking — " <>
          "label intact, Poller net retries)"
      )

      :ok
  end

  @doc """
  Notifies the project architect, or wakes without content if notify_pod is unavailable.

  Returned notify errors log at error level; the wake fallback logs non-ok returns.
  Exceptions and exits warn and return ok. Throws propagate; no notification replay occurs here.
  """
  @spec kick_architect(module(), String.t(), String.t()) :: :ok
  def kick_architect(spawner, repo, message) do
    pod_id = Fleet.Project.Architect.pod_id_for(repo)

    if Fleet.Opts.exported?(spawner, :notify_pod, 2) do
      # Terminal notification loss merits error level; do not hide a returned notify failure.
      case spawner.notify_pod(pod_id, message) do
        {:error, reason} ->
          Logger.error(
            "TerminalEscalation: architecte #{pod_id} (#{repo}) INJOIGNABLE (#{inspect(reason)}) " <>
              "— le verdict terminal n'a PAS ete remis et rien ne le rejoue ; l'incident reste " <>
              "dans le registre et l'issue forge, la notification est perdue"
          )

        _ ->
          :ok
      end

      :ok
    else
      case spawner.wake_pod(pod_id) do
        :ok ->
          :ok

        other ->
          Logger.warning(
            "StepRunConsumer: notify arch #{pod_id} → #{inspect(other)} (arch unreachable? the human restarts " <>
              "their session — the fleet does NOT reboot the arch; the closing comment remains)"
          )

          :ok
      end
    end
  rescue
    e ->
      Logger.warning("StepRunConsumer: notify arch raised #{inspect(e)} (non-blocking)")
      :ok
  catch
    # Do not let a notification exit invalidate an earlier closure.
    :exit, reason ->
      Logger.warning("StepRunConsumer: notify arch exited #{inspect(reason)} (non-blocking)")
      :ok
  end

  defp label(n, :blocked_dep), do: "##{n} (blocked)"
  defp label(n, :terminal_error), do: "##{n} (terminal-error)"
  defp label(n, _other), do: "##{n}"

  defp terminal_error_message({:rework_exhausted, %{step_runs: sr, budget: b}}, role) do
    "🛑 **Rework épuisé** (dernier producteur : `#{role}`) — #{sr}/#{b} step_runs signés, budget atteint.\n\n" <>
      "L'issue ne peut plus avancer seule (re-dispatch = re-échec). Corrige le brief ou la workflow_map, " <>
      "ou abandonne l'issue."
  end

  defp terminal_error_message({:rework_budget_unreadable, reason}, _role) do
    "🛑 **Budget de rework illisible** (`#{inspect(reason)}`) — on ne rebondit pas à l'aveugle (risque de " <>
      "boucle). Vérifie l'état forge de l'issue (comments `[step_run:…]`) puis relance ou abandonne."
  end

  defp terminal_error_message({:gate_fail_unsigned, reason}, role) do
    "🛑 **Échec de gate non comptabilisé** (step `#{role}`, `#{inspect(reason)}`) — impossible de signer ce " <>
      "run raté sur le compteur forge (écriture KO). On ne rebondit PAS sans le débiter (un rework non " <>
      "budgété peut boucler à l'infini). Vérifie l'accès en écriture à la forge puis relance ou abandonne."
  end

  defp terminal_error_message(:cap_profile_unloadable, role) do
    "🛑 **Cap-profile illisible** (rôle `#{role}`) — le profil a disparu/corrompu depuis le spawn : impossible " <>
      "de savoir si ce rôle PRODUIT du code ou juge. On ne devine PAS (un vrai producteur traité en juge " <>
      "perdrait son livrable). Répare le cap-profile canon du rôle puis relance."
  end

  defp terminal_error_message({:human_approval_required, _reason}, role) do
    "✋ **Aval humain requis** (step `#{role}`, gate `human_approval_required`) — le livrable attend TON " <>
      "approbation. Valide (relance le cycle) ou renvoie en correction. La fleet ne s'auto-approuve jamais."
  end
end
