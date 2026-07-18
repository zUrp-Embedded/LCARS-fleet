defmodule Fleet.Workflow.Git do
  @moduledoc """
  System-side git publication mechanism, post-EXTRACT. Composed by the
  orchestration rail on `pod.completed`, when the step declares `post_extract.git`,
  to turn the pod's work into a commit (then push) on the world side.

  Pure data → action. Two INDEPENDENT primitives (composed by `Fleet.Workflow.Deliverable`,
  which separates CONTENT from PUBLICATION — the deliverable gate runs between the two):
    * `commit/1` — `git add <paths> → git commit` in workspace (no push); input = workspace,
      author/committer identities, message, add_paths; output = `{:ok, commit_sha}`.
    * `push/3` — bounded `git push <remote> <refspec>` (no add/commit).
  (No coupled add+commit+push entry point: Deliverable always goes commit → gate → push —
  the gate must run between the two.)

  Fail-closed on inputs: neither `--force` nor `--no-verify` is ever composed
  from caller data or as a default option. `--no-verify` is never composed at all.
  `--force` is composed by ONE system-owned policy only: a bounded retry when the
  push is rejected for a non-fast-forward on the system-owned feature branch (the
  system is the sole pusher — its own rebase is safe to overwrite). A protected-branch
  or server-hook rejection is NEVER force-retried (fail-closed, no data-loss bypass).

  Distinct identities: `author_*` reflects the worker (role) identity;
  `committer_*` reflects the system identity. Native git
  (`GIT_AUTHOR_*` ≠ `GIT_COMMITTER_*`).

  **Last revised**: 2026-07-18
  """

  require Logger

  @type opts :: %{
          required(:workspace) => Path.t(),
          required(:author_name) => String.t(),
          required(:author_email) => String.t(),
          required(:committer_name) => String.t(),
          required(:committer_email) => String.t(),
          required(:message) => String.t(),
          optional(:add_paths) => [String.t()]
        }

  # `commit/1` does not push → no `:branch`/`:remote`/`:push?` (push concerns live in `push/3`'s
  # positional args). The identity (author/committer) + message + workspace are enough.
  @commit_required_keys [
    :workspace,
    :author_name,
    :author_email,
    :committer_name,
    :committer_email,
    :message
  ]

  # The workspace is CO-WRITTEN by an adversarial pod; `.git/hooks/`, `.git/config` and an in-tree
  # `.gitattributes` are all placeable there by the pod. `git add`/`git commit`/`git push` are run HERE,
  # on the WORLD side (Elixir runtime, OUTSIDE bwrap) → a hook (`pre-commit`/`pre-push`), a `clean` filter,
  # an `sshCommand` or a `diff.external` armed by the pod would execute with the runtime's privileges =
  # arbitrary command execution outside the sandbox. We compose the SINGLE SOURCE of config neutralization
  # (`Fleet.Credentials.Shell.git_safe_config_args/0` : hooks + fsmonitor + sshCommand + diff.external +
  # global attributesFile) on every op that can execute config-driven code: the world REFUSES
  # to run the pod's code rather than hoping it arms none (bad state made impossible).
  # Does NOT affect the `--no-verify NEVER` doctrine (which protects the module's caller; here we neutralize
  # the adversarial mechanism, not the caller's integrity check). Honest LIMIT: an IN-TREE `filter.<name>.clean`
  # (armed by a repo `.gitattributes` + `.git/config`) is NOT disableable via `-c` — it is
  # the upstream-validated CONTENT (`PayloadGuard` refuses payloads that write `.git/**` or a `.gitattributes`
  # arming `filter=`) that closes that vector; here we close the global/system config + hooks vectors.
  @hooks_off Fleet.Credentials.Shell.git_safe_config_args()

  @doc """
  Commit-only — `git add <paths> → git commit` in `workspace`, **without push**. Separates the
  CONTENT (the system commits the payload) from the PUBLICATION (`push/3` after the deliverable
  gate). Used by `Fleet.Workflow.Deliverable` in `payload` mode. No `:branch`/`:remote`
  (push concerns live in `push/3`). Returns the SHA of the committed HEAD.
  """
  @spec commit(opts) :: {:ok, String.t()} | {:error, term()}
  def commit(opts) when is_map(opts) do
    with :ok <- check_required_keys(opts, @commit_required_keys),
         :ok <- check_workspace_string(opts.workspace),
         :ok <- ensure_git_workspace(opts.workspace),
         :ok <- git_add(opts) do
      git_commit(opts)
    end
  end

  # ============================================================
  # Validation
  # ============================================================
  # (Ref validation lives with the callers: `Deliverable` validates its target refs via the
  # foundation authority `Fleet.GitRef`; `push/3` fail-closes leading-`-` remote/refspec itself.)

  defp check_required_keys(opts, keys) do
    case Enum.reject(keys, &Map.has_key?(opts, &1)) do
      [] -> :ok
      missing -> {:error, {:missing_opts, missing}}
    end
  end

  defp check_workspace_string(ws) when is_binary(ws) and ws != "", do: :ok
  defp check_workspace_string(_ws), do: {:error, :invalid_workspace}

  defp ensure_git_workspace(ws) do
    # `.git` = a DIRECTORY in a normal clone, but a FILE (`gitdir: …`) in a git WORKTREE
    # (`git worktree add`). A project's work/ops IS an orphan worktree (cf. ProjectOnboard) → a
    # `File.dir?(".git")` check would wrongly reject it (`:not_a_git_workspace` → brief/provenance
    # never committed). `File.exists?` accepts both; a non-git dir (neither file nor dir `.git`)
    # stays refused.
    case {File.dir?(ws), File.exists?(Path.join(ws, ".git"))} do
      {false, _} -> {:error, :workspace_missing}
      {true, false} -> {:error, :not_a_git_workspace}
      {true, true} -> :ok
    end
  end

  # ============================================================
  # Git ops
  # ============================================================

  defp git_add(opts) do
    paths = Map.get(opts, :add_paths, ["."])

    case validate_add_paths(paths) do
      :ok ->
        # `--` terminates the options → a pathspec starting with `-` (e.g. `add_paths = ["--all"]`
        # from an untrusted input) is treated as a literal PATH, not a git option. `System.cmd`
        # does not use a shell, but GIT parses its own options: a leading-`-` arg is an option.
        # `@hooks_off` (config neutralization) BEFORE `add` : `git add` runs the `clean` filter armed by
        # a pod `.gitattributes`+`.git/config` = arbitrary command execution on the world side. The set
        # neutralizes the global/system config vectors; the in-tree vector (named filter) is closed
        # upstream on the CONTENT side by `Deliverable` (cf. the `@hooks_off` comment).
        # Bounded by Shell.git (setsid + SIGKILL of the OS process-GROUP at the deadline): a stale
        # `index.lock` would make `git add` hang indefinitely without a timeout -> the completer never reaches
        # the unlock, the issue stays wedged `lcars-in-flight` without recovery. Same pattern as `run_push`.
        case Fleet.Credentials.Shell.git(@hooks_off ++ ["add", "--" | paths],
               cd: opts.workspace,
               timeout_ms: git_local_timeout_ms()
             ) do
          {:ok, {_out, 0}} -> :ok
          {:ok, {out, rc}} -> {:error, {:git_add_failed, rc, String.trim(out)}}
          {:error, {:timeout, ms}} -> {:error, {:git_add_timeout, ms}}
          {:error, {:exit, reason}} -> {:error, {:git_add_exit, reason}}
        end

      {:error, _} = err ->
        err
    end
  end

  # `add_paths` must be a non-empty list of non-empty binary paths (belt-and-suspenders
  # with the `--` separator).
  defp validate_add_paths(paths) when is_list(paths) and paths != [] do
    if Enum.all?(paths, &(is_binary(&1) and &1 != "")),
      do: :ok,
      else: {:error, :invalid_add_paths}
  end

  defp validate_add_paths(_), do: {:error, :invalid_add_paths}

  defp git_commit(opts) do
    with :ok <- run_commit(opts) do
      read_head_sha(opts.workspace)
    end
  end

  defp run_commit(opts) do
    # No classification by grepping "nothing to commit" on stderr: that would be
    # i18n-dependent (LC_ALL=fr_FR → "rien à valider" → grep misses → wrong
    # classification). Pre-check via `git diff --cached --quiet` (RC codes stable
    # across locales: 0 = no staged diff, 1 = staged diff). Avoids the commit
    # entirely when `:nothing_to_commit`.
    case has_staged_changes?(opts.workspace) do
      false ->
        {:error, :nothing_to_commit}

      true ->
        # Bounded (same as git_add). Explicit `env` = the commit identity (commit_env) MERGED with
        # `ForgeAuth.git_env/0` (GIT_TERMINAL_PROMPT=0): Shell.git injects its default env ONLY
        # if `:env` is absent -> we compose both (no key overlap: AUTHOR/COMMITTER
        # vs TERMINAL_PROMPT). No regression, + the anti-prompt bound kept consistent.
        case Fleet.Credentials.Shell.git(@hooks_off ++ ["commit", "-m", opts.message],
               cd: opts.workspace,
               timeout_ms: git_local_timeout_ms(),
               env: Fleet.Credentials.ForgeAuth.git_env() ++ commit_env(opts)
             ) do
          {:ok, {_out, 0}} -> :ok
          {:ok, {out, rc}} -> {:error, {:git_commit_failed, rc, String.trim(out)}}
          {:error, {:timeout, ms}} -> {:error, {:git_commit_timeout, ms}}
          {:error, {:exit, reason}} -> {:error, {:git_commit_exit, reason}}
        end
    end
  end

  defp has_staged_changes?(workspace) do
    # Bounded + `@hooks_off` (uniformity: `diff` can invoke a `diff.external` armed by the pod;
    # the set disarms it, zero cost — like add/commit). Timeout/exit/unexpected-code → `true` (lets
    # commit TRY and report the error with context; bound preserved: commit is itself bounded too).
    case Fleet.Credentials.Shell.git(@hooks_off ++ ["diff", "--cached", "--quiet"],
           cd: workspace,
           timeout_ms: git_local_timeout_ms()
         ) do
      # Exit 0 = no staged diff → nothing to commit.
      {:ok, {_, 0}} -> false
      # Exit 1 = staged diff present (stable git semantics).
      {:ok, {_, 1}} -> true
      # Other code / timeout / exit = anomaly → lets commit try and report.
      _ -> true
    end
  end

  defp commit_env(opts) do
    [
      {"GIT_AUTHOR_NAME", opts.author_name},
      {"GIT_AUTHOR_EMAIL", opts.author_email},
      {"GIT_COMMITTER_NAME", opts.committer_name},
      {"GIT_COMMITTER_EMAIL", opts.committer_email}
    ]
  end

  @doc """
  SHA of `workspace`'s HEAD, **bounded** (Shell.git: deadline + SIGKILL of the process-group — a
  `rev-parse` hung on a sick FS never blocks the caller). SINGLE AUTHORITY for the system-side
  rev-parse — an unbounded copy elsewhere would re-open the hung-publication hole.
  """
  @spec read_head_sha(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def read_head_sha(workspace) do
    # Bounded + `@hooks_off` for uniformity (rev-parse launches no filter/external → the `-c` are
    # inert here, but every system-side git site composes the set = auditable invariant).
    case Fleet.Credentials.Shell.git(@hooks_off ++ ["rev-parse", "HEAD"],
           cd: workspace,
           timeout_ms: git_local_timeout_ms()
         ) do
      {:ok, {sha, 0}} -> {:ok, String.trim(sha)}
      {:ok, {err, rc}} -> {:error, {:rev_parse_failed, rc, String.trim(err)}}
      {:error, {:timeout, ms}} -> {:error, {:rev_parse_timeout, ms}}
      {:error, {:exit, reason}} -> {:error, {:rev_parse_exit, reason}}
    end
  end

  @doc """
  Push-only — pushes `refspec` from `workspace` to `remote`, **bounded** (timeout). NO add/commit:
  the branch is already committed (by the pod in `git_native` mode, or by `commit/1` in `payload`
  mode). `refspec` can be `local_ref:target_branch` so that the pushed ref is **chosen by the
  system**. Sole caller: `Fleet.Workflow.Deliverable` (both modes).
  """
  @spec push(Path.t(), String.t(), String.t()) :: {:ok, true} | {:error, term()}
  def push(workspace, remote, refspec) do
    with :ok <- validate_cli_arg(remote, :invalid_remote),
         :ok <- validate_cli_arg(refspec, :invalid_refspec),
         # DR-024: push REQUIRES forge auth → fail-loud on a present-but-malformed credential (never run
         # unauthenticated, which masks the config error as a later 403 or silently succeeds on a public remote).
         {:ok, auth_env} <- Fleet.Credentials.ForgeAuth.git_env_result() do
      do_push(workspace, remote, refspec, auth_env)
    end
  end

  # `remote`/`refspec` must NOT start with `-`. Otherwise `git push` reads them as
  # OPTIONS (`--receive-pack=<cmd>` → execution on the remote side, `-c <config>`, `--exec=`) → option
  # injection via an untrusted input. `System.cmd` does not use a shell, but git parses its options:
  # an expected positional that starts with `-` is swallowed as an option. We reject fail-closed.
  defp validate_cli_arg(arg, err) when is_binary(arg) and arg != "" do
    if String.starts_with?(arg, "-"), do: {:error, {err, arg}}, else: :ok
  end

  defp validate_cli_arg(_arg, err), do: {:error, err}

  defp do_push(workspace, remote, refspec, auth_env) do
    case run_push(workspace, remote, refspec, [], auth_env) do
      {:ok, {_out, 0}} ->
        {:ok, true}

      {:ok, {out, rc}} ->
        # A CONFLICT RESOLUTION rebases the feature-branch → history rewritten → push rejected
        # "non-fast-forward". The feature-branch is SYSTEM-owned (only the system pushes it; the pod
        # is forge-blind, no concurrent pusher) → a `--force` retry is safe: the system overwrites
        # ITS OWN branch with the rebase. Without it, the resolution rebase NEVER lands.
        if non_fast_forward?(out),
          do: force_push(workspace, remote, refspec, auth_env),
          else: {:error, {:git_push_failed, rc, String.trim(out)}}

      {:error, {:timeout, _ms}} ->
        {:error, {:git_push_timeout, push_timeout_ms()}}

      {:error, {:exit, reason}} ->
        {:error, {:git_push_exit, reason}}
    end
  end

  defp force_push(workspace, remote, refspec, auth_env) do
    case run_push(workspace, remote, refspec, ["--force"], auth_env) do
      {:ok, {_out, 0}} -> {:ok, true}
      {:ok, {out, rc}} -> {:error, {:git_push_failed, rc, String.trim(out)}}
      {:error, {:timeout, _ms}} -> {:error, {:git_push_timeout, push_timeout_ms()}}
      {:error, {:exit, reason}} -> {:error, {:git_push_exit, reason}}
    end
  end

  # `git push [extra] remote refspec` bounded via `Fleet.Credentials.Shell` (single source of the bound) —
  # `git push` has no native timeout. A hung network push (DNS, TLS, interrupted packfile) would block the
  # calling GenServer; the wrapper launches in a dedicated process-group and, at the WALL deadline, kills the
  # whole GROUP (the push AND its transport helpers) + closes the port. Replaces the `Task.async` +
  # `shutdown(:brutal_kill)` pattern which killed only the BEAM Task while letting the git process (carrier of
  # the forge token in its environ) leak. `core.hooksPath=/dev/null` kept (hook hardening unchanged).
  defp run_push(workspace, remote, refspec, extra, auth_env) do
    # Forge token via env (out of argv/cmdline) — resolved ONCE at `push/3` via `ForgeAuth.git_env_result/0`
    # (fail-loud on a malformed credential, DR-024) and threaded here explicitly.
    Fleet.Credentials.Shell.git(@hooks_off ++ ["push"] ++ extra ++ [remote, refspec],
      cd: workspace,
      timeout_ms: push_timeout_ms(),
      env: auth_env
    )
  end

  # "non-fast-forward" rejection ONLY (the remote history has diverged from the local one — here a resolution
  # rebase rewrites the SYSTEM-owned feature-branch → `--force` safe). Detected on the git output (merged
  # stderr) by restricting to the DIAGNOSTICS SPECIFIC to non-fast-forward: `non-fast-forward` / `fetch first`.
  # We do NOT match the BARE `rejected` substring: git also emits it for a HOOK rejection (`[remote rejected]
  # … pre-receive hook declined`) or a protected branch — a `--force` retry there would wrongly be a FORCED
  # REWRITE over a server protection (data loss / guard bypass). We force only when the cause IS a history
  # divergence, never on a remote policy refusal (fail-closed: a not-explicitly-NFF rejection propagates as-is
  # `{:git_push_failed, …}`, no blind force).
  defp non_fast_forward?(out) do
    o = String.downcase(out)

    String.contains?(o, "non-fast-forward") or String.contains?(o, "fetch first")
  end

  # Timeout for network `git push`. Default 30s (enough for LAN/local forge,
  # guard against indefinite WAN hang). Override via :fleet_workflow,
  # :git_push_timeout_ms (app config or Application.put_env).
  defp push_timeout_ms do
    Application.get_env(:fleet_workflow, :git_push_timeout_ms, 30_000)
  end

  # Bound for LOCAL git ops (add/commit/diff-cached/rev-parse). Normally <1 s; a timeout here =
  # stale `index.lock` / hung FS (NFS). 30 s leaves a wide margin before killing the OS group.
  defp git_local_timeout_ms do
    Application.get_env(:fleet_workflow, :git_local_timeout_ms, 30_000)
  end

  # No `forge_auth_args/0`. System-side forge auth is carried by
  # `Fleet.Credentials.ForgeAuth.git_env/0` (single source, token via env out of argv/cmdline).
end
