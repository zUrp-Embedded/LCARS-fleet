defmodule Fleet.Spawner.Pod.Scaffold do
  @moduledoc """
  WORKSPACE & SESSION of the pod_dir — island extracted from `Fleet.Spawner.Pod`.

  The disk steps of the boot that touch the pod's work SUBSTRATE: GC of the session UUID before a
  re-spawn (`:cleaning`), project workspace bootstrap (git clone + doc branch, `:projecting`) and
  restore of the recall seed (`:projecting`). The two other families of steps have their own
  dedicated islands: the vendor/priv ASSETS (`Pod.Assets` — settings/draft/protocole/watch.sh) and
  the BRIEF (`Pod.Brief` — `issues/<id>.md` + TaskQueue enqueue).

  This module does NOT ORCHESTRATE: the `:cleaning`/`:projecting` STATES stay at the heart of `Pod`
  (their big `with` is the orchestrator). Each step returns `:ok` or a tagged `{:error, reason}`
  that the `:projecting` state's `with` propagates to `transition_failed` (clean cleanup:
  phase=failed + state.json written). `Pod` passes it the `state` as an argument; the module calls
  back NO private of `Pod` (no cycle).

  ## Contract (called by `Pod`)

  - `gc_stale_session_jsonl(state)` — called by the `:cleaning` state (GC of the session UUID before
    a `--session-id` re-spawn).
  - `maybe_bootstrap_project_workspace(state)` / `maybe_recall_restore(state)` — steps called in the
    `:projecting` state's `with`.

  Depends on `Pod.LaunchSpec` (effective cwd/project), `Pod.SessionFiles` (shared glob of the
  session jsonl), `Fleet.CapProfile` (single source of the `name` + `with_project/2`),
  `Fleet.ProjectBootstrap.Phase.Clone` (workspace + doc clone) and `Fleet.Spawner.SeedStore`
  (recall restore). No dependency toward `Fleet.Spawner.Pod`.
  """

  require Logger

  alias Fleet.Spawner.Pod.LaunchSpec
  alias Fleet.Spawner.Pod.SessionFiles

  @doc """
  Removes stale JSONLs for the deterministic session ID across all cwd slugs.

  Removal is best-effort and logged per file; a residue is surfaced by the later
  vendor launch.
  """
  @spec gc_stale_session_jsonl(map()) :: :ok
  def gc_stale_session_jsonl(state) do
    state.pod_dir
    |> SessionFiles.jsonl_paths(state.session_id)
    |> Enum.each(fn f ->
      # RENAME, not rm (debug scribe 2026-08-02): the stale jsonl is the DEAD predecessor's
      # transcript — the only forensic trail of what it was doing when killed. `.dead` frees the
      # UUID exactly like removal (the glob matches *.jsonl only) and keeps ONE generation of
      # evidence; the next death replaces it.
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
  Wiring of `Fleet.ProjectBootstrap.Phase.Clone` for pods carrying a project (`repo_path`): the
  EFFECTIVE project comes from the BRIEF (`LaunchSpec.effective_project/2`: `opts[:project]`
  injected by the issue→repo dispatch) or from the static cap_profile (permanent pods). Present:
  clones the repo into `<pod_dir>/workspace/` + checkout of the feature branch; the REPL's cwd
  points at this workspace (`maybe_put_pod_cwd` → `LCARS_POD_CWD`) → the agent codes INSIDE its
  branch (idempotent clone on respawn). The composed `CLAUDE.md` is copied to the root of the
  workspace ONLY when the repo does not track one of its own — a tracked `CLAUDE.md` is both the
  producer's INPUT and a legitimate deliverable, so it stays untouched and stageable. Absent
  (`repo_path` nil) → no-op.

  The OTHER production face is NOT cloned here: it reaches the pod as an RO BIND
  (`LaunchSpec.other_face_reference_path/3`). A second mechanism cloning it into `<pod_dir>/work`
  existed and never ran — its trigger field had no writer anywhere in the corpus — so a reader met
  the dead one first and took it for the live one.

  Being a BIND and not a clone has one consequence worth knowing before assuming otherwise: the pod
  reads the LIVE worktree, the one the dispatcher commits other tickets' briefs into. Harmless (RO,
  and git is coherent per file) but not a snapshot — two reads by one pod can see two states.

  The pod's commit identity is NOT set here (no mutable, falsifiable `git config`): it is injected in
  the env at launch (`LaunchEnv.build` → `GIT_AUTHOR_*`/`GIT_COMMITTER_*` = the HUMAN, role in the
  trailer) and the guarantee lives on the world side (DeliverableGate gate at push).
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

        with {:ok, workspace, branch} <-
               Fleet.ProjectBootstrap.Phase.Clone.clone_or_skip(
                 state.pod_dir,
                 eff_cap,
                 []
               ) do
          # Repo-section rail, revived HERE and not at :projecting (BL-6-16): the composer runs
          # at :projecting, the clone at :launching — the original rail expected
          # `CLAUDE.md.repo-source` to exist BEFORE composition, an order the state machine
          # contradicts, which is why its writer never existed and zero repo sections ever
          # reached a pod. Post-clone is the first moment the original is READABLE (from GIT,
          # never the working tree — from the 2nd spawn on the tree carries OUR composed file):
          # write repo-source, re-compose the CLAUDE.md with it (RepoSections filters each
          # section through Fleet.ReceptionFilter — hostile sections are dropped loud there),
          # overwrite the pod_dir copy. Best-effort LOUD: a failure degrades to the
          # identity-only CLAUDE.md of :projecting, never a HALT.
          repo_doc = maybe_enrich_claude_md(state, workspace)

          # Composed CLAUDE.md (pod-identity + repo conventions) at the root of the CWD (workspace):
          # the agent pops into an already-documented project. The :projecting state writes it at the
          # pod_dir (parent); with cwd=workspace it must be INSIDE the cwd (otherwise the agent codes
          # without its codebase-doc in cwd). Load-bearing → a copy FAILURE is LOUD,
          # not fatal (the pod still launches; the doc-in-cwd is a degradation, not a HALT).
          # ⚠ ON N'ECRASE PLUS LE `CLAUDE.md` D'UN DEPOT QUI LE TRACKE. Ce fichier est l'ENTREE de
          # tout producteur (ses sept sections voyagent dans le prompt compose) et il doit rester
          # LIVRABLE : c'est par la que ses conventions se mettent a jour quand la pile change.
          # L'ecraser obligeait a le masquer (`skip-worktree`), donc a rendre `git status` propre et
          # `git diff` vide EN AYANT TORT — un producteur qui applique la discipline de preuve
          # obtenait un faux negatif et declarait le critere tenu de bonne foi. Mesure 2026-08-12.
          #
          # Ce que la copie apportait est parti la ou ca vit : l'identite arrive par
          # `--system-prompt-file` (remplacante et fiable, claude_launch.sh), et la doctrine de
          # sortie/preuve/path est dans les blocs SP (le bloc du monde projete, `evidence`,
          # `producer-output`). Il ne restait dans le fichier compose que l'identite dupliquee et
          # les sections du depot — que l'agent lit desormais a leur source.
          if repo_doc == :tracked do
            Logger.info(
              "pod #{state.pod_id} workspace CLAUDE.md: celui du DEPOT, intact et livrable " <>
                "(la doctrine du pod arrive par le system-prompt, plus par ce fichier)"
            )
          else
            case File.cp(Path.join(state.pod_dir, "CLAUDE.md"), Path.join(workspace, "CLAUDE.md")) do
              :ok ->
                # Anti-leak, UNTRACKED case (measured live on the scribe bench: `?? CLAUDE.md` in
                # git status): on a repo that does not track a root CLAUDE.md, OUR composed copy is
                # stageable — a pod's `git add -A` would ship pod-identity material in its
                # deliverable, and the gate's path wall deliberately allows the ROOT CLAUDE.md.
                # `.git/info/exclude` hides it from add/status, is clone-local, and never ships.
                exclude_composed_claude_md(workspace)

              {:error, reason} ->
                Logger.warning(
                  "pod #{state.pod_id} CLAUDE.md → workspace copy FAILED (#{inspect(reason)}) — " <>
                    "the agent's cwd lacks its codebase-doc (pod identity)"
                )
            end
          end

          Logger.info(
            "pod #{state.pod_id} workspace=#{workspace} (branch=#{branch || "default"})"
          )

          :ok
        else
          {:error, reason} -> {:error, {:project_workspace_clone_failed, reason}}
        end
    end
  end

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

  # cf. the call-site comment (anti-leak, untracked case). Idempotent; best-effort LOUD.
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

  # The repo-section revival (BL-6-16 — cf. the call-site comment for WHY here and not at
  # :projecting). Original absent (nominal: the template ships no CLAUDE.md) → silent no-op,
  # the :projecting composition stands. Any failure past that point degrades LOUD to the
  # identity-only CLAUDE.md — a pod without repo conventions beats no pod, and beats a pod
  # whose repo doc bypassed the reception filter.
  # Rend `:tracked` quand le depot porte une racine `CLAUDE.md` A HEAD (`git show HEAD:CLAUDE.md` —
  # c'est exactement le predicat « ce fichier est versionne », pas « il existe sur le disque »), et
  # `:absent` sinon. L'appelant s'en sert pour NE PAS ecraser un fichier livrable.
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

            # `:tracked` MEME EN ECHEC : le depot porte bien ce fichier (on vient de le lire a HEAD),
            # seule la composition de la copie pod_dir a rate. Rendre `:absent` ici ferait ecraser un
            # fichier livrable par une copie degradee — l'echec d'un confort deviendrait la perte
            # d'une entree.
            :tracked
        end
    end
  end
end
