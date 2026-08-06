defmodule Fleet.Pilot.StepDispatcher.ProjectResolver do
  @moduledoc """
  Project resolution: pinning the git base (`base_sha` / `gate_base_sha`) via `git ls-remote`,
  OUT-OF-POD. ISOLATED I/O cluster of `Fleet.Pilot.StepDispatcher`.

  **Quasi-pure** boundary: this module touches NO seam module (no forge_client / spawner /
  task_queue / loader); it reads `opts` / `forge_opts` and calls `Fleet.Credentials.Shell` /
  `Fleet.Credentials.ForgeAuth` (runtime auth, never the pod — the pod is forge-blind).

  `default_project_resolver/2` is the PUBLIC API: it is the default of `StepDispatcher`'s
  `:project_resolver` seam (delegated from the root module via `defdelegate`) AND the fn called directly by
  the tests. The rest (gate-base resolution, base_url, ls-remote) is internal to this cluster.

  **Last revised**: 2026-08-03
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

    # REQUIRED, never defaulted (chantier face-projet, inventory §D): the face decision is made
    # ONCE at the dispatch entry (issue flow: the card step's `face`; review flow: the PR head).
    # This used to be `Keyword.get(opts, :base_branch, "main")` — a substituting default that
    # looked like a seam: when the value did not arrive, the resolver silently pinned the CODE
    # face instead of stopping, and five downstream twins did the same in two spellings. A caller
    # without a base_branch has skipped the face decision; that is its bug to surface, not ours
    # to paper over.
    base_branch =
      Keyword.get(opts, :base_branch) ||
        raise(
          ArgumentError,
          "default_project_resolver: :base_branch missing for #{inspect(repo)} — the FACE " <>
            "decision is made once at the dispatch entry and threaded, never re-defaulted here " <>
            "(single-default-site doctrine, chantier face-projet)."
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
  defp resolve_gate_base_sha(_repo_url, nil, clone_base_sha, _base_branch),
    do: {:ok, clone_base_sha}

  # THE TWO REFS COINCIDE ON THE FORWARD PATH, and the moduledoc says so — build/rework take
  # `gate_base_branch == base_branch`. We still paid a SECOND `ls-remote` (network, bounded at 15 s,
  # INSIDE the poller's GenServer) for a value already in hand. Over D dispatches that was a ceiling
  # of 2 x 15 s x D where 1 x 15 s x D suffices (BL-6-40, amplifier 3).
  #
  # And it is not merely an economy: two `ls-remote` on THE SAME ref at two instants can return two
  # different shas if somebody pushes in between. The pod would then clone one base and be judged
  # against ANOTHER, without either being wrong. Reusing the read already done is therefore more
  # CONSISTENT, not just faster.
  defp resolve_gate_base_sha(_repo_url, branch, clone_base_sha, base_branch)
       when is_binary(branch) and branch == base_branch,
       do: {:ok, clone_base_sha}

  # Divergentes (resolution par rebase) : la seconde lecture est la SEULE facon de connaitre la
  # tete de l'autre ref. Elle reste.
  defp resolve_gate_base_sha(repo_url, branch, _clone_base_sha, _base_branch)
       when is_binary(branch),
       do: ls_remote_sha(repo_url, branch)

  defp forge_base_url(forge_opts) do
    Keyword.get(forge_opts, :base_url) ||
      get_in(Application.get_env(:fleet_pilot, :forge, []), [:base_url])
  end

  # Bounded, authenticated runtime-side remote read.
  defp ls_remote_sha(repo_url, branch) do
    # DR-024: credentials fail before remote read; GitRef rejects option-like branch input.
    with :ok <- validate_branch(branch),
         {:ok, auth_env} <- Fleet.Credentials.ForgeAuth.git_env_result() do
      case Fleet.Credentials.Shell.git(["ls-remote", repo_url, branch],
             timeout_ms: 15_000,
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

  # Require full SHA before using remote output as a base pin.
  @doc false
  @spec parse_ls_remote_out(String.t()) :: {:ok, String.t()} | {:error, term()}
  def parse_ls_remote_out(out) do
    case out |> String.split("\n", trim: true) |> List.first() do
      nil ->
        {:error, :no_ref}

      line ->
        case line |> String.split() |> List.first() do
          sha when is_binary(sha) ->
            if Regex.match?(~r/\A[0-9a-f]{40}\z/, sha),
              do: {:ok, sha},
              else: {:error, {:malformed_ls_remote, String.slice(line, 0, 80)}}

          nil ->
            {:error, {:malformed_ls_remote, String.slice(line, 0, 80)}}
        end
    end
  end
end
