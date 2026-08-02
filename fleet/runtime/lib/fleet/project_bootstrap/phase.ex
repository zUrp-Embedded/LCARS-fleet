# `Fleet.CapProfile` guarantees STRING keys (normalized at `to_struct`) →
# `Phase.Clone` accesses `cap_profile.spec["..."]` directly, without an
# atom|string tolerant accessor nor a defensive double-lookup (the profile
# already carries the canonical form, no need to re-check it here).
defmodule Fleet.ProjectBootstrap.Phase do
  @moduledoc """
  `Phase.Clone` — the only phase WIRED in prod of pod bootstrap. Pure functions
  (no process: File / Path / git). Typed errors (distinct exit codes).
  Wired DIRECTLY by `Fleet.Spawner.Pod` (`maybe_bootstrap_project_workspace` →
  `clone_or_skip`/`clone_work_doc`, and `reset_in_place` on the slot-freeze re-brief).
  Cap-profile access: direct STRING keys (`cap_profile.spec["..."]`) —
  `Fleet.CapProfile` guarantees the form at production.

  Workspace-side invariant (the "positive SP": the agent sees only its work, never
  the machinery): the workspace this builds must show NO trace of LCARS beyond the
  vanilla repo + its plugins.

  Clone is the ONLY bootstrap phase: the other pod-provisioning concerns live
  elsewhere — the pod `CLAUDE.md` is composed by `do_project` (pod.ex side),
  mounts/credentials by `bwrap_launch.sh`.

  **Last revised**: 2026-08-02
  """

  defmodule Clone do
    @moduledoc """
    Phase 2 — CLONE the feature branch OR skip (permanent pod / no repo).
    `git clone --reference <local bare mirror>` (local objects + incremental fetch, no
    per-pod network) if `spec.project.repo_path`, otherwise workspace = empty directory (branch nil).

    ⚠ `--reference` is DORMANT — UNUSED: `project["reference_repo_path"]` (the mirror
    path) is READ below but NEVER SET by any caller → `ref` is always `nil` → clone WITHOUT
    `--reference`, no workspace has `alternates`. A clone-accelerator hook wired but never
    activated (pod-side counterpart = the `$GIT_MIRROR` bind in `bin/bwrap_launch.sh`, also
    dormant). User decision: KEEP, do not purge.
    """
    require Logger

    @spec clone_or_skip(Path.t(), Fleet.CapProfile.t(), keyword()) ::
            {:ok, Path.t(), String.t() | nil} | {:error, term()}
    def clone_or_skip(pod_dir, %Fleet.CapProfile{} = cap_profile, opts) do
      if confined_pod_dir?(pod_dir),
        do: do_clone_or_skip(pod_dir, cap_profile, opts),
        else: {:error, {:unsafe_pod_dir, pod_dir}}
    end

    defp do_clone_or_skip(pod_dir, %Fleet.CapProfile{spec: spec}, opts) do
      project = spec["project"] || %{}

      case project["repo_path"] do
        nil ->
          ws = Fleet.Layout.pod_workspace_path(pod_dir)

          case File.mkdir_p(ws) do
            :ok -> {:ok, ws, nil}
            {:error, r} -> {:error, {:clone_failed, r}}
          end

        repo_url ->
          # This module is the PRODUCER (it creates and returns the workspace); Pod RECOMPUTES it.
          # Both read `Fleet.Layout` — the foundation owns the literal because neither consumer may
          # depend on the other (Spawner already deps ProjectBootstrap; the reverse edge cycles).
          ws = Fleet.Layout.pod_workspace_path(pod_dir)

          # Idempotence of the deterministic re-dispatch: a DEAD predecessor pod (timeout/crash) leaves its
          # workspace on disk; since the pod_id is deterministic (`<repo-slug>-issue-N-role`), the
          # re-dispatch lands on the SAME pod_dir → `git clone` would refuse ("destination already exists
          # and is not an empty directory") → PERMANENT wedge of the issue (a pod that times out otherwise
          # loops forever on clone_failed). The pod OWNS its pod_dir (spawn guard = 1 pod/pod_id) → a residual
          # `ws` can only come from a dead predecessor → clean slate (the `base_sha` is re-pinned
          # just after, a fresh clone is always correct).
          _ = File.rm_rf(ws)

          ref = project["reference_repo_path"]

          # ASSERTED, never defaulted (chantier face-projet): the resolver ALWAYS engraves
          # `base_branch` in the project map — the face decision made once at dispatch. The old
          # `|| "main"` was dead code on the live path and a substituting default on any other:
          # a project map without a base_branch has skipped the face decision, and cloning the
          # code face over it would bury exactly the bug this chantier exists to kill.
          base =
            project["base_branch"] ||
              raise(ArgumentError,
                message:
                  "Phase.Clone: project map for #{inspect(project["repo"])} carries no " <>
                    "\"base_branch\" — the face is decided at dispatch and threaded, never " <>
                    "re-defaulted here (single-default-site doctrine, chantier face-projet)."
              )

          # Clean world: branch = `feature/<slug>` WITHOUT the pod_id (the agent must not re-read its
          # pod_id in its own branch — containment). The slug comes from the dispatcher (sanitized issue
          # title); default `work`. The slug carries no `pod-`/`pod_` prefix (the branch does not
          # leak the pod's identity).
          slug = Keyword.get(opts, :slug, "work")
          feature = "feature/#{slug}"
          ref_args = if ref, do: ["--reference", ref], else: []

          # The NETWORK clone's deadline is calibrable by the caller (`:git_timeout_ms`), default = the
          # wrapper's (30s). The spawner can tighten it; the tests use it to prove the bounding
          # (clone to a URL that hangs → killed within the deadline, no zombie pod).
          git_opts = Keyword.take(opts, [:git_timeout_ms]) |> rename_timeout_key()

          # Clone/checkout BOUNDED by construction via `Fleet.Credentials.Shell.git/2` (runs under
          # `setsid`; an absolute wall deadline kills the whole process-group `kill -KILL -<pgid>`;
          # `GIT_TERMINAL_PROMPT=0` set by `git_env/0`). An unbounded `git`
          # would freeze the `Fleet.Spawner.Pod` (GenServer) if the network clone hung — or if the git
          # prompts for lack of a credential, with no TTY → zombie pod / wedged issue. The wrapper kills the
          # child git if the deadline expires and returns a typed error → the pod does not stay frozen. `Shell.git/2`
          # injects `git_env/0` (anti-prompt + forge auth).
          # base_branch (catalogue/brief) + feature (built from the dispatcher slug) VALIDATED as git refs
          # BEFORE they reach `git clone --branch`/`checkout` (R1-07/08): a malformed ref → a CLEAR typed
          # error, not a cryptic git failure. `Fleet.GitRef` = the foundation check-ref-format authority.
          with true <- Fleet.GitRef.valid?(base) or {:invalid_base_branch, base},
               true <- Fleet.GitRef.valid?(feature) or {:invalid_feature_branch, feature},
               {:ok, {_, 0}} <-
                 Fleet.Credentials.Shell.git(
                   ["clone"] ++ ref_args ++ ["--branch", base, repo_url, ws],
                   git_opts
                 ),
               # If the forge-driven rail PINNED a base_sha (out-of-pod ls-remote), we pin HEAD onto it
               # BEFORE the feature-branch. Eliminates the window "the pod clones a base the rail did not
               # capture" (same-role race): `base..HEAD` will contain ONLY the pod's commits.
               # Axiom set AT the clone boundary (not verified "observable post-hoc").
               {:ok, {_, 0}} <- pin_base_sha(ws, project["base_sha"]),
               # `checkout -b` is local (no network, does not prompt) but ALSO goes through the bounded
               # wrapper: invariant = no bare `System.cmd git` on this path (no unbounded git
               # possible). Bare env (no auth/network).
               {:ok, {_, 0}} <-
                 Fleet.Credentials.Shell.git(["-C", ws, "checkout", "-b", feature], env: []),
               :ok <- sanitize_workspace(ws) do
            {:ok, ws, feature}
          else
            {:invalid_base_branch, b} ->
              {:error, {:clone_failed, {:invalid_base_branch, b}}}

            {:error, {:sanitize_failed, _}} = err ->
              err

            {:invalid_feature_branch, f} ->
              {:error, {:clone_failed, {:invalid_feature_branch, f}}}

            {:ok, {out, code}} ->
              {:error, {:clone_failed, {code, String.slice(out, 0, 500)}}}

            {:error, {:timeout, ms}} ->
              {:error, {:clone_failed, {:git_timeout, ms}}}

            {:error, {:exit, reason}} ->
              {:error, {:clone_failed, {:git_exit, reason}}}

            {:error, reason} ->
              {:error, {:clone_failed, {:git_exit, reason}}}
          end
      end
    end

    @doc """
    IN-PLACE reset of a RESIDENT pod's workspace (slot-freeze pipe) — NO rm_rf. The `ws` is
    bind-mounted into the pipe's LIVE bwrap sandbox: deleting the dir would break the mount (the agent
    ends up in a deleted cwd) + would fail. We clean the PREVIOUS issue's git state IN PLACE:
    reset --hard onto the NEW issue's `base_sha` (`pin_base_sha` reused, handles the fetch if the base
    has advanced) + `clean -fdx` (drops the untracked, e.g. an uncommitted file) + `checkout -B feature/<slug>`
    (recreates the CLEAN work branch from the base — `-B` forces since the branch already exists). The `ws`
    MUST exist (cloned at spawn, never rm_rf in pipe); `base_sha` is REQUIRED (the dispatcher pins it
    at re-brief). Return homogeneous with clone_or_skip: `{:ok, ws, feature}` | `{:error, {:reset_failed, _}}`.
    """
    @spec reset_in_place(Path.t(), Fleet.CapProfile.t(), keyword()) ::
            {:ok, Path.t(), String.t()} | {:error, term()}
    def reset_in_place(pod_dir, %Fleet.CapProfile{spec: spec}, opts \\ []) do
      project = spec["project"] || %{}
      ws = Fleet.Layout.pod_workspace_path(pod_dir)
      slug = Keyword.get(opts, :slug, "work")
      feature = "feature/#{slug}"

      case project["base_sha"] do
        sha when is_binary(sha) and sha != "" ->
          # pin_base_sha REUSED (reset --hard sha + targeted fetch as fallback if the base has advanced).
          # clean + checkout bounded via Shell.git (no bare `System.cmd git`; bare env, local).
          # `sanitize_workspace` LAST and NON-optional (BL-6-16): `reset --hard` rebuilds the
          # index from the tree-object — the CE_SKIP_WORKTREE bits are ERASED and every tracked
          # victim (.claude/, nested CLAUDE.md) is RESTORED; `clean -fdx` only clears the
          # UNtracked. Without this call a pipe pod gets the hostile material back on its 2nd
          # ticket. FAIL-HARD on sanitize failure: the re-brief is refused — never a pod on
          # hostile material; the wedge is visible (reprovision FAILED log), the poison is not.
          with {:ok, {_, 0}} <- pin_base_sha(ws, sha),
               {:ok, {_, 0}} <- Fleet.Credentials.Shell.git(["-C", ws, "clean", "-fdx"], env: []),
               {:ok, {_, 0}} <-
                 Fleet.Credentials.Shell.git(["-C", ws, "checkout", "-B", feature], env: []),
               :ok <- sanitize_workspace(ws) do
            {:ok, ws, feature}
          else
            {:error, {:sanitize_failed, _}} = err -> err
            {:ok, {out, code}} -> {:error, {:reset_failed, {code, String.slice(out, 0, 500)}}}
            {:error, {:timeout, ms}} -> {:error, {:reset_failed, {:git_timeout, ms}}}
            {:error, {:exit, reason}} -> {:error, {:reset_failed, {:git_exit, reason}}}
            # TOTAL over the Shell error union (output_overflow, bad_opt, future members).
            {:error, reason} -> {:error, {:reset_failed, {:git_exit, reason}}}
          end

        _ ->
          # base_sha absent = caller bug (the dispatcher MUST pin it at re-brief) → fail-loud
          # rather than a reset onto an undefined base (which would keep the previous issue's state).
          {:error, {:reset_failed, :no_base_sha}}
      end
    end

    @doc """
    BL-6-16 wall, layer 1 — neutralizes the vendor CLI's PROJECT-TIER instruction surface in
    a workspace: `.claude/` directories and NON-root `CLAUDE.md` files come from the TARGET
    repo (the parking-lot USB) and would be read as DIRECTIVES by the CLI (cwd = workspace;
    the root `CLAUDE.md` is covered separately — the composed one overwrites it, Scaffold).

    Tracked victims (and a tracked root `CLAUDE.md`, which the overwrite would dirty) are
    flagged `git update-index --skip-worktree` BEFORE removal, so the pod's `git add .` never
    stages our deletions nor our composed file into its deliverable — the gate's
    forbidden-path check is the independent second line. Called by BOTH workspace producers
    (`clone_or_skip` at spawn, `reset_in_place` at every slot-freeze re-brief — `reset --hard`
    erases the skip-worktree bits and restores tracked victims). Neutralized paths are logged
    ONCE, warning: the operator of a legitimate repo must see that its `.claude/` does not
    follow. The empty-workspace path (no repo) has nothing to sanitize and never calls this.
    """
    @spec sanitize_workspace(Path.t()) :: :ok | {:error, {:sanitize_failed, term()}}
    def sanitize_workspace(ws) do
      victims = claude_dirs(ws) ++ nested_claude_mds(ws)

      with :ok <- skip_worktree_tracked(ws, victims ++ [Path.join(ws, "CLAUDE.md")]),
           :ok <- remove_all(victims) do
        if victims != [] do
          rels = Enum.map(victims, &Path.relative_to(&1, ws))

          Logger.warning(
            "Phase.Clone: workspace instruction-tier material neutralized (BL-6-16): " <>
              "#{inspect(rels)} — the target repo's .claude/ and nested CLAUDE.md never " <>
              "reach the agent's directive tier"
          )
        end

        :ok
      end
    end

    # Every `.claude` DIRECTORY in the tree (root included), `.git` excluded. `match_dot:
    # true` — a wildcard does not see dotfiles by default, which is the whole point here.
    defp claude_dirs(ws) do
      ws
      |> Path.join("**/.claude")
      |> Path.wildcard(match_dot: true)
      |> Enum.reject(&under_git_dir?(&1, ws))
      |> Enum.filter(&File.dir?/1)
    end

    # Every CLAUDE.md EXCEPT the workspace root's (overwritten by the composed one).
    defp nested_claude_mds(ws) do
      ws
      |> Path.join("**/CLAUDE.md")
      |> Path.wildcard(match_dot: true)
      |> Enum.reject(&(&1 == Path.join(ws, "CLAUDE.md") or under_git_dir?(&1, ws)))
    end

    defp under_git_dir?(path, ws), do: ".git" in Path.split(Path.relative_to(path, ws))

    # ONE `ls-files` for the tracked set, ONE `update-index --skip-worktree` for all victims
    # (bounded twice total, never per-path). A directory victim contributes every tracked file
    # under its prefix (skip-worktree is a per-FILE index bit).
    defp skip_worktree_tracked(ws, paths) do
      case Fleet.Credentials.Shell.git(["-C", ws, "ls-files", "-z"], env: []) do
        {:ok, {out, 0}} ->
          tracked = out |> String.split(<<0>>, trim: true) |> MapSet.new()

          rels = Enum.map(paths, &Path.relative_to(&1, ws))

          targets =
            Enum.filter(tracked, fn t ->
              Enum.any?(rels, fn r -> t == r or String.starts_with?(t, r <> "/") end)
            end)

          flag_skip_worktree(ws, targets)

        {:ok, {out, code}} ->
          {:error, {:sanitize_failed, {:ls_files, code, String.slice(out, 0, 300)}}}

        {:error, reason} ->
          {:error, {:sanitize_failed, {:ls_files, reason}}}
      end
    end

    defp flag_skip_worktree(_ws, []), do: :ok

    defp flag_skip_worktree(ws, targets) do
      case Fleet.Credentials.Shell.git(
             ["-C", ws, "update-index", "--skip-worktree", "--"] ++ targets,
             env: []
           ) do
        {:ok, {_, 0}} ->
          :ok

        {:ok, {out, code}} ->
          {:error, {:sanitize_failed, {:skip_worktree, code, String.slice(out, 0, 300)}}}

        {:error, reason} ->
          {:error, {:sanitize_failed, {:skip_worktree, reason}}}
      end
    end

    defp remove_all(paths) do
      Enum.reduce_while(paths, :ok, fn path, :ok ->
        case File.rm_rf(path) do
          {:ok, _} -> {:cont, :ok}
          {:error, reason, at} -> {:halt, {:error, {:sanitize_failed, {:rm, at, reason}}}}
        end
      end)
    end

    @doc """
    The target repo's ORIGINAL root `CLAUDE.md`, read from GIT (`git show HEAD:CLAUDE.md`) —
    never from the working tree, which carries OUR composed file from the first spawn on.
    `:absent` covers both "not tracked at HEAD" (the nominal case — the project template ships
    none) and any git failure: no original, no repo-section rail, the composed doc renders its
    repo zone empty exactly as before (BL-6-16 — the rail's revival point, cf. Scaffold).
    """
    @spec read_original_claude_md(Path.t()) :: {:ok, String.t()} | :absent
    def read_original_claude_md(ws) do
      case Fleet.Credentials.Shell.git(["-C", ws, "show", "HEAD:CLAUDE.md"], env: []) do
        {:ok, {content, 0}} -> {:ok, content}
        _ -> :absent
      end
    end

    # Translates the PUBLIC opt `:git_timeout_ms` (bootstrap vocabulary) into `:timeout_ms` (`Shell.git/2`
    # vocabulary). Absent → `[]` (the wrapper applies its 30s default). Keeps the wrapper's boundary
    # honest (a caller cannot, by mistake, pass arbitrary `:env`/`:cd` to the network clone).
    defp rename_timeout_key([]), do: []
    defp rename_timeout_key(git_timeout_ms: ms), do: [timeout_ms: ms]

    # Pins the workspace's HEAD onto `sha` (captured out-of-pod by the forge-driven rail). The `--branch base`
    # clone already contains `sha` in the nominal case (sha = tip) and fast-forward (sha = ancestor) → a local
    # `reset --hard` suffices. Pathological case (a remote force-push erased `sha`) → targeted `fetch` then
    # reset. The `fetch` is NETWORK (can hang/prompt) → BOUNDED via `Shell.git/2` (the local `reset`
    # is too, to leave no bare `System.cmd git`). Return homogeneous with `Shell.git/2`
    # (`{:ok, {out, code}}` | `{:error, {:timeout|:exit, _}}`), consumed by the `with` of
    # `clone_or_skip`. nil/"" = no-op success.
    defp pin_base_sha(_ws, sha) when sha in [nil, ""], do: {:ok, {"", 0}}

    defp pin_base_sha(ws, sha) when is_binary(sha) do
      case Fleet.Credentials.Shell.git(["-C", ws, "reset", "--hard", sha], env: []) do
        {:ok, {_, 0}} = ok ->
          ok

        _ ->
          # The local `reset` failed (`sha` absent locally) → targeted NETWORK fetch (forge auth + anti-prompt
          # bound via `git_env/0`), then local re-reset. Fetch failure (incl. timeout/exit) →
          # propagated as-is to the `with` → `{:clone_failed, ...}`.
          case Fleet.Credentials.Shell.git(["-C", ws, "fetch", "origin", sha]) do
            {:ok, {_, 0}} ->
              Fleet.Credentials.Shell.git(["-C", ws, "reset", "--hard", sha], env: [])

            other ->
              other
          end
      end
    end

    @doc """
    Doc-mount — clones the project's DOC branch (`spec.project.work_branch`, orphan `work/ops` by
    LCARS convention) into `<pod_dir>/work`: the doc the agent relies on to code (plans,
    backlog, conventions). Alongside the code branch (`workspace`).

    - `work_branch` nil/absent OR no `repo_path` → `{:ok, nil}` (skip: project with no doc branch).
    - declared but clone failed → `{:error, ...}` FAIL-LOUD: a cap-profile that declares a
      nonexistent doc branch = config bug, not a pod silently amputated of its doc.
    """
    @spec clone_work_doc(Path.t(), Fleet.CapProfile.t()) ::
            {:ok, Path.t() | nil} | {:error, term()}
    def clone_work_doc(pod_dir, %Fleet.CapProfile{} = cap_profile) do
      if confined_pod_dir?(pod_dir),
        do: do_clone_work_doc(pod_dir, cap_profile),
        else: {:error, {:unsafe_pod_dir, pod_dir}}
    end

    defp do_clone_work_doc(pod_dir, %Fleet.CapProfile{spec: spec}) do
      project = spec["project"] || %{}
      work_branch = project["work_branch"]
      repo_url = project["repo_path"]

      cond do
        is_nil(work_branch) or is_nil(repo_url) ->
          {:ok, nil}

        # The branch is GATED before it reaches the argv (Fleet.GitRef): the cap-profile is
        # operator canon (schema-typed as a bare string), but a ref beginning with `-` would read
        # as a git OPTION on the clone below — refuse it typed instead of handing it to git.
        not Fleet.GitRef.valid?(work_branch) ->
          {:error, {:work_doc_clone_failed, {:invalid_work_branch, inspect(work_branch)}}}

        true ->
          do_clone_work_doc_valid(pod_dir, project, work_branch, repo_url)
      end
    end

    defp do_clone_work_doc_valid(pod_dir, project, work_branch, repo_url) do
      doc = Path.join(pod_dir, "work")
      ref = project["reference_repo_path"]
      ref_args = if ref, do: ["--reference", ref], else: []

      # PARITY with `clone_or_skip` (same `rm_rf` of the residue): a DEAD predecessor pod leaves its
      # `work/` on disk; the pod_id being deterministic, the re-dispatch lands on the same
      # `pod_dir` → `git clone` would refuse ("destination already exists and is not an empty
      # directory") → same permanent wedge as the workspace. Clean slate: the residual `work/` can
      # only come from a dead predecessor (the pod owns its pod_dir) → a fresh re-clone is
      # always correct.
      _ = File.rm_rf(doc)

      # --single-branch: the doc branch is orphan ⇒ no need to fetch the rest of the history.
      # NETWORK clone BOUNDED via `Shell.git/2` (anti-prompt + forge auth via `git_env/0`, killed within
      # the deadline if hung → no pod frozen on the doc clone).
      case Fleet.Credentials.Shell.git(
             ["clone"] ++
               ref_args ++ ["--branch", work_branch, "--single-branch", repo_url, doc]
           ) do
        {:ok, {_, 0}} ->
          {:ok, doc}

        {:ok, {out, code}} ->
          {:error, {:work_doc_clone_failed, {work_branch, code, String.slice(out, 0, 500)}}}

        {:error, {:timeout, ms}} ->
          {:error, {:work_doc_clone_failed, {work_branch, :git_timeout, ms}}}

        {:error, {:exit, reason}} ->
          {:error, {:work_doc_clone_failed, {work_branch, :git_exit, reason}}}

        {:error, reason} ->
          {:error, {:work_doc_clone_failed, {work_branch, :git_exit, reason}}}
      end
    end

    # pod_dir CONFINEMENT lives UPSTREAM: the spawner builds pod_dir as `<pod_dir_root>/pod_<pod_id>`
    # from a pod_id validated by `Fleet.Spawner.valid_pod_id?` (no `..`, no `/`). This module
    # CANNOT re-derive that root without a `fleet_spawner` dep (compile cycle), so it cannot check
    # "under root" here. What it CAN and MUST assert before any `rm_rf`/`mkdir` is that pod_dir is
    # ABSOLUTE: a relative pod_dir would make the fixed subdirs `<pod_dir>/workspace|work` resolve
    # against the runtime's CWD → `rm_rf`/`mkdir` on `<cwd>/workspace` (the one footgun visible without
    # the root). Non-absolute → refuse fail-loud (`{:error, {:unsafe_pod_dir, _}}`), never touch the FS.
    defp confined_pod_dir?(pod_dir), do: is_binary(pod_dir) and Path.type(pod_dir) == :absolute

    # No local `forge_auth_args/0` helper (nor a dup of `Fleet.Workflow.Git`, despite the
    # workflow⇄bootstrap compile cycle): forge auth has a single source `Fleet.Credentials.ForgeAuth.git_env/0`
    # (fleet_credentials is below both apps → no cycle), token via env outside argv.

    # No `set_git_identity/2`: setting the pod's commit identity via `git config` in the workspace's
    # `.git/config` would be MUTABLE — the pod could overwrite it (`git config user.email …`) → forgeable
    # identity. The identity is set in env at launch (bwrap_launch.sh: GIT_AUTHOR_*/GIT_COMMITTER_*
    # = the HUMAN of the brief, the role riding the `Co-authored-by:` trailer, cf. `ForgeIdentity`; +
    # GIT_CONFIG_GLOBAL=/dev/null), a deterministic cooperative default the pod cannot override. The guarantee lives on the world side:
    # `Fleet.Workflow.DeliverableGate.check_identity/3` rejects at push any commit outside the
    # authorized identity (the pod CANNOT push a spoofed deliverable).
  end
end
