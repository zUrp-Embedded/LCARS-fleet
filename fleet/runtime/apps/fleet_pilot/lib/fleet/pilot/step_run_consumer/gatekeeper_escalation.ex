defmodule Fleet.Pilot.StepRunConsumer.GatekeeperEscalation do
  @moduledoc """
  Cluster IMPUR « escalade gatekeeper » (async-out) extrait de `Fleet.Pilot.StepRunConsumer`.

  Quand une gate `:soft`/terminal non-tranchable escalade (`{:dispatch_gatekeeper, _}`), ce
  module CONVOQUE le gatekeeper permanent :

    1. enqueue un brief d'éval au gatekeeper PERMANENT (work-session, adressé par `pod_id` via la
       TaskQueue — l'overseer n'est PAS spawné/possédé ici) ;
    2. kicke le pod (best-effort avec recovery de wake) ;
    3. rend le `correlation_id` (= task.id) pour la reprise async
       (`task_queue.work_item.completed` → `resume_gate`).

  Il ne DÉCIDE PAS de la route : le cœur décisionnel stateful (`gate_decide`/`resume_gate`/
  `apply_verdict`) reste le SINGLE-AUTHORITY du module racine, qui appelle `dispatch/7` sur le
  seul chemin `{:dispatch_gatekeeper, _}`.

  ## Frontière : struct de seams explicite (pas `state` entier)

  Le cluster ne lit QUE 4 seams du `state` du consumer (`task_queue`, `spawner`,
  `gatekeeper_pod_id_fun`, `wake_recovery`). On NE passe PAS le `state` entier — ce serait une
  fuite de frontière : le caller construit un `%Seams{}` (contrat étroit, TYPÉ → dialyzer voit
  exactement les 4 champs, aucune autre lecture de state n'est représentable ici). Le struct
  (vs une map nue) est le choix qui BLINDE le mieux la frontière : `@enforce_keys` force les 4
  champs à l'appel, et un accès `seams.<autre_champ>` ne compile pas (KeyError statique). Une map
  laisserait passer `Map.get(seams, :repo)` en silence.

  ## Contrat de retour étroit

  `dispatch/7 :: {:ok, corr} | {:error, reason}` — `gate_decide` consomme ce contrat tel quel :
  `{:ok, corr}` → escalade légitime (`{:escalate, corr, eval_ctx}`) ; `{:error, reason}` →
  fail-loud (`{:error, {:gatekeeper_dispatch, reason}}`, jamais un pass silencieux).
  """

  require Logger

  defmodule Seams do
    @moduledoc """
    Contrat de frontière du cluster d'escalade : les 4 seams async-out lus du `state` du
    `StepRunConsumer`. Construit par le caller AVANT `dispatch/7` — le cluster ne reçoit jamais
    le `state` entier.
    """
    @enforce_keys [:task_queue, :spawner, :gatekeeper_pod_id_fun, :wake_recovery]
    defstruct [:task_queue, :spawner, :gatekeeper_pod_id_fun, :wake_recovery]

    @type t :: %__MODULE__{
            # Broker de briefs d'éval (défaut prod `Fleet.TaskQueue`).
            task_queue: module(),
            # Wake du pod gatekeeper (défaut prod `Fleet.Spawner`).
            spawner: module(),
            # Résout le pod_id du gatekeeper permanent (`nil` si non booté → fail-loud).
            gatekeeper_pod_id_fun: (-> any()),
            # Recovery de wake (respawn au 1er échec, escalade starfleet au 2e) ; `nil` → défaut.
            wake_recovery: (... -> any()) | nil
          }
  end

  @doc """
  Convocation forge-driven du gatekeeper sur escalade de gate. Enqueue un brief d'éval au
  gatekeeper PERMANENT (adressé par `pod_id`), kicke (best-effort), et rend le `correlation_id`
  (= task.id) pour la corrélation `task_queue.work_item.completed`. Pas de gatekeeper booté /
  enqueue raté → `{:error, _}` (l'appelant fail-loud ; jamais un pass silencieux).

  `outputs`/`payload`/`n`/`role` sont EMBARQUÉS dans le metadata de la tâche d'éval (contexte de
  reprise auto-descriptif) : le StepRunConsumer redémarré (gate_evals RAM vide) reconstruit
  l'eval_ctx du metadata au lieu de jeter le verdict en silence.
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
    case seams.gatekeeper_pod_id_fun.() do
      pod_id when is_binary(pod_id) ->
        gate = get_in(workflow_map, ["steps", step, "gate"])
        workflow_map_name = Map.get(workflow_map, "name")

        brief =
          Fleet.Workflow.GateBrief.build(%{
            step: step,
            workflow_map_id: workflow_map_name,
            gate: gate,
            outputs: outputs
          })

        # VERDICT AUTO-DESCRIPTIF : le metadata de la tâche d'éval porte le contexte de REPRISE
        # (`payload`/`n`/`role` en plus du step/workflow_map_name déjà présents). Cette tâche survit dans le broker
        # (TaskQueue = autre process) à un crash du StepRunConsumer seul → le verdict (`work_item.completed`) ramène
        # ce metadata → le StepRunConsumer redémarré (gate_evals RAM vidé) reconstruit l'eval_ctx
        # (`workflow_map = Loader.load!(workflow_map_name)`) au lieu d'un `{:noreply}` silencieux (issue wedgée à vie). Aucune
        # NOUVELLE source : `payload` porte déjà `workspace`/`base_sha`/`gate_base_sha` — on l'embarque tel quel.
        attrs = %{
          # Cible d'escalade = le gatekeeper (juge d'exception STRUCTUREL, GATE-D1) — via l'accesseur
          # UNIQUE `Roles.gatekeeper_role` (config-overridable), plus un littéral épars. Ce n'est PAS
          # configurable par map : le gatekeeper EST l'escalade (il gère la patate chaude via son SP).
          role: Fleet.Pilot.Roles.gatekeeper_role(),
          brief: brief,
          metadata: %{
            "gate_eval" => true,
            "step" => step,
            "workflow_map" => workflow_map_name,
            "gate" => gate,
            "outputs" => outputs,
            "resume_payload" => payload,
            "resume_n" => n,
            "resume_role" => role
          }
        }

        case seams.task_queue.enqueue(pod_id, attrs) do
          {:ok, %{id: corr}} ->
            # Le retour du kick est LOAD-BEARING : si le wake escalade (gatekeeper injoignable →
            # starfleet) ou échoue, on ne l'AVALE PAS (`_ = kick`). Le brief d'éval EST enqueué (corr
            # valide) → l'escalade gatekeeper reste légitime ({:escalate, corr, …}) ; mais un kick non
            # joignable est SURFACÉ (telemetry + warning distinct), pas confondu avec un kick OK. Sans ça,
            # un gatekeeper jamais réveillé resterait invisible (le verdict ne reviendrait jamais, gate stallée
            # en silence). `corr` retourné dans les deux cas (le brief survit, le re-wake/escalade le couvre).
            case kick(seams, pod_id) do
              :ok ->
                {:ok, corr}

              {:error, reason} ->
                :telemetry.execute(
                  [:fleet_pilot, :step_run_consumer, :gatekeeper_kick_unreached],
                  %{count: 1},
                  %{pod_id: pod_id, corr: corr, reason: reason}
                )

                Logger.warning(
                  "StepRunConsumer: gatekeeper #{pod_id} kické MAIS INJOIGNABLE (#{inspect(reason)}) — " <>
                    "brief d'éval enqueué (corr=#{inspect(corr)}), escalade WakeRecovery active ; le verdict " <>
                    "ne reviendra qu'au re-wake/réparation (pas un kick silencieux qui ment)"
                )

                {:ok, corr}
            end

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:error, :no_gatekeeper}
    end
  end

  # KICK le gatekeeper après l'enqueue. Pod PERMANENT déjà booté+idle (:monitoring) : son kick-loop de
  # boot est fini, ce brief arrive APRÈS → sans wake il ne pull jamais (gate qui stalle). Un wake
  # raté = panne FLEET (pod injoignable), PAS un pb projet → re-roll (reboot du gatekeeper) au 1er fail,
  # escalade système → starfleet au 2e. Pas de warn-et-oublie ici (le gatekeeper est un juge, pas un
  # sysadmin : il ne peut rien faire d'une erreur système).
  defp kick(seams, pod_id) do
    wake_recovery = seams.wake_recovery || (&Fleet.Pilot.WakeRecovery.wake/3)

    wake_recovery.(pod_id, fn -> Fleet.Workflow.Gatekeeper.reboot() end,
      wake_fun: fn p -> seams.spawner.wake_pod(p) end
    )
  end
end
