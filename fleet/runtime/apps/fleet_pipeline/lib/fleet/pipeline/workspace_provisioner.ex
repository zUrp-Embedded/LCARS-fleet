defmodule Fleet.Pipeline.WorkspaceProvisioner do
  @moduledoc """
  Provisionne le workspace d'une stage AVANT spawn du pod (face 2 brique 2.4,
  décision archi git capacité paramétrable, 2026-05-24).

  Convention du path : `<:workspaces_root>/<pipeline_id>/<stage>/workspace`.
  Clone `repo_url` à cet emplacement, checkout `branch` (créée si absente du
  remote). Le pod ne touche pas au workspace ; il livre un payload structuré
  (`result.files`) que l'Executor applique post-EXTRACT avant `Fleet.Pipeline.Git.publish/1`.

  Mécanisme **temporaire** en attendant le câblage de
  `Fleet.ProjectBootstrap.prepare/3` (#596) qui formalisera le workspace
  provisioning au sein du Ring 1 pod primitive. La signature ci-dessous est
  cohérente : un caller donne `pipeline_id`, `stage`, et `git_spec`
  (`%{"repo_url" => ..., "branch" => ...}`) ; on retourne le path workspace
  prêt à recevoir le pod + payload.
  """

  require Logger

  @type git_spec :: %{required(String.t()) => any()}

  @doc """
  Provisionne le workspace si `git_spec` est non-nil. Sinon no-op.

  Retourne `{:ok, workspace_path}` même quand no-op (le path n'est pas créé
  dans ce cas, juste calculé conventionnellement) — caller peut ignorer.

  Erreurs : `{:error, reason}` où reason ∈
    * `{:missing_key, key}` — git_spec sans repo_url/branch
    * `{:clone_failed, rc, output}` — git clone non-zero
    * `{:checkout_failed, rc, output}` — git checkout non-zero
  """
  @spec provision_for_stage(term(), String.t(), git_spec | nil) ::
          {:ok, Path.t()} | {:error, term()}
  def provision_for_stage(_pipeline_id, _stage, nil), do: {:ok, nil}

  def provision_for_stage(pipeline_id, stage, git_spec) when is_map(git_spec) do
    with {:ok, repo_url} <- fetch_string(git_spec, "repo_url"),
         {:ok, branch} <- fetch_string(git_spec, "branch") do
      workspace = workspace_dir_for(pipeline_id, stage)
      do_provision(workspace, repo_url, branch)
    end
  end

  @doc """
  Path workspace conventionnel pour `pipeline_id` + `stage`. Pure, sans I/O.
  Aligné sur `Fleet.Pipeline.Executor.workspace_dir_for/2` (face 2 brique 2.3).
  """
  @spec workspace_dir_for(term(), String.t()) :: Path.t()
  def workspace_dir_for(pipeline_id, stage) do
    root = Application.get_env(:fleet_pipeline, :workspaces_root, System.tmp_dir!())
    Path.join([root, to_string(pipeline_id), stage, "workspace"])
  end

  # ============================================================
  # Implementation
  # ============================================================

  defp fetch_string(map, key) do
    case Map.get(map, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, {:missing_key, key}}
    end
  end

  # Idempotence : si workspace existe déjà (retry), on ne re-clone pas. On
  # force quand même le checkout pour garantir la branche attendue.
  defp do_provision(workspace, repo_url, branch) do
    case {File.dir?(workspace), File.dir?(Path.join(workspace, ".git"))} do
      {false, _} -> clone_then_checkout(workspace, repo_url, branch)
      {true, true} -> checkout(workspace, branch)
      {true, false} -> {:error, {:workspace_exists_not_git, workspace}}
    end
  end

  defp clone_then_checkout(workspace, repo_url, branch) do
    parent = Path.dirname(workspace)

    case File.mkdir_p(parent) do
      :ok ->
        with :ok <- clone(workspace, repo_url) do
          checkout(workspace, branch)
        end

      {:error, reason} ->
        {:error, {:mkdir_failed, parent, reason}}
    end
  end

  defp clone(workspace, repo_url) do
    # BL-037 : clone système-side depuis une forge authentifiée → injecte le token forge `-c
    # http.<prefix>.extraheader` (jamais persisté dans la config du clone). `[]` si non-configuré (bare).
    case System.cmd("git", Fleet.Pipeline.Git.forge_auth_args() ++ ["clone", repo_url, workspace],
           stderr_to_stdout: true
         ) do
      {_out, 0} ->
        Logger.debug("fleet_pipeline workspace clone ok: #{workspace} <- #{repo_url}")
        :ok

      {out, rc} ->
        {:error, {:clone_failed, rc, String.trim(out)}}
    end
  end

  # Tente checkout direct (la branche existe peut-être déjà localement depuis
  # le clone). Sinon crée la branche locale depuis HEAD courant.
  #
  # audit elixir #4 : try_checkout peut fail pour 2 raisons distinctes —
  # (a) branche absente (cas attendu, fallback `-b` OK) ou (b) dirty working
  # tree / autre erreur git (le fallback create_branch va aussi fail mais
  # son `:checkout_failed` ne porte pas la trace de la cause primaire).
  # Log debug avant le fallback pour préserver le diagnostic d'incident.
  defp checkout(workspace, branch) do
    case try_checkout(workspace, branch) do
      :ok ->
        {:ok, workspace}

      {:error, reason} ->
        require Logger

        Logger.debug(
          "fleet_pipeline workspace try_checkout fail (fallback create_branch -b) : " <>
            inspect(reason)
        )

        create_branch(workspace, branch)
    end
  end

  defp try_checkout(workspace, branch) do
    case System.cmd("git", ["checkout", branch], cd: workspace, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, rc} -> {:error, {:try_checkout_failed, rc, String.trim(out)}}
    end
  end

  defp create_branch(workspace, branch) do
    case System.cmd("git", ["checkout", "-b", branch],
           cd: workspace,
           stderr_to_stdout: true
         ) do
      {_out, 0} -> {:ok, workspace}
      {out, rc} -> {:error, {:checkout_failed, rc, String.trim(out)}}
    end
  end
end
