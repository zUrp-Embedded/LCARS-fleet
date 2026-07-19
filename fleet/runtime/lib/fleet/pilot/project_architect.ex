defmodule Fleet.Pilot.ProjectArchitect do
  @moduledoc """
  Spawns the PER-PROJECT architect on-open — the reorg-2026-07-19 machinery that replaces the old
  fleet-level permanent arch. When starfleet creates/adopts a project (`ProjectOnboard.onboard`/`import`),
  the project's architect is spawned HERE: one arch per repo, project-bound (repo in its deterministic
  UUID → a stable Desktop slot), cloning its project like any worker.

  **Best-effort**: a spawn failure is LOGGED, NEVER fatal to the onboard — the project exists on the
  forge, and its arch can be relaunched. Reuses the producer-spawn machinery
  (`StepDispatcher.Spawn.resolve_repo_id`, `Fleet.Spawner.spawn_pod`) — same domain, no new spawn path.

  ## Deterministic pod_id (relaunch-idempotent)

  `architect-<name>`: stable per repo. A re-open re-spawns the SAME pod_id → `{:already_started}` no-op
  if the arch is alive, fresh spawn if it died. NOT a `permanent-*` id: the arch is boot_at_start:false,
  so the `PermanentWarden` must not treat it as a fleet permanent to respawn.

  ## Seams (keyword opts, defaults = real)

    * `:spawner` — default `Fleet.Spawner` (the `spawn_pod/3` provider).
    * `:forge_client` — default `Fleet.Pilot.ForgeClient` (resolves the numeric repo id for the UUID).
    * `:loader` — default `Fleet.CapProfile` (load + compose the arch cap with its default modops).

  **Last revised**: 2026-07-19
  """

  require Logger

  alias Fleet.Pilot.StepDispatcher.Spawn

  @doc """
  Spawns the per-project architect for a just-opened project. `%{repo, url, name}` = the onboard result
  (repo `owner/name`, git `url` = the clone/push URL the arch's workspace clones, kebab `name`). `opts` =
  the onboard opts (carry the seams + forge token). Best-effort: `{:ok, pod_id}` | `{:error, reason}`
  (logged, non-fatal to the caller).
  """
  @spec open(%{repo: String.t(), url: String.t(), name: String.t()}, keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def open(%{repo: repo, url: url, name: name}, opts)
      when is_binary(repo) and is_binary(url) and is_binary(name) do
    spawner = Keyword.get(opts, :spawner, Fleet.Spawner)
    forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
    loader = Keyword.get(opts, :loader, Fleet.CapProfile)
    forge_opts = Keyword.take(opts, [:token, :base_url])

    with {:ok, base} <- loader.load("architect"),
         {:ok, cap} <- loader.compose("architect", loader.default_modops(base)) do
      pod_id = "architect-" <> name

      spawn_opts = [
        pod_id: pod_id,
        # Project-bound like the engineer: `repo_path` = the git URL its workspace clones; `base_branch`
        # = main (the arch reads the code to frame briefs, it does not push — forge-blind by cap-profile).
        project: %{"repo_path" => url, "base_branch" => "main"},
        # Numeric forge id → the `<REPO4>` of the deterministic UUID (a stable per-repo Desktop slot).
        repo_id: Spawn.resolve_repo_id(forge, repo, forge_opts),
        # Desktop remote-control name: `<project>_architect` (one slot per project).
        rc_name: name <> "_architect"
      ]

      case spawner.spawn_pod(cap, "architect-" <> repo, spawn_opts) do
        {:ok, _pid} ->
          Logger.info("ProjectArchitect: architect spawned for #{repo} (pod #{pod_id})")
          {:ok, pod_id}

        {:error, {:already_started, _pid}} ->
          Logger.info("ProjectArchitect: architect #{pod_id} already alive — idempotent no-op")
          {:ok, pod_id}

        {:error, reason} = err ->
          Logger.error(
            "ProjectArchitect: architect spawn for #{repo} FAILED (#{inspect(reason)}) — " <>
              "project onboarded, the arch can be relaunched"
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
