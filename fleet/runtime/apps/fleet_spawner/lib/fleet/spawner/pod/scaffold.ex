defmodule Fleet.Spawner.Pod.Scaffold do
  @moduledoc """
  WORKSPACE & SESSION du pod_dir — île extraite de `Fleet.Spawner.Pod`, recentrée 2026-07-05.

  Les étapes disque du boot qui touchent le SUBSTRAT de travail du pod : GC de l'UUID de session
  avant un re-spawn (`:cleaning`), bootstrap du workspace projet (clone git + branche doc,
  `:projecting`) et restauration du seed de recall (`:projecting`). Les deux autres familles
  d'étapes ont leurs îles dédiées : les ASSETS vendor/priv (`Pod.Assets` — settings/draft/
  protocole/watch.sh) et le BRIEF (`Pod.Brief` — `issues/<id>.md` + enqueue TaskQueue).

  Ce module N'ORCHESTRE PAS : les ÉTATS `:cleaning`/`:projecting` restent au cœur du `Pod` (leur
  gros `with` est l'orchestrateur). Chaque étape rend `:ok` ou un `{:error, reason}` taggé que le
  `with` de l'état `:projecting` propage vers `transition_failed` (cleanup clean : phase=failed +
  state.json écrit). Le `Pod` lui passe le `state` en argument ; le module ne rappelle AUCUN
  private de `Pod` (pas de cycle).

  ## Contrat (appelé par `Pod`)

  - `gc_stale_session_jsonl(state)` — appelé par l'état `:cleaning` (GC de l'UUID de session avant
    un re-spawn `--session-id`).
  - `maybe_bootstrap_project_workspace(state)` / `maybe_recall_restore(state)` — étapes appelées
    dans le `with` de l'état `:projecting`.

  Dépend de `Pod.LaunchSpec` (cwd/projet effectif), `Pod.SessionFiles` (glob partagé des jsonl de
  session), `Fleet.CapProfile` (source unique du `name` + `with_project/2`),
  `Fleet.ProjectBootstrap.Phase.Clone` (clone workspace + doc) et `Fleet.Spawner.SeedStore`
  (restore recall). Aucune dépendance vers `Fleet.Spawner.Pod`.
  """

  require Logger

  alias Fleet.Spawner.Pod.LaunchSpec
  alias Fleet.Spawner.Pod.SessionFiles

  @doc """
  Supprime tout `<session_id>.jsonl` résiduel sous le pod_dir (tous cwd-slugs, glob partagé
  `SessionFiles.jsonl_paths/2`) → libère l'UUID pour `--session-id` (un jsonl stale ferait heurter
  « Session ID already in use » au re-spawn déterministe). Best-effort : un échec ne casse pas le
  spawn. Appelé par l'état `:cleaning` (skip si `resume` — `SeedStore.restore` écrase le jsonl).
  """
  @spec gc_stale_session_jsonl(map()) :: :ok
  def gc_stale_session_jsonl(state) do
    state.pod_dir
    |> SessionFiles.jsonl_paths(state.session_id)
    |> Enum.each(fn f ->
      _ = File.rm(f)

      Logger.info(
        "Pod.gc #{state.pod_id}: jsonl stale #{Path.basename(f)} retiré (GC UUID → session frais)"
      )
    end)
  end

  @doc """
  Câblage de `Fleet.ProjectBootstrap.Phase.Clone` pour les pods porteurs d'un projet
  (`repo_path`) : le projet EFFECTIF vient du BRIEF (`LaunchSpec.effective_project/2` :
  `opts[:project]` injecté par le dispatch issue→repo) ou du cap_profile statique (pods
  permanents). Présent : clone le repo dans `<pod_dir>/workspace/` + checkout feature branch +
  branche doc (`work/ops` — nil si le projet n'a pas de branche doc, fail-loud si déclarée mais
  absente) ; le cwd du REPL pointe sur ce workspace (`maybe_put_pod_cwd` → `LCARS_POD_CWD`) →
  l'agent code DANS sa branche (clone idempotent au respawn). Le `CLAUDE.md` composé est copié à
  la racine du workspace (avec cwd=workspace il doit être DANS le cwd). Absent (`repo_path` nil) →
  no-op.

  L'identité git du rôle n'est PAS posée ici (pas de `git config` mutable, falsifiable) : elle est
  injectée en env au lancement (`LaunchEnv.build` → `GIT_AUTHOR_*`/`GIT_COMMITTER_*`) et la
  garantie vit côté monde (gate DeliverableGate au push).
  """
  @spec maybe_bootstrap_project_workspace(map()) ::
          :ok | {:error, {:project_workspace_clone_failed, term()}}
  def maybe_bootstrap_project_workspace(state) do
    project = LaunchSpec.effective_project(state.opts, state.cap_profile)

    case project["repo_path"] do
      nil ->
        :ok

      _repo_path ->
        # cap_profile porteur du projet EFFECTIF (brief > statique) pour les Clone.* (qui lisent spec.project).
        eff_cap = Fleet.CapProfile.with_project(state.cap_profile, project)

        with {:ok, workspace, branch} <-
               Fleet.ProjectBootstrap.Phase.Clone.clone_or_skip(
                 state.pod_dir,
                 eff_cap,
                 []
               ),
             # Doc-mount (mundo invocado) : la branche `work/ops` (plans/backlog/conventions) à côté
             # du code. nil si le projet n'a pas de branche doc ; fail-loud si déclarée mais absente.
             {:ok, doc} <-
               Fleet.ProjectBootstrap.Phase.Clone.clone_work_doc(
                 state.pod_dir,
                 eff_cap
               ) do
          # CLAUDE.md composé (pod-identité + conventions repo) à la racine du CWD (workspace) :
          # l'agent pop dans un projet déjà documenté. L'état :projecting l'écrit au pod_dir (parent) ;
          # avec cwd=workspace il doit être DANS le cwd (sinon l'agent code sans sa codebase-doc en cwd).
          _ = File.cp(Path.join(state.pod_dir, "CLAUDE.md"), Path.join(workspace, "CLAUDE.md"))

          Logger.info(
            "pod #{state.pod_id} workspace=#{workspace} (branch=#{branch || "default"})" <>
              if(doc, do: " doc=#{doc}", else: " (pas de branche doc)")
          )

          :ok
        else
          {:error, reason} -> {:error, {:project_workspace_clone_failed, reason}}
        end
    end
  end

  @doc """
  Recall délibéré. Si `opts[:recall_seed_jsonl]` est fourni (par `Fleet.Spawner.recall/2`),
  restaure le seed à `projects/<slugify(cwd)>/<session_id>.jsonl` AVANT le launch ; claude
  `--resume <session_id>` (resume:true via opts) le retrouve. Gaté : absent → no-op (spawn normal
  intact). Le seed est validé (`read_map`) côté `Spawner.recall` ; absent ICI = fail-loud
  (`{:recall_seed_missing, _}` → `transition_failed`).
  """
  @spec maybe_recall_restore(map()) :: :ok | {:error, {:recall_seed_missing, String.t()}}
  def maybe_recall_restore(state) do
    case Keyword.get(state.opts, :recall_seed_jsonl) do
      nil ->
        :ok

      jsonl when is_binary(jsonl) ->
        if File.exists?(jsonl) do
          {:ok, _} =
            Fleet.Spawner.SeedStore.restore(
              jsonl,
              state.pod_dir,
              LaunchSpec.pod_cwd(state.opts, state.cap_profile, state.pod_dir),
              state.session_id
            )

          :ok
        else
          {:error, {:recall_seed_missing, jsonl}}
        end
    end
  end
end
