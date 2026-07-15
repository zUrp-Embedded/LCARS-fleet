defmodule Fleet.Pilot.StepDispatcher.ProjectResolver do
  @moduledoc """
  Project resolution: pinning the git base (`base_sha` / `gate_base_sha`) via `git ls-remote`,
  OUT-OF-POD. ISOLATED I/O cluster extracted from `Fleet.Pilot.StepDispatcher`.

  **Quasi-pure** boundary: this module touches NO seam module (no forge_client / spawner /
  task_queue / loader); it reads `opts` / `forge_opts` and calls `Fleet.Credentials.Shell` /
  `Fleet.Credentials.ForgeAuth` (runtime auth, never the pod — the pod is forge-blind).

  `default_project_resolver/2` is the PUBLIC API: it is the default of `StepDispatcher`'s
  `:project_resolver` seam (delegated from the root module via `defdelegate`) AND the fn called directly by
  the tests. The rest (gate-base resolution, base_url, ls-remote) is internal to this cluster.
  """

  # Builds `%{repo_path, base_branch, base_sha}` for the issue's repo.
  # `base_url` ← `:forge_opts[:base_url]` or app config; `base_branch` ← `:base_branch`
  # (default "main"). No forge configured → `{:ok, nil}` (pod without repo, e.g. local
  # tests). The clone/ls-remote auth is carried by the runtime (`Fleet.Credentials.ForgeAuth.
  # git_env`, token via env), never by the pod (forge-blind).
  @spec default_project_resolver(String.t(), keyword()) ::
          {:ok, map() | nil} | {:error, term()}
  def default_project_resolver(repo, opts) do
    forge_opts = Keyword.get(opts, :forge_opts, [])
    base_branch = Keyword.get(opts, :base_branch, "main")

    # DECONFLATION clone-base / gate-base. `base_sha` would otherwise conflate two
    # concerns: (1) the STARTING POINT of the clone (`pin_base_sha` resets HEAD onto it) and (2) the
    # GATE base (HEAD must DESCEND from it). Forward (build/rework): they coincide. RESOLUTION
    # by rebase: they DIVERGE — the pod starts from the feature (its work) but must descend from `main`.
    # `:gate_base_branch` (set by the dispatch resolve) pins the gate base separately; absent → the
    # gate falls back to the clone-base (`base_sha`), forward behavior UNCHANGED.
    gate_base_branch = Keyword.get(opts, :gate_base_branch)

    case forge_base_url(forge_opts) do
      nil ->
        {:ok, nil}

      base_url ->
        repo_url = "#{String.trim_trailing(base_url, "/")}/#{repo}.git"

        with {:ok, sha} <- ls_remote_sha(repo_url, base_branch),
             {:ok, gate_sha} <- resolve_gate_base_sha(repo_url, gate_base_branch, sha) do
          # `"repo"` (full_name "owner/name") embedded in the project → it travels all the way to the pod
          # then comes back out in `pod.completed` (`CompletedPayload.build`) → the StepRunConsumer knows on WHICH
          # repo to act (multi-project), without re-deriving it. `repo_path` = the push URL (per-step-run remote).
          {:ok,
           %{
             "repo" => repo,
             "repo_path" => repo_url,
             "base_branch" => base_branch,
             "base_sha" => sha,
             # gate_base_sha = the GATE base (≠ clone-base for a rebase resolution, cf. above).
             "gate_base_sha" => gate_sha
           }}
        end
    end
  end

  # The GATE base. Default (forward): = clone-base (`base_sha`) → the guard requires HEAD to descend
  # from where the pod cloned. A dispatch resolve passes `:gate_base_branch` ("main") → we pin the tip of
  # THAT branch (the rebase target): the guard then requires HEAD to descend from `main`, not from the old
  # feature tip (rewritten by the rebase → it would no longer be an ancestor, hence a `base_not_ancestor`).
  defp resolve_gate_base_sha(_repo_url, nil, clone_base_sha), do: {:ok, clone_base_sha}

  defp resolve_gate_base_sha(repo_url, branch, _clone_base_sha) when is_binary(branch),
    do: ls_remote_sha(repo_url, branch)

  defp forge_base_url(forge_opts) do
    Keyword.get(forge_opts, :base_url) ||
      get_in(Application.get_env(:fleet_pilot, :forge, []), [:base_url])
  end

  # `git ls-remote <repo_url> <branch>` bounded via `Fleet.Credentials.Shell` (single source of the bound)
  # + runtime auth → tip SHA (out-of-pod). Symmetric to the base pin on the pipeline side. The wrapper launches the
  # ls-remote (NETWORK: can hang/prompt) in its own process-group and, at the WALL deadline, kills the
  # whole GROUP (the ls-remote AND its transport helpers, holders of the forge token) + closes the port —
  # whereas the `Task.async` + `shutdown(:brutal_kill)` pattern only killed the BEAM Task while letting the
  # git process leak.
  defp ls_remote_sha(repo_url, branch) do
    # Forge token via env (out of argv/cmdline). DR-024: a private ls-remote REQUIRES auth → fail-loud on a
    # present-but-malformed credential (git_env_result) instead of running unauthenticated (a 403/404 masks it).
    with {:ok, auth_env} <- Fleet.Credentials.ForgeAuth.git_env_result() do
      case Fleet.Credentials.Shell.git(["ls-remote", repo_url, branch],
             timeout_ms: 15_000,
             env: auth_env
           ) do
        {:ok, {out, 0}} ->
          case out |> String.split("\n", trim: true) |> List.first() do
            nil -> {:error, :no_ref}
            line -> {:ok, line |> String.split() |> List.first()}
          end

        {:ok, {out, rc}} ->
          {:error, {rc, String.trim(out)}}

        {:error, {:timeout, _ms}} ->
          {:error, :timeout}

        {:error, {:exit, reason}} ->
          {:error, {:exit, reason}}
      end
    end
  end
end
