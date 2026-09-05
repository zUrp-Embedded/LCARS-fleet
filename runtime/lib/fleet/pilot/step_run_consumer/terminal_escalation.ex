defmodule Fleet.Pilot.StepRunConsumer.TerminalEscalation do
  @moduledoc """
  TERMINAL escalation to the human (the "human wall") of
  `Fleet.Pilot.StepRunConsumer`: when the end of a step_run CANNOT be resolved by
  the machine (rework exhausted, unreadable budget, human approval required, blocked producer,
  fail-closed verdict), we FREEZE the issue toward the arch and kick it.

  ## The single net `freeze_to_arch/5`

  All terminal escalations go through THE SAME gesture (single source, never
  re-derived by a caller):

    1. `await_arch` via the StepRunCompleter — comment addressed to the arch +
       label `lcars-awaits-arch` + UNLOCK (`lcars-in-flight` removed). The unlock is
       LOAD-BEARING: the poller no longer re-dispatches (the issue carries `lcars-awaits-arch`,
       skipped) → the churn stops, the human decides.
    2. `Fleet.Pilot.ArchWake.offer_then_wake/4`, INSIDE the completion closure and only after
       step 1 returned `{:ok, _}` — a latency accelerator only: the truth (label
       `lcars-awaits-arch` + arch-addressed comment) is already on the forge; a failed wake is
       logged and the Poller (G4) re-offers the arch every tick as long as an issue carries the
       label.

  `kick_architect/3` is NOT part of this net: it carries CONTENT (the abandon trace) to the arch
  pod on the `"abandon"` verdict, from `StepRunConsumer`, under the same rule — inside the closure,
  after the close reached the forge.

  Without this net (G2, the funnel), a terminal error bubbled up as log-only would make
  the rail churn: the reaper reclaims the lock 2 ticks later, re-dispatches the SAME step
  → re-fail → infinite loop without ever notifying a human.

  ## Family

  One link of the escalation FAMILY. The register — the links ordered by the DEPTH they reach —
  lives once, in `Fleet.Pilot`'s moduledoc; a new link is placed there by depth, never counted
  (no count-based merge threshold).

  ## Armored boundary

  The module NEVER receives the consumer's state: `Seams` (narrow struct) carries the
  5 authorized reads/effects — including `run_completion`, the consumer's execution
  closure (SINGLE SOURCE of the sync/offload discipline: the execution policy
  stays with the consumer, the escalation does not choose its mode).

  ## Who decides what

  `terminal_escalate?/1` (pure) classifies TERMINAL NON-TRANSIENT errors; the
  consumer calls it on the `{:error, reason}` path of the gate decision. The
  transient / self-healing errors (`:no_gatekeeper` → the one-shot gatekeeper is
  (re)spawned on the next tick; unreadable workflow_map → IncidentRegistry, G6) bubble up unchanged.
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
  Whether a completion error requires human arbitration instead of retry or propagation.
  """
  @spec terminal_escalate?(term()) :: boolean()
  def terminal_escalate?({:rework_exhausted, _}), do: true
  def terminal_escalate?({:rework_budget_unreadable, _}), do: true
  def terminal_escalate?({:gate_fail_unsigned, _}), do: true
  def terminal_escalate?({:human_approval_required, _}), do: true

  # DR-013
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
  Commits the await-architect state, then offers and wakes the architect only after success.
  """
  # `decision` est HETEROGENE : `:blocked_dep` et `:terminal_error` sur les deux chemins nommes,
  # une BINAIRE sur les autres (la branche `other` de `StepRunConsumer.apply_verdict`, et
  # `VerdictCorrection.freeze/5` qui passe `"halt_invalid"`). `label/2` l'absorbe par sa clause
  # fourre-tout et la valeur part telle quelle dans le `step_run` durable. Le spec dit l'etat, il
  # ne le corrige pas.
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

    # CI-04
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
  Sends terminal verdict content to the project architect. Falls back to a bare wake when the spawner
  does not implement notification. Failures are logged and remain non-blocking.
  """
  @spec kick_architect(module(), String.t(), String.t()) :: :ok
  def kick_architect(spawner, repo, message) do
    pod_id = Fleet.Project.Architect.pod_id_for(repo)

    if Fleet.Opts.exported?(spawner, :notify_pod, 2) do
      # ⚠ CETTE BRANCHE NE JETTE PAS SON RESULTAT, sans quoi le `@doc` juste au-dessus — « Failures
      # are logged » — ne serait vrai que de l'AUTRE branche. C'est le chemin d'escalade TERMINALE :
      # le moment ou un step_run a echoue definitivement et ou l'architecte du projet doit etre
      # prevenu. Pod absent du registre -> message perdu, et rien ne le dirait.
      #
      # `error` et non `warning` : `notify_pod/2` ne connait pas l'enjeu de son message et le
      # signale au niveau du fait ; ICI on sait que ce qui vient d'etre perdu est le dernier
      # avertissement d'un ticket mort. Doctrine des niveaux : perte reelle = `error`.
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
    # Same net as `safe_offer_then_wake/2`: this runs INSIDE the completion closure after a close
    # that succeeded; an exit here would report that close as lost.
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
