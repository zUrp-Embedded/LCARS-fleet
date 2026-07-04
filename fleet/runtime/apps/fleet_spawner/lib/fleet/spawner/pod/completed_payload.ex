defmodule Fleet.Spawner.Pod.CompletedPayload do
  @moduledoc """
  Builder PUR du payload de l'event `pod.completed` — île extraite de `Fleet.Spawner.Pod`.

  Un seul rôle : à partir du `data` du gen_statem (LU, jamais muté) + le `result` reçu, construire
  la map du payload `pod.completed` que `Pod` diffuse via `Pod.Events.required_broadcast/2`. Aucun
  state propre, aucun Port, aucun timer, aucune écriture FS : que du calcul déterministe sur les
  quelques champs lus (`pod_id`, `issue_id`, `opts`, `cap_profile`, `pod_dir`). Jumeau du
  `Fleet.Pilot.BriefBuilder` (autre payload builder pur extrait de son orchestrateur).

  Le builder N'EST PAS logé dans `Pod.Events` : celui-ci est un cluster ENVELOPPE-only (il construit
  le `%Fleet.Event{}` + broadcaste, il ne connaît PAS le FORMAT du payload). Séparer garde chaque
  frontière nette — `Events` = comment on diffuse, `CompletedPayload` = quoi on met dedans.

  ## Vocabulaire `pod.completed` (FIGÉ — le StepRunConsumer en dépend)

  `pod.completed` est LIFECYCLE load-bearing : le `Fleet.Pilot.StepRunConsumer` en dépend pour finir
  le step_run. Les CLÉS du payload (`pod_id`/`issue_id`/`result`/`workspace`/`base_sha`/`gate_base_sha`/
  `role`/`repository`/`remote`/`workflow_map`/`step`) sont un contrat — ce module en est la source
  unique de construction.

  ## Contrat (appelé par `Pod`)

  - `build(data, result)` — rend la map du payload. Site d'appel unique dans l'état `:extracting`
    (`Events.required_broadcast("pod.completed", CompletedPayload.build(data, result))`).

  ## Dépendances (frères / en-bas — pas de cycle vers `Pod`)

  - `Fleet.Spawner.Pod.LaunchSpec.effective_project/2` (projet EFFECTIF, source unique),
  - `Fleet.Spawner.Pod.Paths.pod_workspace_path/1` (autorité unique du sous-dossier workspace),
  - `Fleet.CapProfile.name/1` (source unique du rôle gravé au spawn).
  """

  alias Fleet.Spawner.Pod.LaunchSpec
  alias Fleet.Spawner.Pod.Paths

  @doc """
  Construit la map du payload `pod.completed` depuis le `data` du gen_statem (LU, jamais muté) +
  le `result` reçu. Pod-projet (`repo_path` présent) → embarque `workspace`/`base_sha`/
  `gate_base_sha`/`role` (+ `repository`/`remote` si `repo`) ; pod sans projet → payload nu
  (base). Le contexte workflow_map (`workflow_map_id`+`step`) n'est porté que SI le pod est
  spawné avec ces clés — plus aucun appelant ne les pose aujourd'hui, en pratique le payload est
  nu (un consommateur qui reçoit un payload nu ignore le contexte workflow_map, no-op).
  """
  @spec build(map(), map()) :: map()
  def build(data, result) do
    base = %{
      "pod_id" => data.pod_id,
      "issue_id" => data.issue_id,
      "result" => result
    }

    opts = data.opts || []

    case {Keyword.get(opts, :workflow_map_id), Keyword.get(opts, :step)} do
      {nil, _} ->
        # Pod step-dispatch (assignee-driven) hors workflow_map. S'il porte un PROJET (repo cloné), le
        # payload embarque le contexte de fin-de-step-run : le consumer StepRunConsumer est stateless (l'event
        # porte l'état). Pod sans projet (memory-X, architect) → payload nu (base), filtré en aval.
        case LaunchSpec.effective_project(data.opts, data.cap_profile) do
          %{"repo_path" => rp} = proj when is_binary(rp) and rp != "" ->
            base
            |> Map.merge(%{
              # Autorité unique du sous-dossier workspace (Pod.Paths), pas un littéral recopié.
              "workspace" => Paths.pod_workspace_path(data.pod_dir),
              "base_sha" => proj["base_sha"],
              # Base de la GATE de livraison, DÉCONFLÉE de la clone-base (`base_sha`). Pour une
              # résolution par rebase, le livrable doit DESCENDRE de `main` (cible du rebase). Le
              # resolver l'égale à `base_sha` pour le forward (build/rework). Fallback `base_sha`.
              "gate_base_sha" => proj["gate_base_sha"] || proj["base_sha"],
              "role" => Fleet.CapProfile.name(data.cap_profile)
            })
            |> maybe_put_repo(proj)
            |> maybe_put_workflow_map_ctx(opts)

          _ ->
            base
        end

      {workflow_map_id, step} ->
        Map.merge(base, %{"workflow_map_id" => workflow_map_id, "step" => step})
    end
  end

  # Contexte workflow_map (workflow_map+step) injecté au spawn par StepDispatcher via `:workflow_map`/`:step`.
  # Permet au StepRunConsumer de naviguer la workflow_map. Absent (workflow_map 1-step) → payload inchangé.
  defp maybe_put_workflow_map_ctx(payload, opts) do
    case {Keyword.get(opts, :workflow_map), Keyword.get(opts, :step)} do
      {p, s} when is_binary(p) and is_binary(s) ->
        Map.merge(payload, %{"workflow_map" => p, "step" => s})

      _ ->
        payload
    end
  end

  # Multi-projet : embarque le REPO du projet dans `pod.completed` → le StepRunConsumer sait sur quel
  # repo agir + où pousser. `"repository" => %{"full_name"}` = identifiant forge ; `"remote"` = l'URL
  # de push. Projet sans `"repo"` → payload inchangé → fallback single-repo du StepRunConsumer.
  defp maybe_put_repo(payload, %{"repo" => repo} = proj) when is_binary(repo) and repo != "" do
    payload
    |> Map.put("repository", %{"full_name" => repo})
    |> maybe_put_remote(proj["repo_path"])
  end

  defp maybe_put_repo(payload, _proj), do: payload

  defp maybe_put_remote(payload, remote) when is_binary(remote) and remote != "",
    do: Map.put(payload, "remote", remote)

  defp maybe_put_remote(payload, _), do: payload
end
