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

  **Last revised**: 2026-08-02
  """

  require Logger

  alias Fleet.Spawner.Pod.LaunchSpec
  alias Fleet.Spawner.Pod.SessionFiles

  @doc """
  Removes any residual `<session_id>.jsonl` under the pod_dir (all cwd-slugs, shared glob
  `SessionFiles.jsonl_paths/2`) → frees the UUID for `--session-id` (a stale jsonl would trip
  "Session ID already in use" on the deterministic re-spawn). A leftover jsonl does not FAIL here — it
  resurfaces at the `--session-id` launch itself as the vendor's "Session ID already in use" error (the
  launch, not this GC, carries the blocking failure). But we log the REAL result per file, never a blanket
  "removed": actually removed → info; already absent → silent; a removal that FAILED → warning (so the
  residue is diagnosed here too, not only at the later launch). Called by the `:cleaning` state
  (skipped on `resume` — `SeedStore.restore` overwrites the jsonl).
  """
  @spec gc_stale_session_jsonl(map()) :: :ok
  def gc_stale_session_jsonl(state) do
    state.pod_dir
    |> SessionFiles.jsonl_paths(state.session_id)
    |> Enum.each(fn f ->
      case File.rm(f) do
        :ok ->
          Logger.info(
            "pod #{state.pod_id} gc: stale jsonl #{Path.basename(f)} removed (UUID GC → fresh session)"
          )

        {:error, :enoent} ->
          # Nothing to remove (the UUID slot is already free) — the nominal case, silent.
          :ok

        {:error, reason} ->
          Logger.warning(
            "pod #{state.pod_id} gc: could NOT remove stale jsonl #{Path.basename(f)} " <>
              "(#{inspect(reason)}) — the --session-id launch will surface it as 'Session ID already in use'"
          )
      end
    end)
  end

  @doc """
  Wiring of `Fleet.ProjectBootstrap.Phase.Clone` for pods carrying a project (`repo_path`): the
  EFFECTIVE project comes from the BRIEF (`LaunchSpec.effective_project/2`: `opts[:project]`
  injected by the issue→repo dispatch) or from the static cap_profile (permanent pods). Present:
  clones the repo into `<pod_dir>/workspace/` + checkout of the feature branch + doc branch
  (`work/ops` — nil if the project has no doc branch, fail-loud if declared but absent); the REPL's
  cwd points at this workspace (`maybe_put_pod_cwd` → `LCARS_POD_CWD`) → the agent codes INSIDE its
  branch (idempotent clone on respawn). The composed `CLAUDE.md` is copied to the root of the
  workspace (with cwd=workspace it must be INSIDE the cwd). Absent (`repo_path` nil) → no-op.

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
        # cap_profile carrying the EFFECTIVE project (brief > static) for the Clone.* (which read spec.project).
        eff_cap = Fleet.CapProfile.with_project(state.cap_profile, project)

        with {:ok, workspace, branch} <-
               Fleet.ProjectBootstrap.Phase.Clone.clone_or_skip(
                 state.pod_dir,
                 eff_cap,
                 []
               ),
             # Doc-mount: the `work/ops` branch (plans/backlog/conventions) alongside
             # the code. nil if the project has no doc branch; fail-loud if declared but absent.
             {:ok, doc} <-
               Fleet.ProjectBootstrap.Phase.Clone.clone_work_doc(
                 state.pod_dir,
                 eff_cap
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
          maybe_enrich_claude_md(state, workspace)

          # Composed CLAUDE.md (pod-identity + repo conventions) at the root of the CWD (workspace):
          # the agent pops into an already-documented project. The :projecting state writes it at the
          # pod_dir (parent); with cwd=workspace it must be INSIDE the cwd (otherwise the agent codes
          # without its codebase-doc in cwd). Load-bearing → a copy FAILURE is LOUD,
          # not fatal (the pod still launches; the doc-in-cwd is a degradation, not a HALT).
          case File.cp(Path.join(state.pod_dir, "CLAUDE.md"), Path.join(workspace, "CLAUDE.md")) do
            :ok ->
              :ok

            {:error, reason} ->
              Logger.warning(
                "pod #{state.pod_id} CLAUDE.md → workspace copy FAILED (#{inspect(reason)}) — " <>
                  "the agent's cwd lacks its codebase-doc (pod-identity + repo conventions)"
              )
          end

          Logger.info(
            "pod #{state.pod_id} workspace=#{workspace} (branch=#{branch || "default"})" <>
              if(doc, do: " doc=#{doc}", else: " (no doc branch)")
          )

          :ok
        else
          {:error, reason} -> {:error, {:project_workspace_clone_failed, reason}}
        end
    end
  end

  @doc """
  Deliberate recall. If `opts[:recall_seed_jsonl]` is provided (by `Fleet.Spawner.recall/2`),
  restores the seed to `projects/<slugify(cwd)>/<session_id>.jsonl` BEFORE the launch; claude
  `--resume <session_id>` (resume:true via opts) finds it again. Gated: absent → no-op (normal spawn
  intact). The seed is validated (`read_map`) on the `Spawner.recall` side; absent HERE = fail-loud
  (`{:recall_seed_missing, _}` → `transition_failed`).
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
          # `SeedStore.restore/4` is a BANG (raises on cp!/mkdir_p! failure or an escaping uuid). We FOLD
          # that raise into a typed error so the `:projecting` `with` routes it to `transition_failed`
          # (clean tombstone written), instead of the raise crossing the `with` and crashing the Pod
          # gen_statem (abnormal exit → no phase=failed → reclaim/re-dispatch loop on the same bad seed).
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

  # The repo-section revival (BL-6-16 — cf. the call-site comment for WHY here and not at
  # :projecting). Original absent (nominal: the template ships no CLAUDE.md) → silent no-op,
  # the :projecting composition stands. Any failure past that point degrades LOUD to the
  # identity-only CLAUDE.md — a pod without repo conventions beats no pod, and beats a pod
  # whose repo doc bypassed the reception filter.
  defp maybe_enrich_claude_md(state, workspace) do
    case Fleet.ProjectBootstrap.Phase.Clone.read_original_claude_md(workspace) do
      :absent ->
        :ok

      {:ok, original} ->
        repo_source = Path.join(state.pod_dir, "CLAUDE.md.repo-source")

        with :ok <- File.write(repo_source, original),
             {:ok, md} <- Fleet.SPBuilder.compose_claude_md(state.cap_profile, repo_source),
             :ok <- File.write(Path.join(state.pod_dir, "CLAUDE.md"), md) do
          :ok
        else
          {:error, reason} ->
            Logger.warning(
              "pod #{state.pod_id} repo-section enrichment FAILED (#{inspect(reason)}) — " <>
                "the pod launches on the identity-only CLAUDE.md (no repo conventions)"
            )

            :ok
        end
    end
  end
end
