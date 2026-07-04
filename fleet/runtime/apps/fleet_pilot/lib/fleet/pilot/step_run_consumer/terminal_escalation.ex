defmodule Fleet.Pilot.StepRunConsumer.TerminalEscalation do
  @moduledoc """
  Escalade TERMINALE vers l'humain (le « mur humain »), extraite de
  `Fleet.Pilot.StepRunConsumer` : quand une fin de step_run ne peut PAS être résolue par
  la machine (rework épuisé, budget illisible, aval humain requis, producteur bloqué,
  verdict fail-closed), on GÈLE l'issue vers l'arch et on le kick.

  ## Le filet unique `freeze_to_arch/5`

  Toutes les escalades terminales passent par LE MÊME geste (source unique, jamais
  re-dérivé par un appelant) :

    1. `await_arch` via le StepRunCompleter — comment adressé à l'arch +
       label `lcars-awaits-arch` + UNLOCK (`lcars-in-flight` retiré). L'unlock est
       LOAD-BEARING : le poller ne re-dispatche plus (l'issue porte `lcars-awaits-arch`,
       skippée) → le churn s'arrête, l'humain tranche.
    2. `kick_architect/1` — notification active best-effort du pod arch.

  Sans ce filet (G2, l'entonnoir), une erreur terminale remontée en log-only ferait
  churner le rail : le reaper réclame le verrou 2 ticks après, re-dispatch le MÊME step
  → re-fail → boucle infinie sans jamais notifier un humain.

  ## Frontière blindée

  Le module ne reçoit JAMAIS le state du consumer : `Seams` (struct étroit) porte les
  5 lectures/effets autorisés — dont `run_completion`, la closure d'exécution du
  consumer (SOURCE UNIQUE de la discipline sync/offload : la politique d'exécution
  reste au consumer, l'escalade ne choisit pas son mode).

  ## Qui décide quoi

  `terminal_escalate?/1` (pur) classe les erreurs TERMINALES NON-TRANSITOIRES ; le
  consumer l'appelle sur le chemin `{:error, reason}` de la décision de gate. Les
  erreurs transitoires / auto-réparantes (`:no_gatekeeper` → le gatekeeper permanent
  reboote ; workflow_map illisible → IncidentRegistry, G6) remontent inchangées.
  """

  require Logger

  alias Fleet.Pilot.StepRunConsumer.Verdict

  defmodule Seams do
    @moduledoc """
    Frontière blindée de l'escalade terminale : les SEULES lectures/effets autorisés.
    Construit par le consumer depuis son state DÉRIVÉ per-step-run (`repo` vient de
    l'event, multi-projet). `run_completion` = closure `(label, fun) -> outcome` du
    consumer (discipline sync/offload, source unique côté consumer).
    """
    @enforce_keys [:repo, :step_run_completer, :completer_opts, :spawner, :run_completion]
    defstruct [
      # Repo "owner/name" du step_run (per-step-run, dérivé de l'event).
      :repo,
      # Module completer (seam, défaut côté consumer = Fleet.Pilot.StepRunCompleter).
      :step_run_completer,
      # Opts passés au completer ([forge_opts: …] + :forge_client éventuel).
      :completer_opts,
      # Spawner pour le kick de l'arch (seam, défaut côté consumer = Fleet.Spawner).
      :spawner,
      # Closure (label :: String.t(), fun :: (-> outcome)) -> outcome — exécution sync/offload.
      :run_completion
    ]

    @type t :: %__MODULE__{
            repo: String.t() | nil,
            step_run_completer: module(),
            completer_opts: keyword(),
            spawner: module(),
            run_completion: (String.t(), (-> term()) -> term())
          }
  end

  @doc """
  Le result d'un producteur porte-t-il le flag `blocked` (dépendance/info manquante) ?
  Prédicat du déclencheur de `escalate_blocked_producer/4` — appelé par le consumer sur
  le result DÉPLIÉ (`Verdict.unwrap_worker_envelope`).
  """
  @spec blocked_flag?(term()) :: boolean()
  def blocked_flag?(m) when is_map(m), do: m["blocked"] == true
  def blocked_flag?(_), do: false

  @doc """
  G2 (entonnoir) — quelles erreurs de fin de step_run sont TERMINALES NON-TRANSITOIRES
  (= un mur humain, à escalader) vs remontées telles quelles :

    * `rework_exhausted` : le budget est un compteur MONOTONE (step_runs signés) →
      re-dispatch = re-fail, jamais de convergence sans intervention → ESCALADE.
    * `rework_budget_unreadable` : le code choisit explicitement de « surfacer » plutôt
      que rebondir à l'aveugle (un rebond non vérifiable pourrait boucler) → ESCALADE.
    * `human_approval_required` (D2/G3) : aval humain requis (gate) → escalade directe
      (pas un échec, pas un rework).

  Tout le reste (`:no_gatekeeper` wrappé `gatekeeper_dispatch`, nav workflow_map, load
  workflow_map…) reste remonté : transitoire (le gatekeeper permanent reboote) ou d'un
  autre concern (G6 → IncidentRegistry).
  """
  @spec terminal_escalate?(term()) :: boolean()
  def terminal_escalate?({:rework_exhausted, _}), do: true
  def terminal_escalate?({:rework_budget_unreadable, _}), do: true
  def terminal_escalate?({:human_approval_required, _}), do: true
  def terminal_escalate?(_), do: false

  @doc """
  Escalade un PRODUCTEUR BLOQUÉ vers l'humain, motif = sa voix `summary` (extraite du
  payload `pod.completed`). Un producteur qui ne peut pas livrer marque `blocked: true`
  dans son result ; SANS cette escalade, la publish sans commit fail-loud
  `:no_deliverable_commit` = WEDGE silencieux (un eng honnête refuse de deviner →
  blocage non escaladé). Réutilise tout le filet `freeze_to_arch/5`.
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
  Escalade une erreur TERMINALE (classée par `terminal_escalate?/1`) vers l'humain,
  message explicatif dérivé du `reason` (rework épuisé / budget illisible / aval requis).
  """
  @spec escalate_terminal_error(term(), pos_integer(), String.t(), Seams.t()) :: term()
  def escalate_terminal_error(reason, n, role, %Seams{} = seams),
    do: freeze_to_arch(n, role, :terminal_error, terminal_error_message(reason, role), seams)

  @doc """
  LE geste unique de gel vers l'arch : `await_arch` (comment + `lcars-awaits-arch` +
  unlock) via `run_completion`, PUIS kick de l'arch (best-effort). Rend l'outcome de la
  complétion (le kick n'altère jamais le résultat). Aussi appelé par le consumer pour
  les verdicts fail-closed (redirect/escalate_user/halt_*) — parité de filet.
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

    result =
      seams.run_completion.(label(n, decision), fn ->
        seams.step_run_completer.await_arch(step_run, seams.completer_opts)
      end)

    # KICK l'arch : un gel vers l'arch sans notification = une issue qui attend en silence.
    _ = kick_architect(seams.spawner)
    result
  end

  @doc """
  NOTIFIE l'arch (sas UNIQUE vers l'humain) qu'un verdict (escalate/abandon) ou un blocage requiert
  son attention. KICK best-effort via le wake UNIVERSEL (`wake_pod` : flag PORTEUR/MCP → fallback send-keys
  → log ; tout pod arme son Monitor au spawn). **PAS de reboot** : l'arch est la SESSION de l'humain, jamais
  kill/relancée par la fleet (un arch injoignable = l'humain relance SA session, pas nous) — d'où PAS de
  `WakeRecovery.wake` (qui porte un respawn). Échec wake → log-loud, non-bloquant (le label `lcars-awaits-arch`
  + le commentaire adressé-arch restent ; l'arch query son inbox au prochain tour).
  """
  @spec kick_architect(module()) :: :ok
  def kick_architect(spawner) do
    # Pod id de l'arch permanent (sas user) — AUTORITÉ UNIQUE `Fleet.Pilot.Roles` (partagée
    # avec le re-kick awaits-arch du Poller ; pas de littéral "permanent-architect" ici).
    pod_id = Fleet.Pilot.Roles.architect_pod_id()

    case spawner.wake_pod(pod_id) do
      :ok ->
        :ok

      other ->
        Logger.warning(
          "StepRunConsumer: kick arch #{pod_id} → #{inspect(other)} (arch injoignable ? l'humain relance sa " <>
            "session — la fleet ne reboot PAS l'arch ; label+commentaire restent)"
        )

        :ok
    end
  rescue
    e ->
      Logger.warning("StepRunConsumer: kick arch a levé #{inspect(e)} (non-bloquant)")
      :ok
  end

  # Label de log de la complétion — dérivé de la décision (mêmes libellés que
  # l'historique du consumer : suivi des greps/logs existants).
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

  defp terminal_error_message({:human_approval_required, _reason}, role) do
    "✋ **Aval humain requis** (step `#{role}`, gate `human_approval_required`) — le livrable attend TON " <>
      "approbation. Valide (relance le cycle) ou renvoie en correction. La fleet ne s'auto-approuve jamais."
  end
end
