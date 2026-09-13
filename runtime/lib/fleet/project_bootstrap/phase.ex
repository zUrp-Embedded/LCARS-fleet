defmodule Fleet.ProjectBootstrap.Phase do
  @moduledoc """
  Workspace provisioning called by Fleet.Spawner.Pod, with filesystem and Git effects.
  Clone handles spawn and resident re-brief; prompt projection and launcher mounts
  belong to their respective stages. Profiles must use CapProfile's normalized string keys.
  """

  alias Fleet.Credentials.Shell

  defmodule Clone do
    @moduledoc """
    Clones a project base and cuts feature/<slug>, or creates the workspace without
    cloning when repo_path is nil. Operations run in the daemon, outside the pod sandbox.

    Optional reference_repo_path enables Git --reference; production dispatch does not
    populate it. Retained accelerator hook, paired with the dormant GIT_MIRROR launcher bind.
    A reference borrows local objects but does not eliminate network access.
    """
    require Logger

    # The pod can write .git/hooks, which clean -fdx leaves intact. Daemon-side checkout
    # must disable those hooks. Share Shell's overrides so added protections reach every
    # call; they are not a complete sandbox for all repository-controlled Git behaviour.
    @hooks_off Fleet.Credentials.Shell.git_safe_config_args()

    @doc """
    Returns {:ok, workspace, feature_branch}, or branch nil when repo_path is nil.
    Clones base_branch with single-branch full history, optionally pins base_sha, then
    cuts feature/<slug> (default slug work). Without a repo, mkdir_p preserves existing contents.

    Rejects non-absolute pod_dir before filesystem effects; confinement under the pod root
    is the caller's responsibility. A residual clone workspace moves to workspace.morgue,
    replacing its previous generation. Rename failure falls back to deletion and logs work loss.

    Unsafe paths and sanitize failures have their own error tuples; handled Git/ref failures
    use clone_failed. Missing base_branch raises, and malformed profiles may also raise.
    git_timeout_ms applies to the initial clone only; later Git calls use Shell defaults.
    """
    @spec clone_or_skip(Path.t(), Fleet.CapProfile.t(), keyword()) ::
            {:ok, Path.t(), String.t() | nil} | {:error, term()}
    def clone_or_skip(pod_dir, %Fleet.CapProfile{} = cap_profile, opts) do
      if confined_pod_dir?(pod_dir),
        do: do_clone_or_skip(pod_dir, cap_profile, opts),
        else: {:error, {:unsafe_pod_dir, pod_dir}}
    end

    # Derive the role from the profile and install outside the working tree. Git runs
    # prepare-commit-msg even with --no-verify; installation errors only warn, so the push
    # gate remains necessary. The pod can modify this hook; it is a cooperative default.
    # Append a blank-separated trailer paragraph unless the last nonblank line already
    # equals it. $(cat) strips trailing newlines; printf restores the paragraph separator.
    # interpret-trailers --if-exists inspects a trailer block, not arbitrary message prose.
    defp install_trailer_hook(ws, %Fleet.CapProfile{metadata: meta}) do
      case Map.get(meta || %{}, "name") do
        role when is_binary(role) and role != "" ->
          write_trailer_hook(ws, Fleet.Credentials.ForgeIdentity.coauthor_trailer(role))

        _ ->
          :ok
      end
    end

    defp write_trailer_hook(ws, trailer) do
      path = Path.join([ws, ".git", "hooks", "prepare-commit-msg"])

      body = """
      #!/bin/sh
      # LCARS — the role trailer is the LAST paragraph of every commit message.
      # `$(cat)` strips trailing newlines, so the printf below always yields EXACTLY one blank
      # line before the trailer — which is what makes it a git TRAILER BLOCK and not prose.
      set -e
      msg="$1"
      last=$(grep -v '^[[:space:]]*$' "$msg" | tail -n 1 || true)
      if [ "$last" = '#{trailer}' ]; then
        exit 0
      fi
      body=$(cat "$msg")
      printf '%s\\n\\n%s\\n' "$body" '#{trailer}' > "$msg"
      """

      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(path, body),
           :ok <- File.chmod(path, 0o755) do
        :ok
      else
        {:error, reason} ->
          Logger.warning(
            "Phase.Clone: trailer hook NOT installed in #{ws} (#{inspect(reason)}) — the push " <>
              "gate still holds, the agent just has to place the line itself"
          )

          :ok
      end
    end

    defp do_clone_or_skip(pod_dir, %Fleet.CapProfile{spec: spec} = cap_profile, opts) do
      project = spec["project"] || %{}

      case project["repo_path"] do
        nil ->
          # The launcher needs an existing bind source even when there is no repository.
          ws = Fleet.Layout.pod_workspace_path(pod_dir)

          case File.mkdir_p(ws) do
            :ok -> {:ok, ws, nil}
            {:error, r} -> {:error, {:clone_failed, r}}
          end

        repo_url ->
          clone_into_workspace(pod_dir, cap_profile, project, repo_url, opts)
      end
    end

    defp clone_into_workspace(pod_dir, cap_profile, project, repo_url, opts) do
      # Layout keeps this producer and Pod's recomputed workspace path aligned without a cycle.
      ws = Fleet.Layout.pod_workspace_path(pod_dir)

      # Deterministic redispatch reuses the directory. Move the predecessor aside so clone
      # can proceed; the caller must ensure exclusive ownership of this pod directory.
      morgue_residual_workspace(ws)

      ref = project["reference_repo_path"]

      # Dispatch chooses the code/workshop base. Defaulting here would hide a missing decision.
      base =
        project["base_branch"] ||
          raise(ArgumentError,
            message:
              "Phase.Clone: project map for #{inspect(project["repo"])} carries no " <>
                "\"base_branch\" — the face is decided at dispatch and threaded, never " <>
                "re-defaulted here (single-default-site doctrine, face-projet)."
          )

      # Use the dispatcher slug, not the pod identifier, in the agent-visible branch name.
      slug = Keyword.get(opts, :slug, "work")
      feature = "feature/#{slug}"
      ref_args = if ref, do: ["--reference", ref], else: []

      git_opts = Keyword.take(opts, [:git_timeout_ms]) |> rename_timeout_key()

      # Shell supplies receive/output limits and default ForgeAuth env. Its teardown is
      # best effort, not an end-to-end bootstrap deadline. Validate refs before Git sees them.
      with true <- Fleet.GitRef.valid?(base) or {:invalid_base_branch, base},
           true <- Fleet.GitRef.valid?(feature) or {:invalid_feature_branch, feature},
           # Avoid unrelated feature branches but retain history for log/blame and base pinning.
           # The documentation mount may be shallow; this code workspace deliberately is not.
           {:ok, {_, 0}} <-
             Shell.git(
               @hooks_off ++
                 ["clone"] ++ ref_args ++ ["--branch", base, "--single-branch", repo_url, ws],
               git_opts
             ),
           # Pin before cutting the feature branch so a moved remote tip does not change its base.
           {:ok, {_, 0}} <- pin_base_sha(ws, project["base_sha"]),
           # Give prompts one comparison ref; a review clone may not contain the PR base yet.
           {:ok, {_, 0}} <- pin_work_base(ws, project),
           # Explicit env skips ForgeAuth defaults; inherited variables remain.
           {:ok, {_, 0}} <-
             Shell.git(@hooks_off ++ ["-C", ws, "checkout", "-b", feature],
               env: []
             ),
           :ok <- install_trailer_hook(ws, cap_profile),
           :ok <- sanitize_workspace(ws) do
        {:ok, ws, feature}
      else
        autre -> clone_refusal(autre)
      end
    end

    defp clone_refusal({:invalid_base_branch, b}),
      do: {:error, {:clone_failed, {:invalid_base_branch, b}}}

    # Ref validators return both bare and wrapped errors. Keep these before the Git catch-all
    # so validation refusals are not mislabeled as command failures.
    defp clone_refusal({:invalid_base_sha, sha}),
      do: {:error, {:clone_failed, {:invalid_base_sha, sha}}}

    defp clone_refusal({:error, {:invalid_pr_base_branch, b}}),
      do: {:error, {:clone_failed, {:invalid_pr_base_branch, b}}}

    defp clone_refusal({:error, {:sanitize_failed, _}} = err), do: err

    defp clone_refusal({:invalid_feature_branch, f}),
      do: {:error, {:clone_failed, {:invalid_feature_branch, f}}}

    defp clone_refusal({:ok, {out, code}}),
      do: {:error, {:clone_failed, {code, String.slice(out, 0, 500)}}}

    defp clone_refusal({:error, {:timeout, ms}}),
      do: {:error, {:clone_failed, {:git_timeout, ms}}}

    defp clone_refusal({:error, {:exit, reason}}),
      do: {:error, {:clone_failed, {:git_exit, reason}}}

    defp clone_refusal({:error, reason}), do: {:error, {:clone_failed, {:git_exit, reason}}}

    @doc """
    Resets a resident workspace in place, preserving its live bind mount. Requires an
    existing repository and nonempty base_sha; reset --hard and clean -fdx discard previous
    work before checkout -B feature/<slug>. No morgue or rollback is provided.

    Returns {:ok, ws, feature}, reset_failed errors, or a separate sanitize_failed error.
    Unlike clone_or_skip, this entry point does not check absolute pod_dir or validate
    feature before checkout; callers must provide safe paths and a valid slug.
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
          # Re-sanitize newly introduced instruction files: they had no skip-worktree bit
          # at clone time. The regression fixture verifies existing bits survive reset/checkout/
          # clean; that does not cover files introduced by a later base. Refuse sanitization errors.
          with {:ok, {_, 0}} <- pin_base_sha(ws, sha),
               # Move the comparison ref too, otherwise it still names the previous ticket's base.
               {:ok, {_, 0}} <- pin_work_base(ws, project),
               {:ok, {_, 0}} <-
                 Shell.git(@hooks_off ++ ["-C", ws, "clean", "-fdx"], env: []),
               {:ok, {_, 0}} <-
                 Shell.git(@hooks_off ++ ["-C", ws, "checkout", "-B", feature],
                   env: []
                 ),
               :ok <- sanitize_workspace(ws) do
            {:ok, ws, feature}
          else
            {:error, {:sanitize_failed, _}} = err ->
              err

            {:invalid_base_sha, s} ->
              {:error, {:reset_failed, {:invalid_base_sha, s}}}

            # This validator returns a wrapped error; preserve its cause before the catch-all.
            {:error, {:invalid_pr_base_branch, b}} ->
              {:error, {:reset_failed, {:invalid_pr_base_branch, b}}}

            {:ok, {out, code}} ->
              {:error, {:reset_failed, {code, String.slice(out, 0, 500)}}}

            {:error, {:timeout, ms}} ->
              {:error, {:reset_failed, {:git_timeout, ms}}}

            {:error, {:exit, reason}} ->
              {:error, {:reset_failed, {:git_exit, reason}}}

            {:error, reason} ->
              {:error, {:reset_failed, {:git_exit, reason}}}
          end

        _ ->
          # Missing base must not silently preserve the previous ticket's state.
          {:error, {:reset_failed, :no_base_sha}}
      end
    end

    # One salvage generation, replaced on redispatch. Rename failure logs then attempts
    # deletion; filesystem cleanup results are ignored, so this is not lossless or transactional.
    defp morgue_residual_workspace(ws) do
      _ =
        if File.exists?(ws) do
          morgue = ws <> ".morgue"
          _ = File.rm_rf(morgue)

          _ =
            case File.rename(ws, morgue) do
              :ok ->
                Logger.error(
                  "Phase.Clone: residual workspace of a DEAD predecessor moved to #{morgue} — " <>
                    "salvage any uncommitted work there; replaced at the next respawn"
                )

              {:error, reason} ->
                Logger.error(
                  "Phase.Clone: residual workspace #{ws} could NOT be morgued (#{inspect(reason)}) " <>
                    "— falling back to rm_rf (clean slate over wedge; uncommitted work lost)"
                )

                _ = File.rm_rf(ws)
            end
        end

      :ok
    end

    @doc """
    Removes discovered .claude directories and non-root CLAUDE.md paths, excluding .git
    subtrees. Marks tracked victims skip-worktree first to avoid staging these deletions
    with ordinary git add. The push gate separately checks forbidden paths.

    Called after clone and resident reset; the no-repository path skips it. Logs removed
    paths per call so operators can diagnose missing repository instructions. This scan
    is not atomic with pod writes and does not prevent later recreation of those paths.
    """
    @spec sanitize_workspace(Path.t()) :: :ok | {:error, {:sanitize_failed, term()}}
    def sanitize_workspace(ws) do
      victims = claude_dirs(ws) ++ nested_claude_mds(ws)

      # Never flag root CLAUDE.md: skip-worktree would hide legitimate edits from diff/status
      # and staging. Scaffold preserves a tracked root file; its untracked projection is excluded.
      with :ok <- skip_worktree_tracked(ws, victims),
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

    # Include hidden directories in discovery; leave Git internals alone.
    defp claude_dirs(ws) do
      ws
      |> Path.join("**/.claude")
      |> Path.wildcard(match_dot: true)
      |> Enum.reject(&under_git_dir?(&1, ws))
      |> Enum.filter(&File.dir?/1)
    end

    defp nested_claude_mds(ws) do
      ws
      |> Path.join("**/CLAUDE.md")
      |> Path.wildcard(match_dot: true)
      |> Enum.reject(&(&1 == Path.join(ws, "CLAUDE.md") or under_git_dir?(&1, ws)))
    end

    defp under_git_dir?(path, ws), do: ".git" in Path.split(Path.relative_to(path, ws))

    # Batch index reads and updates rather than spawning Git per victim.
    defp skip_worktree_tracked(ws, paths) do
      case Shell.git(@hooks_off ++ ["-C", ws, "ls-files", "-z"], env: []) do
        {:ok, {out, 0}} ->
          rels = Enum.map(paths, &Path.relative_to(&1, ws))

          out
          |> String.split(<<0>>, trim: true)
          |> Enum.filter(&covered_by?(&1, rels))
          |> then(&flag_skip_worktree(ws, &1))

        {:ok, {out, code}} ->
          {:error, {:sanitize_failed, {:ls_files, code, String.slice(out, 0, 300)}}}

        {:error, reason} ->
          {:error, {:sanitize_failed, {:ls_files, reason}}}
      end
    end

    # skip-worktree is per file: include tracked descendants of directory victims.
    defp covered_by?(tracked, rels),
      do: Enum.any?(rels, fn r -> tracked == r or String.starts_with?(tracked, r <> "/") end)

    defp flag_skip_worktree(_ws, []), do: :ok

    defp flag_skip_worktree(ws, targets) do
      case Shell.git(
             @hooks_off ++ ["-C", ws, "update-index", "--skip-worktree", "--"] ++ targets,
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
    Reads root CLAUDE.md from HEAD, ignoring working-tree edits or projections.
    :absent conflates a missing tracked file with any returned Git failure; callers then
    omit repository sections. Exceptions from Shell are not caught here.
    """
    @spec read_original_claude_md(Path.t()) :: {:ok, String.t()} | :absent
    def read_original_claude_md(ws) do
      case Shell.git(@hooks_off ++ ["-C", ws, "show", "HEAD:CLAUDE.md"],
             env: []
           ) do
        {:ok, {content, 0}} -> {:ok, content}
        _ -> :absent
      end
    end

    # Forward only the initial clone timeout; callers cannot override its auth env or cwd here.
    defp rename_timeout_key([]), do: []
    defp rename_timeout_key(git_timeout_ms: ms), do: [timeout_ms: ms]

    # Missing clone pin is allowed; resident reset requires a nonempty pin before calling this.
    defp pin_base_sha(_ws, sha) when sha in [nil, ""], do: {:ok, {"", 0}}

    # Reject option-like revisions before authenticated fetch. This field accepts symbolic
    # refs as well as hashes, so use GitRef rather than a hex-only validator.
    defp pin_base_sha(ws, sha) when is_binary(sha) do
      if Fleet.GitRef.valid?(sha), do: do_pin_base_sha(ws, sha), else: {:invalid_base_sha, sha}
    end

    defp do_pin_base_sha(ws, sha) do
      case Shell.git(@hooks_off ++ ["-C", ws, "reset", "--hard", sha, "--"],
             env: []
           ) do
        {:ok, {_, 0}} = ok ->
          ok

        _ ->
          # Any returned reset failure triggers a targeted fetch, not only a missing object.
          case Shell.git(@hooks_off ++ ["-C", ws, "fetch", "origin", "--", sha]) do
            {:ok, {_, 0}} ->
              Shell.git(@hooks_off ++ ["-C", ws, "reset", "--hard", sha, "--"],
                env: []
              )

            other ->
              other
          end
      end
    end

    @doc """
    Fetches pr_base_branch into refs/lcars/base without resetting or cleaning the live
    workspace. Conflict rework needs a fresh comparison base even when the producer keeps
    its existing work and conversation; otherwise it can merge a stale ref and redeliver
    the same conflict. Requires a nonempty pr_base_branch and propagates fetch/ref errors.
    """
    @spec refresh_work_base(Path.t(), map()) :: {:ok, term()} | {:error, term()}
    def refresh_work_base(ws, project) do
      case project["pr_base_branch"] do
        base when is_binary(base) and base != "" ->
          case fetch_work_base(ws, base) do
            {:ok, {_, 0}} -> {:ok, :refreshed}
            {:ok, {out, rc}} -> {:error, {:refresh_fetch_failed, rc, out}}
            {:error, _} = err -> err
          end

        _ ->
          {:error, :no_pr_base_branch}
      end
    end

    # Review/rework clones may lack the PR base; other pods use the just-pinned HEAD.
    # Keep one ref name for prompt commands, and propagate failures before accepting bootstrap.
    defp pin_work_base(ws, project) do
      case project["pr_base_branch"] do
        base when is_binary(base) and base != "" ->
          fetch_work_base(ws, base)

        _ ->
          local_work_base(ws)
      end
    end

    # Write the destination directly rather than depending on a later FETCH_HEAD read.
    defp fetch_work_base(ws, base) do
      if Fleet.GitRef.valid?(base) do
        Shell.git(
          @hooks_off ++
            ["-C", ws, "fetch", "--no-tags", "origin", "+refs/heads/#{base}:refs/lcars/base"]
        )
      else
        {:error, {:invalid_pr_base_branch, base}}
      end
    end

    # HEAD is already pinned, before feature checkout; base_sha may be absent at clone.
    defp local_work_base(ws) do
      Shell.git(
        @hooks_off ++ ["-C", ws, "update-ref", "refs/lcars/base", "HEAD"],
        env: []
      )
    end

    # Clone's local guard prevents CWD-relative mutation. Root confinement and symlink safety
    # remain upstream; this domain cannot depend back on Spawner to derive its pod root.
    defp confined_pod_dir?(pod_dir), do: is_binary(pod_dir) and Path.type(pod_dir) == :absolute

    # Auth is shared through Credentials.Shell. Commit identity is supplied by the launcher
    # (human author/committer, role trailer), not written into .git/config here. These are
    # cooperative defaults that the pod can override; DeliverableGate checks submitted identity.
  end
end
