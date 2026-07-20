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
    2. `kick_architect/1` — active notification of the arch pod, a latency accelerator
       only: the truth (label `lcars-awaits-arch` + arch-addressed comment) is already on
       the forge; a failed kick is logged warning and the Poller (G4) re-kicks the arch
       every tick as long as an issue carries the label.

  Without this net (G2, the funnel), a terminal error bubbled up as log-only would make
  the rail churn: the reaper reclaims the lock 2 ticks later, re-dispatches the SAME step
  → re-fail → infinite loop without ever notifying a human.

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

  **Last revised**: 2026-07-21
  """

  require Logger

  alias Fleet.Pilot.StepRunConsumer.Verdict

  defmodule Seams do
    @moduledoc """
    Armored boundary of the terminal escalation: the ONLY authorized reads/effects.
    Built by the consumer from its DERIVED per-step-run state (`repo` comes from
    the event, multi-project). `run_completion` = the consumer's `(label, fun) -> outcome`
    closure (sync/offload discipline, single source consumer-side).
    """
    @enforce_keys [:repo, :step_run_completer, :completer_opts, :spawner, :task_queue, :run_completion]
    defstruct [
      # Repo "owner/name" of the step_run (per-step-run, derived from the event).
      :repo,
      # Completer module (seam, consumer-side default = Fleet.Pilot.StepRunCompleter).
      :step_run_completer,
      # Opts passed to the completer ([forge_opts: …] + optional :forge_client).
      :completer_opts,
      # Spawner for the arch kick (seam, consumer-side default = Fleet.Spawner).
      :spawner,
      # Broker for the arch's arbitration mandate (seam, consumer-side default = Fleet.TaskQueue) —
      # freeze_to_arch's post-commit offer-then-wake enqueues BEFORE it wakes (ArchWake), inside the
      # offloaded completion unit and only after a confirmed await_arch commit (CI-04).
      :task_queue,
      # Closure (label :: String.t(), fun :: (-> outcome)) -> outcome — sync/offload execution.
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
  Does a producer's result carry the `blocked` flag (missing dependency/info)?
  Predicate of the `escalate_blocked_producer/4` trigger — called by the consumer on
  the UNWRAPPED result (`Verdict.unwrap_worker_envelope`).
  """
  @spec blocked_flag?(term()) :: boolean()
  def blocked_flag?(m) when is_map(m), do: m["blocked"] == true
  def blocked_flag?(_), do: false

  @doc """
  G2 (funnel) — which end-of-step_run errors are TERMINAL NON-TRANSIENT
  (= a human wall, to be escalated) vs bubbled up as-is:

    * `rework_exhausted`: the budget is a MONOTONIC counter (signed step_runs) →
      re-dispatch = re-fail, never convergence without intervention → ESCALATE.
    * `rework_budget_unreadable`: the code explicitly chooses to "surface" rather
      than bounce blindly (an unverifiable bounce could loop) → ESCALATE.
    * `gate_fail_unsigned`: the failed run could not be signed onto the budget counter
      (forge write outage). Rebounding on an unbudgeted run would reopen the runaway
      (counter frozen while rework spawns) → SURFACE, not bounce → ESCALATE. Symmetric
      to `rework_budget_unreadable` (budget unreadable ↔ budget unwritable).
    * `human_approval_required` (D2/G3): human approval required (gate) → direct escalation
      (not a failure, not a rework).

  Everything else (`:no_gatekeeper` wrapped as `gatekeeper_dispatch`, workflow_map nav, workflow_map
  load…) stays bubbled up: transient (the one-shot gatekeeper is (re)spawned next tick) or of a
  different concern (G6 → IncidentRegistry).
  """
  @spec terminal_escalate?(term()) :: boolean()
  def terminal_escalate?({:rework_exhausted, _}), do: true
  def terminal_escalate?({:rework_budget_unreadable, _}), do: true
  def terminal_escalate?({:gate_fail_unsigned, _}), do: true
  def terminal_escalate?({:human_approval_required, _}), do: true
  # DR-013: an unloadable cap-profile at completion is a TERMINAL config anomaly (the producer/judge
  # property is unknown). ESCALATE, never bubble: bubbling would let the reaper re-dispatch a persistently
  # broken profile forever (G2 churn) without notifying a human.
  def terminal_escalate?(:cap_profile_unloadable), do: true
  def terminal_escalate?(_), do: false

  @doc """
  Escalates a BLOCKED PRODUCER to the human, reason = its `summary` voice (extracted from
  the `pod.completed` payload). A producer that cannot deliver marks `blocked: true`
  in its result; WITHOUT this escalation, the publish without a commit fail-louds
  `:no_deliverable_commit` = silent WEDGE (an honest eng refuses to guess →
  un-escalated blockage). Reuses the whole `freeze_to_arch/5` net.
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
  Escalates a TERMINAL error (classified by `terminal_escalate?/1`) to the human,
  explanatory message derived from the `reason` (rework exhausted / unreadable budget / required approval).
  """
  @spec escalate_terminal_error(term(), pos_integer(), String.t(), Seams.t()) :: term()
  def escalate_terminal_error(reason, n, role, %Seams{} = seams),
    do: freeze_to_arch(n, role, :terminal_error, terminal_error_message(reason, role), seams)

  @doc """
  THE single freeze-to-arch gesture: `await_arch` (comment + `lcars-awaits-arch` +
  unlock) via `run_completion`, THEN — inside the SAME offloaded unit, GATED on a confirmed
  commit — the offer-then-wake of the arch (`ArchWake`, latency only: the durable truth is the
  forge state — label + comment — and a failed kick, logged warning, is retried by the Poller's
  cooldown-capped awaits-arch net). Returns the completion's outcome (the kick never alters the
  result). Also called by the consumer for the fail-closed verdicts (redirect/escalate_user/halt_*)
  — net parity.
  """
  @spec freeze_to_arch(pos_integer(), String.t(), term(), String.t(), Seams.t()) :: term()
  def freeze_to_arch(n, role, decision, comment_body, %Seams{} = seams) do
    step_run = %{
      repo: seams.repo,
      issue_number: n,
      role: role,
      decision: decision,
      comment_body: comment_body
    }

    # WAKE-AFTER-COMMIT, inside the offloaded unit (CI-04). `run_completion` is SYNC by default but
    # in prod it OFFLOADS onto a Task.Supervisor and returns `{:ok, :offloaded}` at once — so an
    # offer-then-wake placed AFTER this call (outside the closure) fired BEFORE await_arch's forge
    # writes, or on a synchronous `{:error, _}`: the arch was woken onto a mandate that did not exist
    # yet. This reopened, one layer up, the very 2026-07-18 signal-before-content race that ArchWake's
    # internal enqueue-then-wake order (design 2026-07-19: "first kick immediate, protection BEHIND")
    # was built to close. The fix is ORDERING, not deferral to the poll grid: the offer-then-wake now
    # lives INSIDE the completion closure and only after await_arch returns `{:ok, _}` — a confirmed
    # forge commit (comment + label). On `{:error, _}` the escalation did NOT commit → we do NOT wake
    # the arch onto a non-existent mandate; the Poller net (cooldown-capped) re-derives the wake next
    # tick from the durable forge state, if any took. The offer stays best-effort (`safe_offer_then_wake`
    # NEVER alters the completion's outcome).
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

  # The immediate kick must never take the completion down with it (the escalation is GRAVED
  # on the forge at this point): any raise is demoted to a loud warning — the Poller net
  # covers the latency.
  defp safe_offer_then_wake(%Seams{} = seams, n) do
    _ = Fleet.Pilot.ArchWake.offer_then_wake(seams.task_queue, seams.spawner, {seams.repo, n}, "immediate")
    :ok
  rescue
    e ->
      Logger.warning(
        "StepRunConsumer: immediate arch offer-then-wake raised #{inspect(e)} (non-blocking — " <>
          "label intact, Poller net retries)"
      )

      :ok
  catch
    # A GenServer.call on a dead/absent broker EXITS (it does not raise) — same demotion:
    # the escalation is already graved on the forge, the net covers the latency.
    :exit, reason ->
      Logger.warning(
        "StepRunConsumer: immediate arch offer-then-wake exited #{inspect(reason)} (non-blocking — " <>
          "label intact, Poller net retries)"
      )

      :ok
  end

  @doc """
  NOTIFIES the arch (the SOLE airlock to the human) that a verdict (escalate/abandon) or a blockage requires
  its attention. The KICK is a latency accelerator via the UNIVERSAL wake (`wake_pod`: CARRIER/MCP flag →
  send-keys fallback → log; every pod arms its Monitor at spawn). **NO reboot**: the arch is the human's SESSION,
  never killed/restarted by the fleet (an unreachable arch = the human restarts ITS session, not us) — hence NO
  `WakeRecovery.wake` (which carries a respawn). Wake failure → log-loud (warning), non-blocking: the truth is the
  forge state (label `lcars-awaits-arch` + the arch-addressed comment stay), the arch queries its inbox on the
  next round, and the Poller (G4) re-kicks every tick while the label is present.
  """
  @spec kick_architect(module(), String.t()) :: :ok
  def kick_architect(spawner, repo) do
    # Pod id of THIS project's architect (per-project since the 2026-07-19 reorg) — SINGLE
    # AUTHORITY `Fleet.Pilot.ProjectArchitect.pod_id_for/1` (no rebuilt literal).
    pod_id = Fleet.Pilot.ProjectArchitect.pod_id_for(repo)

    case spawner.wake_pod(pod_id) do
      :ok ->
        :ok

      other ->
        Logger.warning(
          "StepRunConsumer: kick arch #{pod_id} → #{inspect(other)} (arch unreachable? the human restarts their " <>
            "session — the fleet does NOT reboot the arch; label+comment remain)"
        )

        :ok
    end
  rescue
    e ->
      Logger.warning("StepRunConsumer: kick arch raised #{inspect(e)} (non-blocking)")
      :ok
  end

  # Completion log label — derived from the decision (same wording as the
  # consumer's history: continuity of existing greps/logs).
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
