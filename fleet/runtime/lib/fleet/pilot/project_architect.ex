defmodule Fleet.Pilot.ProjectArchitect do
  @moduledoc """
  The PER-PROJECT architect — pod-id AUTHORITY + idempotent `ensure/2` (reorg 2026-07-19,
  cf. DESIGN-carte-des-roles §6/§14). Replaces the old fleet-level permanent arch: ONE architect
  per repo, project-bound identity (numeric repo id in its deterministic UUID → a stable Desktop
  slot per project), spawned ON-OPEN (create/import/open) and ON-DEMAND (escalation rail).

  ## No clone — mounts (§14.d)

  The arch is NOT a producer: a work clone (frozen at spawn, forge-blind so never fetched) is the
  wrong window for it. Its world = two DYNAMIC mounts derived from the project name:

    * `/home/projects/<name>` **RO** — read the code to frame briefs (the host-side dir, the same
      view the human has);
    * `/home/projects.work/<name>` **RW** — author its docs/briefs (the system pushes; the pod
      stays forge-blind like every worker: it commits in its pod, the SYSTEM pushes).

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
    * `:projects_root` / `:work_root` — FS roots (defaults `Fleet.Layout`), same keys as
      `ProjectOnboard` (the onboard opts thread through unchanged).

  **Last revised**: 2026-08-02
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
    # The EXPLAINED shape (`Spawn.repo_id/3`), not the `nil`-flattening `resolve_repo_id/3` its
    # optional callers use: here an unresolved id is a REFUSAL, and a refusal owes its reason.
    repo_id_result = Spawn.repo_id(forge, repo, forge_opts)

    cond do
      not File.dir?(proj_dir) ->
        # Never spawn an architect for a project that is not on the machine: its whole world is the
        # mounts below — an absent project dir would launch an EMPTY box. open/import first.
        {:error, {:not_onboarded, proj_dir}}

      match?({:error, _}, repo_id_result) ->
        # The numeric id IS the arch's identity (`<REPO4>` of the deterministic UUID). Refused early
        # and clearly rather than letting SessionMint raise inside the pod init (same fact, worse trace).
        # The reason is CARRIED, never inferred: this log used to end in "(forge down?)" over a forge
        # that was answering — the guess was the only thing an operator could read, and it pointed
        # away from the fault. What we know is what the forge said; if that is not enough, the fix is
        # upstream of here.
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
            # The arch's world (moduledoc): live host dirs, not a frozen clone.
            mounts: [
              %{"mode" => "ro", "path" => proj_dir},
              %{"mode" => "rw", "path" => work_dir}
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
