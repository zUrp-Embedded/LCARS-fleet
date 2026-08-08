defmodule Fleet.Pilot.ProjectArchitect do
  @moduledoc """
  The PER-PROJECT architect — pod-id AUTHORITY + idempotent `ensure/2` (reorg 2026-07-19,
  cf. DESIGN-carte-des-roles §6/§14). Replaces the old fleet-level permanent arch: ONE architect
  per repo, project-bound identity (numeric repo id in its deterministic UUID → a stable Desktop
  slot per project), spawned ON-OPEN (create/import/open) and ON-DEMAND (escalation rail).

  ## No clone — the three faces, and one of them only in reading

  The arch is NOT a producer of code: a work clone (frozen at spawn, forge-blind so never fetched)
  is the wrong window for it. Its world = three DYNAMIC mounts derived from the project name, one
  per face:

    * `/home/projects/<name>` **RO** — read the code to frame briefs (the host-side dir, the same
      view the human has). Read-only and HARD: a typo fixed by hand here is a change nobody
      reviewed, and an actor with a pen uses it where nobody is looking;
    * `/home/projects.doc/<name>` **RW** — this IS its producing face. The documentation is written
      here, with the human, at the terminal — which is the bulk of what actually happens — and a
      scribe enriches it through the ordinary pipeline.

      A DRAFT SPACE, AND DELIBERATELY SO (user arbitration): nothing pushes this face on its own,
      and nothing written here enters the project as-is. What the human and the arch produce
      together is MATTER, not a deliverable — a scribe ticket carries it through the ordinary
      pipeline, judged and sealed like any other, even when the pass is only an eval. The pod is
      told this in its own words, because a pod that believes it published fills the gap the same
      way one that cannot see its deliverable does;
    * `/home/projects.work/<name>` **RO** — the record: briefs, verdicts, provenance. The arch is
      the ONLY pod that mounts it, and reading it is its function — following the work and
      reporting it to the human. **Read-only, and the mode is the point**: it is the party being
      judged, and a judged party that can rewrite the tree it is judged on is not judged at all.

  The in-flight work view (branches, PRs) is the FORGE via its MCP tools (`get_issue_status`),
  never git — neither a frozen clone nor a mount shows branches born after spawn.

  ## Idempotent ensure (open = relaunch = crash-recovery)

  `ensure/2` is the SINGLE entry for "this project must have its architect": deterministic
  `pod_id` (`architect-<name>`) → alive = `{:already_started}` no-op; dead/never = fresh spawn
  (context back via the slot sidecar). Callers: `ProjectOnboard` (on-open, best-effort),
  `ArchWake` (on-demand when an escalation arrives), the `open_project` tool (human-driven
  relaunch). A project NOT on the machine (`/home/projects/<name>` absent) is REFUSED
  (`:not_onboarded`) — an architect without its project world would be an empty box.

  ## Seams (keyword opts, defaults = real)

    * `:spawner` — default `Fleet.Spawner` (the `spawn_pod/3` provider).
    * `:forge_client` — default `Fleet.Pilot.ForgeClient` (numeric repo id for the UUID).
    * `:loader` — default `Fleet.CapProfile` (load + compose with default modops).
    * `:projects_root` / `:work_root` / `:doc_root` — FS roots (defaults `Fleet.Layout`), same
      keys as `ProjectOnboard` (the onboard opts thread through unchanged).
  """

  require Logger

  alias Fleet.Pilot.StepDispatcher.Spawn

  # Deterministic per-project arch pod id. NOT `permanent-*`: the arch is not a fleet permanent
  # (PermanentWarden must not respawn it — the escalation rail and the open verbs do, on demand).
  @pod_prefix "architect-"

  @doc """
  THE pod-id authority for a project's architect: `architect-<name>` (`name` = the repo's name
  segment). Accepts a `owner/name` full_name or a bare name. Every consumer (ArchWake, ArchFeed,
  open_project) derives through here — never a rebuilt literal.
  """
  @spec pod_id_for(String.t()) :: String.t()
  def pod_id_for(repo_or_name) when is_binary(repo_or_name),
    do: @pod_prefix <> Fleet.Layout.project_name(repo_or_name)

  @doc """
  Ensures the per-project architect of `repo` (`owner/name`) is up — idempotent (alive → no-op).
  `{:ok, pod_id}` | `{:error, reason}`. Best-effort at every call site: a failure is logged and
  never fatal to the caller (the project exists; ensure can be retried on the next trigger).
  """
  @spec ensure(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def ensure(repo, opts \\ []) when is_binary(repo) and is_list(opts) do
    spawner = Keyword.get(opts, :spawner, Fleet.Spawner)
    forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
    loader = Keyword.get(opts, :loader, Fleet.CapProfile)
    forge_opts = Keyword.take(opts, [:token, :base_url])

    name = Fleet.Layout.project_name(repo)
    proj_dir = Path.join(Keyword.get(opts, :projects_root, Fleet.Layout.projects_root()), name)
    work_dir = Path.join(Keyword.get(opts, :work_root, Fleet.Layout.work_root()), name)
    doc_dir = Path.join(Keyword.get(opts, :doc_root, Fleet.Layout.doc_root()), name)
    repo_id_result = Spawn.repo_id(forge, repo, forge_opts)

    cond do
      # EVERY mounted face must exist, because bwrap binds STRICTLY: a missing source is not an
      # empty mount, it is a launcher that dies. Checking only the code face let a project whose
      # doc face never landed pass this door and fail at the bind, with an error naming bwrap
      # instead of the onboarding that never completed.
      missing = Enum.find([proj_dir, work_dir, doc_dir], &(not File.dir?(&1))) ->
        {:error, {:not_onboarded, missing}}

      match?({:error, _}, repo_id_result) ->
        {:error, reason} = repo_id_result

        Logger.error(
          "ProjectArchitect: repo id unresolved for #{repo} (#{inspect(reason)}) — arch NOT ensured"
        )

        {:error, {:repo_id_unresolved, repo, reason}}

      true ->
        {:ok, repo_id} = repo_id_result

        # The role is RESOLVED by the `project_delegate` capability, never named — same source as
        # the gate that admits the call (`Delegation.require_architect/1`, B-03). Naming it here
        # would gate correctly on a renamed delegate and then ensure a role the catalogue lacks.
        with {:ok, cap} <-
               Fleet.CapProfile.resolve(loader, Fleet.Pilot.Roles.project_delegate_role()) do
          pod_id = pod_id_for(name)

          spawn_opts = [
            pod_id: pod_id,
            # The repo the pod is BOUND to — exposed by `pod_info` so the MCP delegation tools
            # resolve "the project" from the channel identity (the arch never names it).
            repo: repo,
            repo_id: repo_id,
            rc_name: Fleet.Layout.pod_label(name, "architect"),
            project_slug: name,
            # The arch's world (moduledoc): live host dirs, not a frozen clone. ONE writable
            # face and it is `doc` — the face it produces on. `ops` is the record it is judged
            # against, so it reads it and cannot touch it; `code` goes through the pipeline like
            # everyone else's.
            #
            # ORDER MATTERS HERE. `pod_cwd/3` falls back to the FIRST rw mount for a pod with no
            # project remap, and `pod_mounts_env/3` keeps the FIRST occurrence of a path. Putting
            # the two read-only faces ahead of the writable one is therefore not cosmetic.
            mounts: [
              %{"mode" => "ro", "path" => proj_dir},
              %{"mode" => "ro", "path" => work_dir},
              %{"mode" => "rw", "path" => doc_dir}
            ]
          ]

          case spawner.spawn_pod(cap, pod_id, spawn_opts) do
            {:ok, _pid} ->
              Logger.info(
                "ProjectArchitect: architect ensured for #{repo} (pod #{pod_id}, spawned)"
              )

              {:ok, pod_id}

            {:error, {:already_started, _pid}} ->
              {:ok, pod_id}

            {:error, reason} = err ->
              Logger.error(
                "ProjectArchitect: architect spawn for #{repo} FAILED (#{inspect(reason)}) — " <>
                  "retried on the next open/escalation trigger"
              )

              err
          end
        else
          {:error, reason} = err ->
            Logger.error(
              "ProjectArchitect: architect cap-profile load/compose failed (#{inspect(reason)})"
            )

            err
        end
    end
  end
end
