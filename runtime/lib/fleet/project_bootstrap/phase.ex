# `Fleet.CapProfile` guarantees STRING keys (normalized at `to_struct`) →
# `Phase.Clone` accesses `cap_profile.spec["..."]` directly, without an
# atom|string tolerant accessor nor a defensive double-lookup (the profile
# already carries the canonical form, no need to re-check it here).
defmodule Fleet.ProjectBootstrap.Phase do
  @moduledoc """
  `Phase.Clone` — the only phase WIRED in prod of pod bootstrap. Pure functions
  (no process: File / Path / git). Typed errors (distinct exit codes).
  Wired DIRECTLY by `Fleet.Spawner.Pod` (`maybe_bootstrap_project_workspace` →
  `clone_or_skip`, and `reset_in_place` on the slot-freeze re-brief).
  Cap-profile access: direct STRING keys (`cap_profile.spec["..."]`) —
  `Fleet.CapProfile` guarantees the form at production.

  Workspace-side invariant (the "positive SP": the agent sees only its work, never
  the machinery): the workspace this builds must show NO trace of LCARS beyond the
  vanilla repo + its plugins.

  Clone is the ONLY bootstrap phase: the other pod-provisioning concerns live
  elsewhere — the pod `CLAUDE.md` is composed in the pod's `:projecting` state (pod.ex side),
  mounts/credentials by `bwrap_launch.sh`.
  """

  alias Fleet.Credentials.Shell

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

    # EVERY git op below runs SYSTEM-SIDE — in the daemon, under the human's UID, OUTSIDE bwrap —
    # on a workspace the pod co-writes. Without this prefix, a `post-checkout` the pod dropped in
    # `<ws>/.git/hooks/` executes THERE at the next re-brief: not a pod escaping its sandbox, but
    # the daemon running the pod's code for it, with reach over `~/.claude/.credentials.json`, the
    # role tokens and the whole catalogue. `git clean -fdx` does not remove `.git/`, so the hook
    # outlives the step that precedes the checkout.
    #
    # Composed, never recopied: `Fleet.Credentials.Shell` holds the single definition of what
    # "system-side git neutralized" means (hooks, fsmonitor, sshCommand, diff.external, global
    # attributesFile) and says why for each flag. A site that rebuilds the list by hand is a site
    # that will miss the next flag added to it.
    @hooks_off Fleet.Credentials.Shell.git_safe_config_args()

    @doc """
    Provides the pod's workspace and returns `{:ok, workspace, branch}` — `branch` is `nil` when
    there was nothing to clone.

    TWO OUTCOMES, ONE SHAPE. With a `spec.project.repo_path`, the project's `base_branch` is cloned
    (single-branch, full history) and `feature/<slug>` is CUT from it — that new branch is what the
    third element names, never the base. Without a repo (permanent pod), the workspace is an empty
    directory and the branch is `nil`. The caller reads the same tuple either way and never has to
    know which world it is in.

    THE GUARD IS THE FIRST THING, and it refuses rather than sanitizes: a `pod_dir` that is not an
    absolute path yields `{:error, {:unsafe_pod_dir, pod_dir}}` before any git runs. Everything
    below this line executes SYSTEM-SIDE — in the daemon, under the human's UID, outside bwrap — so
    a relative path resolved against the daemon's cwd would put a pod's workspace anywhere.

    Re-dispatchable onto a workspace a dead predecessor left behind: the pod_id is deterministic, so
    the re-dispatch lands on the same directory. The residual is MOVED to `<workspace>.morgue` (one
    generation kept) and the clone is redone from scratch — a fresh clone is always correct, and
    uncommitted work is never shredded on the way.

    Errors are typed and only two escape the `clone_failed` wrapper, because they are not failures
    OF the clone: `{:unsafe_pod_dir, _}` from the guard above, and `{:sanitize_failed, _}` from the
    workspace scrub that runs after it. Everything else — git exit code, timeout, malformed base or
    feature ref — arrives as `{:error, {:clone_failed, reason}}`.
    """
    @spec clone_or_skip(Path.t(), Fleet.CapProfile.t(), keyword()) ::
            {:ok, Path.t(), String.t() | nil} | {:error, term()}
    def clone_or_skip(pod_dir, %Fleet.CapProfile{} = cap_profile, opts) do
      if confined_pod_dir?(pod_dir),
        do: do_clone_or_skip(pod_dir, cap_profile, opts),
        else: {:error, {:unsafe_pod_dir, pod_dir}}
    end

    # ⚠ RIEN N'EST DEMANDE A L'AGENT : une position DETERMINISTE n'est pas a produire par lui. Une
    # instruction peut dire QUOI sans dire OU, git n'extrait que le dernier paragraphe, et une ligne
    # echouee au milieu du message fait refuser le push APRES un run complet — clone compris.
    #
    # ⚠ APPEND MECANIQUE, PAS `git interpret-trailers` : son `--if-exists doNothing` inspecte le
    # BLOC de trailers, pas le message, donc une ligne isolee au milieu ne compte pas comme existante
    # et une seconde est ajoutee quand meme. La regle est donc la NOTRE, et elle tient en une phrase :
    # si la derniere ligne non vide est deja exactement le trailer, ne rien faire ; sinon en faire le
    # DERNIER PARAGRAPHE.
    #
    # ⚠ PARAGRAPHE, PAS LIGNE, et ce mot est tout le correctif : le gate lit le trailer par
    # l'extraction de git, qui ne voit qu'un BLOC precede d'une ligne vide. Ajouter `\n<trailer>\n`
    # ne produit cette ligne vide que si le message se terminait deja par une — donc ca passe sous
    # `git commit -m`, et ca echoue sur un message construit autrement. `$(cat)` retirant les sauts
    # finaux, le printf en rend toujours exactement une.
    #
    # Survit a `--no-verify`, qui saute `pre-commit` et `commit-msg` mais pas celui-ci. Ce que le mur
    # attrape ensuite CHANGE de nature : plus une negligence de placement, mais une FALSIFICATION —
    # le seul cas pour lequel il est interessant.
    #
    # Il vit dans `.git/hooks/`, HORS de l'arbre de travail : l'agent ne voit aucun artefact LCARS
    # dans la matiere sur laquelle il raisonne. Best-effort par construction — un hook qui ne peut
    # pas s'ecrire ne doit pas faire echouer un clone, et le gate de push reste.
    #
    # Le role se lit sur le cap-profile plutot que de voyager en parametre : un parametre qu'un
    # futur site d'appel peut oublier est un hook dont un futur pod se passe en silence.
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
          # just after, a fresh clone is always correct). The slate is cleaned through the MORGUE,
          # never a mute shredder: a deadline-killed producer leaves 10+ min of uncommitted work
          # in ws, and a bare rm_rf erases it — deliverable loss is the house's
          # top severity. A residual ws MOVES to `<ws>.morgue` (previous morgue replaced: ONE
          # generation kept — the operator salvage window, not an archive), logged ERROR.
          morgue_residual_workspace(ws)

          ref = project["reference_repo_path"]

          # ASSERTED, never defaulted (face-projet): the resolver ALWAYS engraves
          # `base_branch` in the project map — the face decision made once at dispatch. The old
          # `|| "main"` would be dead code on the live path and a substituting default on any
          # other: a project map without a base_branch has skipped the face decision, and cloning
          # the code face over it buries exactly that.
          base =
            project["base_branch"] ||
              raise(ArgumentError,
                message:
                  "Phase.Clone: project map for #{inspect(project["repo"])} carries no " <>
                    "\"base_branch\" — the face is decided at dispatch and threaded, never " <>
                    "re-defaulted here (single-default-site doctrine, face-projet)."
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
               # `--single-branch`: the workspace needs `base` and the feature branch it cuts from
               # it, and nothing else. Without it the clone brings EVERY branch of the repo — under
               # a per-ticket fan-out, that is every neighbour's feature branch, unmerged and
               # possibly wrong, sitting one `git checkout` away from an agent whose whole job is
               # to reason from `base`. The cost is not the bytes (the forge is local); it is that
               # the material is THERE, and a world projected for a pod is exactly the material it
               # should reason from.
               #
               # History is KEPT (no `--depth`): `git log`/`git blame` are legitimate tools for
               # understanding code, and this is the code face. The doc mount is the asymmetric
               # twin — a doc is consulted in its present state, so it shallows.
               #
               # `pin_base_sha` is unaffected: a pinned `base_sha` is an ancestor of `base` by
               # construction (the rail captures it from an ls-remote of that branch), so it is in
               # the fetched history; and its targeted `fetch origin <sha>` fallback stays for the
               # anomalous case it exists for.
               {:ok, {_, 0}} <-
                 Shell.git(
                   @hooks_off ++
                     ["clone"] ++ ref_args ++ ["--branch", base, "--single-branch", repo_url, ws],
                   git_opts
                 ),
               # If the forge-driven rail PINNED a base_sha (out-of-pod ls-remote), we pin HEAD onto it
               # BEFORE the feature-branch. Eliminates the window "the pod clones a base the rail did not
               # capture" (same-role race): `base..HEAD` will contain ONLY the pod's commits.
               # Axiom set AT the clone boundary (not verified "observable post-hoc").
               {:ok, {_, 0}} <- pin_base_sha(ws, project["base_sha"]),
               # `refs/lcars/base` — LA BASE CONTRE LAQUELLE CE TRAVAIL SE JUGE, materialisee ICI
               # parce que le pod ne peut pas la poser lui-meme (`update-ref` est dans sa denylist
               # git) et parce que, pour un juge, elle n'est meme pas dans son clone.
               {:ok, {_, 0}} <- pin_work_base(ws, project),
               # `checkout -b` is local (no network, does not prompt) but ALSO goes through the bounded
               # wrapper: invariant = no bare `System.cmd git` on this path (no unbounded git
               # possible). Bare env (no auth/network).
               {:ok, {_, 0}} <-
                 Shell.git(@hooks_off ++ ["-C", ws, "checkout", "-b", feature],
                   env: []
                 ),
               :ok <- install_trailer_hook(ws, cap_profile),
               :ok <- sanitize_workspace(ws) do
            {:ok, ws, feature}
          else
            {:invalid_base_branch, b} ->
              {:error, {:clone_failed, {:invalid_base_branch, b}}}

            # Named, and BEFORE the catch-all: the fall-through would have dressed them as
            # `{:git_exit, ...}`, i.e. a refusal reported as a git failure that never happened. The
            # two shapes differ (`{:invalid_base_sha, _}` bare, `{:error, {:invalid_pr_base_branch,
            # _}}` wrapped) because their producers do not share a convention -- which is exactly
            # why they are matched explicitly rather than left to the union.
            {:invalid_base_sha, s} ->
              {:error, {:clone_failed, {:invalid_base_sha, s}}}

            {:error, {:invalid_pr_base_branch, b}} ->
              {:error, {:clone_failed, {:invalid_pr_base_branch, b}}}

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
          # `sanitize_workspace` LAST and NON-optional (BL-6-16) — and NOT because `reset --hard`
          # would erase the CE_SKIP_WORKTREE bits and restore every tracked victim.
          # MEASURED, git 2.x: the bit SURVIVES `reset --hard`,
          # `checkout -B` and `clean -fdx`, and the victim stays absent through all three. Remove
          # the bit and `reset --hard` does restore the file — so what protects ticket N+1 is the
          # bit set at CLONE time, not a re-sanitisation.
          #
          # What this call actually catches is the case the old reason hid: a `.claude/` or nested
          # `CLAUDE.md` that enters the BASE BETWEEN two tickets. It did not exist at clone, so no
          # bit was set for it; the re-brief pins a new `base_sha` and brings it in. Only a sanitise
          # HERE sees it. The target repo is the parking lot — it gains files between tickets, and
          # that is precisely when nobody is looking.
          #
          # FAIL-HARD on sanitize failure: the re-brief is refused — never a pod on hostile
          # material; the wedge is visible (reprovision FAILED log), the poison is not.
          with {:ok, {_, 0}} <- pin_base_sha(ws, sha),
               # 6-135 — LE RE-BRIEF DEPLACE LA BASE, donc le ref doit suivre. Sans cette ligne un
               # pod de pipe garderait `refs/lcars/base` sur la base du ticket PRECEDENT : son diff
               # contiendrait le travail de quelqu'un d'autre, ce qui est pire qu'un ref absent
               # parce que ca ne leve pas.
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

            # Same refusal as at the clone site, named the same way. `no_base_sha` below answers
            # "the field is missing"; this one answers "the field is there and is not a ref".
            {:invalid_base_sha, s} ->
              {:error, {:reset_failed, {:invalid_base_sha, s}}}

            # ⚠ CELLE-CI EST UN `{:error, _}`, PAS UN TUPLE NU, et l'ordre des clauses est ce qui la
            # rend visible : sous le fourre-tout elle ressortait en `{:git_exit, ...}`, un refus de
            # validation deguise en panne de git. Deux formes de refus coexistent sur ce `with`
            # parce que leurs producteurs ont ete ecrits a deux moments ; les melanger silencieusement
            # est la faute que ce bloc evite.
            {:error, {:invalid_pr_base_branch, b}} ->
              {:error, {:reset_failed, {:invalid_pr_base_branch, b}}}

            {:ok, {out, code}} ->
              {:error, {:reset_failed, {code, String.slice(out, 0, 500)}}}

            {:error, {:timeout, ms}} ->
              {:error, {:reset_failed, {:git_timeout, ms}}}

            {:error, {:exit, reason}} ->
              {:error, {:reset_failed, {:git_exit, reason}}}

            # TOTAL over the Shell error union (output_overflow, bad_opt, future members).
            {:error, reason} ->
              {:error, {:reset_failed, {:git_exit, reason}}}
          end

        _ ->
          # base_sha absent = caller bug (the dispatcher MUST pin it at re-brief) → fail-loud
          # rather than a reset onto an undefined base (which would keep the previous issue's state).
          {:error, {:reset_failed, :no_base_sha}}
      end
    end

    # The residual-workspace morgue (cf. the clone-site comment): move, never erase. Kept ONE
    # generation deep — `<ws>.morgue` is a salvage window for the operator, not an archive; the
    # NEXT death replaces it. Move failure degrades to the old rm_rf (the clone MUST proceed —
    # a wedged issue trades a lost deliverable for a dead rail) and says so.
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
    BL-6-16 wall, layer 1 — neutralizes the vendor CLI's PROJECT-TIER instruction surface in
    a workspace: `.claude/` directories and NON-root `CLAUDE.md` files come from the TARGET
    repo (the parking-lot USB) and would be read as DIRECTIVES by the CLI (cwd = workspace;
    the root `CLAUDE.md` is covered separately — the composed one overwrites it, Scaffold).

    Tracked victims are flagged `git update-index --skip-worktree` BEFORE removal, so the pod's
    `git add .` never stages our deletions into its deliverable — the gate's
    forbidden-path check is the independent second line. Called by BOTH workspace producers:
    `clone_or_skip` at spawn, and `reset_in_place` at every slot-freeze re-brief, where what it
    catches is material that entered the BASE between two tickets (the skip-worktree bit set at
    clone survives `reset --hard`, measured; a file that was not there at clone has no bit).
    Neutralized paths are logged ONCE, warning: the operator of a legitimate repo must see that its
    `.claude/` does not follow. The empty-workspace path (no repo) has nothing to sanitize and
    never calls this.
    """
    @spec sanitize_workspace(Path.t()) :: :ok | {:error, {:sanitize_failed, term()}}
    def sanitize_workspace(ws) do
      victims = claude_dirs(ws) ++ nested_claude_mds(ws)

      # ⚠ LA RACINE `CLAUDE.md` N'EST PAS FLAGUEE, ET CE N'EST PAS UN OUBLI. La flaguer protegerait
      # notre copie composee de partir dans le livrable — mais sur un depot qui TRACKE sa racine
      # `CLAUDE.md`, c'est-a-dire tout projet cree par la fleet puisque le template en pose un, un
      # producteur ne peut plus livrer ce fichier. Effet de bord mesure : son edition n'est jamais
      # stagee, `git status` reste propre et `git diff` vide EN AYANT TORT, donc un producteur
      # appliquant la discipline de preuve obtient un faux negatif et declare le critere tenu de
      # bonne foi.
      # L'environnement neutralisait l'instrument de preuve qu'il exige par ailleurs.
      # Le Scaffold n'ecrase plus un `CLAUDE.md` tracke (il n'y a donc plus rien a masquer), et le
      # cas non-tracke reste couvert par `.git/info/exclude`, qui lui ne ment a personne.
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
      case Shell.git(@hooks_off ++ ["-C", ws, "ls-files", "-z"], env: []) do
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
    The target repo's ORIGINAL root `CLAUDE.md`, read from GIT (`git show HEAD:CLAUDE.md`) —
    never from the working tree, which carries OUR composed file from the first spawn on.
    `:absent` covers both "not tracked at HEAD" (an adopted repo that carries none; a project the
    fleet onboarded carries the template's) and any git failure: no original, no repo-section
    rail, the composed doc renders its repo zone empty (BL-6-16, cf. Scaffold).
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

    # `sha` REACHED THE GIT COMMAND LINE UNVERIFIED, IN LAST POSITION AND WITHOUT `--`. An argument
    # starting with `-` is an OPTION to git, not a revision -- and the second call here is the one
    # that carries the forge credentials and touches the network. The sibling checks two lines up
    # (`base`, `feature`) already go through `GitRef.valid?/1`; this argument is on the same `with`,
    # in the same function, and must go through it too.
    #
    # `GitRef.valid?/1` and not a hex-only test: this field legitimately holds a ref as well as a
    # sha, and the validator is the one every other ref on this path uses. Measured against what it
    # must REFUSE: `-x`, `--exec=id`, `--upload-pack=...`, `a b`, `""` -- and what it must LET
    # THROUGH: `abc1234`, `refs/heads/main`, `HEAD`.
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
          # The local `reset` failed (`sha` absent locally) → targeted NETWORK fetch (forge auth + anti-prompt
          # bound via `git_env/0`), then local re-reset. Fetch failure (incl. timeout/exit) →
          # propagated as-is to the `with` → `{:clone_failed, ...}`.
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

    # ⚠ UN CLONE DE REVIEW EST `--single-branch` SUR LA HEAD : il ne contient PAS la base. Les
    # commandes de preuve prescrites a un juge echouaient donc sur une revision inconnue, et un
    # agent prive de son instrument improvise ou juge sur le seul brief. Pour une PR de face
    # atelier, la base metier n'est de toute facon pas la branche principale.
    #
    # ⚠ UN SEUL NOM, POUR TOUS LES PODS : c'est la condition pour qu'un prompt puisse le NOMMER. Un
    # ref conditionnel obligerait l'instruction a dire « selon les cas », ce qu'un agent ne sait pas
    # resoudre depuis l'interieur de son workspace.
    #
    #   * un pod qui porte la base d'une PR (`pr_base_branch` : juge, rework) → on la RAPATRIE, elle
    #     n'est pas dans le clone ;
    #   * tout autre pod → sa base est deja la (c'est celle qu'il a clonee), on pose juste le nom.
    #
    # `+refs/heads/<base>:refs/lcars/base` en une passe : le ref est cree deterministe, sans passer
    # par `FETCH_HEAD` que la commande suivante ecraserait.
    #
    # UN ECHEC ICI ARRETE LE SPAWN, delibere et borne : il ne peut arriver qu'a un pod qui juge, et
    # « la base a disparu » est exactement l'etat ou un verdict ne doit pas etre rendu. Le pod n'est
    # pas pris : le verrou n'a pas ete pose, le tick suivant retente, et un echec durable remonte
    # sous son propre nom au lieu de produire un juge aveugle.
    @doc """
    A0.5 (mesuré au banc) — refreshes `refs/lcars/base` ALONE on a live
    workspace, no reset, no clean, no `/clear`.

    The hole it closes sits at the INTERSECTION of two deliberate decisions: an instance-scoped
    producer in rework is re-briefed in place without reprovision (the ticket's
    context is an asset), and `refs/lcars/base` only moves inside the reprovision path (6-135 —
    "le re-brief déplace la base, donc le ref doit suivre"). A CONFLICT rework is precisely the
    case where the base HAS moved — measured: the pod merged its stale `lcars/base` ("Already up
    to date", twice), redelivered unchanged, burned its budget and escalated a conflict it was
    never given the means to see. It cannot fetch by itself: it is forge-blind by design.

    Requires the project map to carry `pr_base_branch` (stamped by `RoleDispatch` on every review
    dispatch) — a conflict rework without it is a caller that has not said which base moved.
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

    defp pin_work_base(ws, project) do
      case project["pr_base_branch"] do
        base when is_binary(base) and base != "" ->
          fetch_work_base(ws, base)

        _ ->
          local_work_base(ws)
      end
    end

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

    # Aucun reseau, et `HEAD` plutot que le nom de la branche ou le sha : a cet instant precis HEAD
    # EST la base — `pin_base_sha` vient de l'y poser et la branche de travail n'est pas encore
    # coupee. Nommer `base_branch` ferait dependre le geste d'une subtilite de resolution de ref
    # (mono-branche : le clone cree bien la branche locale, mais c'est un detail de `git clone` et
    # pas un invariant qu'on veut porter ici) ; nommer `base_sha` echouerait quand il est absent.
    defp local_work_base(ws) do
      Shell.git(
        @hooks_off ++ ["-C", ws, "update-ref", "refs/lcars/base", "HEAD"],
        env: []
      )
    end

    # pod_dir CONFINEMENT lives UPSTREAM: the spawner builds pod_dir as `<pod_dir_root>/pod_<pod_id>`
    # from a pod_id validated by `Fleet.Spawner.valid_pod_id?` (no `..`, no `/`). This module
    # CANNOT re-derive that root: `Fleet.Spawner` is not among this domain's boundary deps, and
    # widening them for one path derivation would be an API decision. So it cannot check
    # "under root" here. What it CAN and MUST assert before any `rm_rf`/`mkdir` is that pod_dir is
    # ABSOLUTE: a relative pod_dir would make the fixed subdirs `<pod_dir>/workspace|work` resolve
    # against the runtime's CWD → `rm_rf`/`mkdir` on `<cwd>/workspace` (the one footgun visible without
    # the root). Non-absolute → refuse fail-loud (`{:error, {:unsafe_pod_dir, _}}`), never touch the FS.
    defp confined_pod_dir?(pod_dir), do: is_binary(pod_dir) and Path.type(pod_dir) == :absolute

    # No local `forge_auth_args/0` helper (nor a dup of `Fleet.Workflow.Git`, despite the
    # workflow⇄bootstrap compile cycle): forge auth has a single source `Fleet.Credentials.ForgeAuth.git_env/0`
    # (fleet_credentials is below both apps → no cycle), token via env outside argv.

    # No `set_git_identity/2`: setting the pod's commit identity via `git config` in the workspace's `.git/config` would
    # be MUTABLE — the pod could overwrite it (`git config user.email …`) → forgeable identity. The identity is set in
    # env at launch (bwrap_launch.sh: GIT_AUTHOR_*/GIT_COMMITTER_* = the HUMAN of the brief, the role riding the
    # `Co-authored-by:` trailer, cf. `ForgeIdentity`; + GIT_CONFIG_GLOBAL=/dev/null), a deterministic cooperative
    # default the pod cannot override. The guarantee lives on the world side:
    # `Fleet.Workflow.DeliverableGate.check_identity/3` rejects at push any commit outside the authorized identity (the
    # pod CANNOT push a spoofed deliverable).
  end
end
