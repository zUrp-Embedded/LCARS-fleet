defmodule Fleet.Pilot.StepDispatcher.ProjectResolver do
  @moduledoc """
  Resolves clone and deliverable-gate base pins through runtime-authenticated Git reads.
  StepDispatcher delegates its default project resolver here; pods receive the resulting
  project metadata, not the credentials used to query the remote.
  """

  @doc """
  Returns `{:ok, project}` with repo URL, clone branch and base/gate SHAs, or a typed error.
  Returns `{:ok, nil}` when no forge URL is configured. `:base_branch` is required even
  in that case: a missing value raises rather than silently choosing the code face.

  An absent or identical gate branch reuses the clone SHA, avoiding two inconsistent
  observations of the same moving ref. A distinct gate branch requires another read;
  those two refs are not sampled atomically.
  """
  @spec default_project_resolver(String.t(), keyword()) ::
          {:ok, map() | nil} | {:error, term()}
  def default_project_resolver(repo, opts) do
    forge_opts = Keyword.get(opts, :forge_opts, [])

    # The caller chooses the face or feature branch; this resolver must not substitute main.
    base_branch =
      Keyword.get(opts, :base_branch) ||
        raise(
          ArgumentError,
          "default_project_resolver: :base_branch missing for #{inspect(repo)} — the FACE " <>
            "decision is made once at the dispatch entry and threaded, never re-defaulted here " <>
            "(single-default-site doctrine, face-projet)."
        )

    # Rebase resolution may need a distinct gate base from clone base.
    gate_base_branch = Keyword.get(opts, :gate_base_branch)

    case forge_base_url(forge_opts) do
      nil ->
        {:ok, nil}

      base_url ->
        repo_url = "#{String.trim_trailing(base_url, "/")}/#{repo}.git"

        with {:ok, sha} <- ls_remote_sha(repo_url, base_branch),
             {:ok, gate_sha} <-
               resolve_gate_base_sha(repo_url, gate_base_branch, sha, base_branch) do
          # Carry the full repository identity through pod completion; repo_path is the remote URL.
          {:ok,
           %{
             "repo" => repo,
             "repo_path" => repo_url,
             "base_branch" => base_branch,
             "base_sha" => sha,
             "gate_base_sha" => gate_sha
           }}
        end
    end
  end

  # Default ancestry checks start at the clone pin; rebase paths may choose a different gate target.
  defp resolve_gate_base_sha(_repo_url, nil, clone_base_sha, _base_branch),
    do: {:ok, clone_base_sha}

  # Reuse one observation when branches match; a second read could see a concurrent push.
  defp resolve_gate_base_sha(_repo_url, branch, clone_base_sha, base_branch)
       when is_binary(branch) and branch == base_branch,
       do: {:ok, clone_base_sha}

  defp resolve_gate_base_sha(repo_url, branch, _clone_base_sha, _base_branch)
       when is_binary(branch),
       do: ls_remote_sha(repo_url, branch)

  defp forge_base_url(forge_opts) do
    Keyword.get(forge_opts, :base_url) ||
      get_in(Application.get_env(:lcars_fleet, :pilot_forge, []), [:base_url])
  end

  # Bounded, authenticated runtime-side remote read.
  defp ls_remote_sha(repo_url, branch) do
    # DR-024: credentials fail before remote read; GitRef rejects option-like branch input.
    with :ok <- validate_branch(branch),
         {:ok, auth_env} <- Fleet.Credentials.ForgeAuth.git_env_result() do
      # Run outside the caller's repository to avoid inheriting its local URL rewrites/proxy.
      # Safe config flags separately disable execution hooks and related commands.
      # This assumes the temporary directory is outside Git; global URL/proxy config is not isolated.
      case Fleet.Credentials.Shell.git(
             Fleet.Credentials.Shell.git_safe_config_args() ++
               ["ls-remote", repo_url, branch],
             timeout_ms: 15_000,
             cd: System.tmp_dir!(),
             env: auth_env
           ) do
        {:ok, {out, 0}} ->
          parse_ls_remote_out(out)

        {:ok, {out, rc}} ->
          {:error, {rc, String.trim(out)}}

        {:error, {:timeout, _ms}} ->
          {:error, :timeout}

        {:error, {:exit, reason}} ->
          {:error, {:exit, reason}}

        {:error, reason} ->
          {:error, {:shell_error, reason}}
      end
    end
  end

  defp validate_branch(branch) do
    if Fleet.GitRef.valid?(branch),
      do: :ok,
      else: {:error, {:invalid_branch, inspect(branch)}}
  end

  # Validate the first line's first field as a full lowercase SHA; this does not verify the returned ref.
  @doc false
  @spec parse_ls_remote_out(String.t()) :: {:ok, String.t()} | {:error, term()}
  def parse_ls_remote_out(out) do
    case out |> String.split("\n", trim: true) |> List.first() do
      nil -> {:error, :no_ref}
      line -> full_sha(line |> String.split() |> List.first(), line)
    end
  end

  defp full_sha(sha, line) when is_binary(sha) do
    if Regex.match?(~r/\A[0-9a-f]{40}\z/, sha),
      do: {:ok, sha},
      else: {:error, {:malformed_ls_remote, String.slice(line, 0, 80)}}
  end

  defp full_sha(nil, line), do: {:error, {:malformed_ls_remote, String.slice(line, 0, 80)}}
end
