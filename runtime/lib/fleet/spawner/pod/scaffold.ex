defmodule Fleet.Spawner.Pod.Scaffold do
  @moduledoc """
  Prepares pod workspaces and session files: stale UUID cleanup, project clone and recall
  seed restoration. Pod orchestrates these steps in cleaning/projecting and handles
  returned errors; `Pod.Assets` owns static assets and `Pod.Brief` owns brief delivery.
  """

  require Logger

  alias Fleet.Spawner.Pod.LaunchSpec
  alias Fleet.Spawner.Pod.SessionFiles

  @doc """
  Renames matching stale session JSONLs to `.dead`, freeing the UUID while retaining
  one generation of transcript evidence. Best-effort; a rename failure is logged and
  may leave the vendor reporting the session ID already in use.
  """
  @spec gc_stale_session_jsonl(map()) :: :ok
  def gc_stale_session_jsonl(state) do
    state.pod_dir
    |> SessionFiles.jsonl_paths(state.session_id)
    |> Enum.each(fn f ->
      # Renaming leaves one predecessor transcript for diagnosis while removing it from *.jsonl scans.
      case File.rename(f, f <> ".dead") do
        :ok ->
          Logger.info(
            "pod #{state.pod_id} gc: stale jsonl #{Path.basename(f)} -> .dead (UUID freed, transcript kept one generation)"
          )

        {:error, :enoent} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "pod #{state.pod_id} gc: could NOT rename stale jsonl #{Path.basename(f)} " <>
              "(#{inspect(reason)}) — the --session-id launch will surface it as 'Session ID already in use'"
          )
      end
    end)
  end

  @doc """
  Bootstraps a project workspace from opts[:project] or the profile’s static project.
  A missing repo_path is a no-op. Clone errors are tagged `:project_workspace_clone_failed`.

  After cloning, enriches the pod’s composed CLAUDE.md with filtered repository sections.
  The repository’s tracked CLAUDE.md stays intact and stageable. If none is tracked,
  copy the composed document into the workspace and exclude it locally from Git.
  Document enrichment/copy failures log without refusing launch.

  LaunchSpec supplies the other production face separately; LaunchEnv supplies Git identity,
  with deliverable checks enforcing it at publication.
  """
  @spec maybe_bootstrap_project_workspace(map()) ::
          :ok | {:error, {:project_workspace_clone_failed, term()}}
  def maybe_bootstrap_project_workspace(state) do
    project = LaunchSpec.effective_project(state.opts, state.cap_profile)

    case project["repo_path"] do
      nil ->
        :ok

      _repo_path ->
        eff_cap = Fleet.CapProfile.with_project(state.cap_profile, project)

        case Fleet.ProjectBootstrap.Phase.Clone.clone_or_skip(state.pod_dir, eff_cap, []) do
          {:ok, workspace, branch} -> settle_workspace_doc(state, workspace, branch)
          {:error, reason} -> {:error, {:project_workspace_clone_failed, reason}}
        end
    end
  end

  # Composition precedes cloning, so repository sections can only be read here. Read them
  # from Git rather than a possibly composed working-tree copy, then apply ReceptionFilter.
  defp settle_workspace_doc(state, workspace, branch) do
    claim_workspace_doc(maybe_enrich_claude_md(state, workspace), state, workspace)

    Logger.info("pod #{state.pod_id} workspace=#{workspace} (branch=#{branch || "default"})")

    :ok
  end

  # A tracked CLAUDE.md is both input and deliverable. Overwriting or hiding it would make
  # producer edits disappear from Git evidence; pod identity already comes through the system prompt.
  defp claim_workspace_doc(:tracked, state, _workspace) do
    Logger.info(
      "pod #{state.pod_id} workspace CLAUDE.md: celui du DEPOT, intact et livrable " <>
        "(la doctrine du pod arrive par le system-prompt, plus par ce fichier)"
    )
  end

  # For untracked repos, place the composed document at the actual cwd; copy failure is nonfatal.
  defp claim_workspace_doc(_repo_doc, state, workspace),
    do: copy_composed_claude_md(state, workspace)

  @doc """
  Restores an explicit recall seed under the resolved cwd and session ID before launch.

  A missing seed or restore exception returns a tagged projection error.
  """
  @spec maybe_recall_restore(map()) ::
          :ok
          | {:error, {:recall_seed_missing, String.t()} | {:recall_restore_failed, String.t()}}
  def maybe_recall_restore(state) do
    case Keyword.get(state.opts, :recall_seed_jsonl) do
      nil ->
        :ok

      jsonl when is_binary(jsonl) ->
        if File.exists?(jsonl) do
          try do
            {:ok, _dest} =
              Fleet.Spawner.SeedStore.restore(
                jsonl,
                state.pod_dir,
                LaunchSpec.pod_cwd(state.opts, state.cap_profile, state.pod_dir),
                state.session_id
              )

            :ok
          rescue
            e -> {:error, {:recall_restore_failed, Exception.message(e)}}
          end
        else
          {:error, {:recall_seed_missing, jsonl}}
        end
    end
  end

  # Exclude only the generated, untracked document so git add -A cannot ship pod identity.
  # .git/info/exclude stays local and does not affect tracked repository documents.
  defp copy_composed_claude_md(state, workspace) do
    case File.cp(Path.join(state.pod_dir, "CLAUDE.md"), Path.join(workspace, "CLAUDE.md")) do
      :ok ->
        exclude_composed_claude_md(workspace)

      {:error, reason} ->
        Logger.warning(
          "pod #{state.pod_id} CLAUDE.md → workspace copy FAILED (#{inspect(reason)}) — " <>
            "the agent's cwd lacks its codebase-doc (pod identity)"
        )
    end
  end

  defp exclude_composed_claude_md(workspace) do
    exclude = Path.join(workspace, ".git/info/exclude")
    line = "/CLAUDE.md"

    with {:ok, content} <-
           (case File.read(exclude) do
              {:ok, c} -> {:ok, c}
              {:error, :enoent} -> {:ok, ""}
              err -> err
            end),
         false <- String.contains?(content, line),
         :ok <- File.mkdir_p(Path.dirname(exclude)),
         :ok <- File.write(exclude, line <> "\n", [:append]) do
      :ok
    else
      true ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "pod: composed CLAUDE.md NOT excluded in #{workspace} (#{inspect(reason)}) — " <>
            "a pod commit-all could ship it (the gate allows root CLAUDE.md by design)"
        )
    end

    :ok
  end

  # Original presence is determined at HEAD. Enrichment failures retain :tracked so the
  # caller preserves that deliverable even when the pod-side composition failed.
  defp maybe_enrich_claude_md(state, workspace) do
    case Fleet.ProjectBootstrap.Phase.Clone.read_original_claude_md(workspace) do
      :absent ->
        :absent

      {:ok, original} ->
        repo_source = Path.join(state.pod_dir, "CLAUDE.md.repo-source")

        with :ok <- File.write(repo_source, original),
             {:ok, md} <- Fleet.SPBuilder.compose_claude_md(state.cap_profile, repo_source),
             :ok <- File.write(Path.join(state.pod_dir, "CLAUDE.md"), md) do
          :tracked
        else
          {:error, reason} ->
            Logger.warning(
              "pod #{state.pod_id} repo-section enrichment FAILED (#{inspect(reason)}) — " <>
                "the pod launches on the identity-only CLAUDE.md (no repo conventions)"
            )

            # Return :tracked on enrichment failure too: a degraded copy must not overwrite the original.
            :tracked
        end
    end
  end
end
