defmodule Fleet.Pilot.StepRunCompleter.Emissions do
  @moduledoc """
  Émissions ANNEXES de la livraison producteur (voix de l'eng + event slot-freeze),
  extraites de `Fleet.Pilot.StepRunCompleter` : tout ce qui accompagne la publication
  d'un livrable SANS faire partie de la séquence de complétion.

  ## Best-effort par contrat

  Les deux émissions sont **best-effort** : un échec ne casse JAMAIS la complétion
  (le livrable = le commit, déjà poussé ; la PR est déjà ouverte). C'est précisément
  ce contrat qui rend le concern séparable : la séquence du completer (ordre, verrou,
  idempotence) ne dépend d'AUCUN retour d'ici — l'appelant discard (`_ =`).

  Appelées par `complete_producer` APRÈS `open_deliverable_pr` (le push a déjà LU le
  workspace) et AVANT `route` (le verrou n'est pas encore levé).

  Mêmes seams keyword que le completer (`:forge_client` / `:forge_opts`) — pas de
  struct dédié : le module vit dans l'orbite du completer et lit les mêmes opts.
  """

  require Logger

  alias Fleet.Pilot.ForgeClient

  @doc """
  SLOT-FREEZE : signale que le livrable du producteur est CONFIRMÉ sur la forge (commit poussé + PR
  ouverte) → un pod pipe résident peut alors reset son workspace pour le issue suivant SANS courser
  le push. Porte le `pod_id` (le pod producteur, depuis le payload pod.completed). Source `:workflow`
  (la publication est une op du moteur workflow ; atome aligné sur le rename fleet_pipeline→fleet_workflow —
  l'atome nu :pipeline avait survécu au sed du rename, seul émetteur, zéro matcher par source).
  Best-effort : un échec d'émission ne casse PAS la complétion (le livrable est déjà publié) — le
  backstop côté pod (deadline :publishing) couvre un raté. No-op si pas de pod_id (legacy/test).
  """
  @spec deliverable_published(map(), integer()) :: :ok | :noop
  def deliverable_published(step_run, pr) do
    case Map.get(step_run, :pod_id) do
      pod_id when is_binary(pod_id) ->
        result =
          Fleet.EventRouter.Bus.emit(:workflow, :"deliverable.published",
            pod_id: pod_id,
            payload: %{
              "repo" => Map.fetch!(step_run, :repo),
              "issue" => Map.fetch!(step_run, :issue_number),
              "pr" => pr
            }
          )

        case result do
          :ok ->
            :ok

          other ->
            Logger.warning(
              "StepRunCompleter: deliverable.published non diffuse (#{inspect(other)})"
            )

            :ok
        end

      _ ->
        :noop
    end
  rescue
    e ->
      Logger.warning("StepRunCompleter: deliverable.published a leve (#{inspect(e)})")
      :ok
  end

  @doc """
  VOIX DE L'ENG sur la PR (info SORTANTE, descriptive et traçable) : poste le
  `summary` du producteur (ce qu'il a fait à la livraison / sa réponse à la review au rework) en
  commentaire PR, AU NOM DE L'ENG (`as_role` — traça honnête ; le pod reste forge-aveugle, c'est
  le SYSTÈME qui poste). Best-effort : un échec de post ne casse PAS la complétion (le livrable = le
  commit, déjà poussé). Absent/vide → rien (pas de commentaire vide). Couvre livraison ET rework (les
  deux passent par open_deliverable_pr — PR neuve ou existante).

  DÉDUP (footprint) : la NOTE COMPLÈTE va sur le ISSUE (le ticket = record canonique du travail,
  « voici ce que j'ai fait » en réponse au brief) ; la PR ne reçoit qu'un POINTEUR vers le ticket
  (le reviewer review le diff ; la prose de l'eng vit UNE seule fois, sur le ticket). Avant, le même
  `summary` (~1 Ko) était posté verbatim des deux côtés — bruit pur.
  """
  @spec post_eng_summary(map(), integer(), keyword()) :: :ok | :noop
  def post_eng_summary(step_run, pr, opts) do
    case Map.get(step_run, :eng_summary) do
      summary when is_binary(summary) and summary != "" ->
        forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
        forge_opts = Keyword.get(opts, :forge_opts, [])
        repo = Map.fetch!(step_run, :repo)
        n = Map.fetch!(step_run, :issue_number)
        role = Map.get(step_run, :role, "engineer")
        role_opts = ForgeClient.as_role(forge_opts, role)

        # NOTE COMPLÈTE sur le ISSUE (record canonique du travail).
        _ =
          forge.post_comment(
            repo,
            n,
            "## 🔧 Note de l'#{role} (livrable)\n\n#{summary}",
            role_opts
          )

        # POINTEUR sur la PR (pas le blob) : `##{n}` est auto-linké par Gitea → le reviewer suit le lien
        # s'il veut la prose ; sinon il review le diff. Fin de la dup verbatim (l'intuition user).
        _ =
          forge.post_comment(
            repo,
            pr,
            "🔧 Note de l'#{role} (livrable) → détail sur le ticket ##{n}.",
            role_opts
          )

        :ok

      _ ->
        :noop
    end
  end
end
