defmodule Fleet.Project.Architect do
  @moduledoc """
  Resolves the project delegate's pod ID and ensures its pod is started.
  The role prefix comes from Project.Roles; the project-name segment omits the org,
  so equal names in different orgs produce the same pod ID.

  Spawn options bind live code and ops directories read-only, workshop read-write,
  without a project clone. Workshop is draft space: scratch publication does not
  itself turn notes into a judged deliverable; scribe work goes through the pipeline.
  In-flight PRs and branches are observed through forge tools.

  ensure/2 performs forge/profile work even when the spawner later says already_started.
  ensure_alive/2 first requires an on-disk pod record, then checks tmux liveness:
  the org scan and shared project directories alone do not show that this user
  requested a delegate. A retained snapshot permits restart; removing it stops
  keeper-driven resurrection. This is a record-existence policy, not authentication.

  Options select :spawner, :forge_client, :loader and code/ops/workshop roots.
  The keeper also accepts :pod_tmux, :on_record and snapshot path options.
  """

  require Logger

  alias Fleet.Layout

  @doc """
  Returns <resolved-delegate-role>-<project-name> for owner/name or a bare name.
  It is not a permanent-* fleet pod ID: project opening and the keeper own its
  lifecycle. Delegate resolution uses global configuration/catalogue defaults,
  not repo-specific options, and can raise when resolution fails.
  """
  @spec pod_id_for(String.t()) :: String.t()
  def pod_id_for(repo_or_name) when is_binary(repo_or_name),
    do:
      Fleet.Project.Roles.project_delegate_role() <>
        "-" <> Layout.project_name(repo_or_name)

  @doc """
  Returns :not_ours without a recorded snapshot, :alive for a recorded pod with
  a live tmux session, otherwise calls ensure/2. It resolves the pod ID before
  checking the record. Liveness uses tmux rather than Registry membership, which
  can outlast a lost session. Errors from injected callbacks are not rescued.
  """
  @spec ensure_alive(String.t(), keyword()) ::
          {:ok, String.t() | :alive | :not_ours} | {:error, term()}
  def ensure_alive(repo, opts \\ []) when is_binary(repo) and is_list(opts) do
    tmux = Keyword.get(opts, :pod_tmux, Fleet.Spawner.PodTmux)
    recorded? = Keyword.get(opts, :on_record, &on_record?/2)
    pod_id = pod_id_for(repo)

    cond do
      # Record gate precedes tmux and forge calls; shared project directories are insufficient.
      not recorded?.(repo, opts) -> {:ok, :not_ours}
      tmux.alive?(pod_id) -> {:ok, :alive}
      true -> ensure(repo, opts)
    end
  end

  @doc """
  Delegates to Spawner.snapshot_on_record?/2: checks for a regular state.json
  under the selected state root, without parsing its content or checking liveness.
  An unreadable root returns false. Defaults use the user's state location;
  explicit path options can select another root.
  """
  @spec on_record?(String.t(), keyword()) :: boolean()
  def on_record?(repo, opts \\ []) when is_binary(repo) and is_list(opts),
    do: Fleet.Spawner.snapshot_on_record?(pod_id_for(repo), opts)

  @doc """
  Requests a spawn and treats {:already_started, pid} as success, returning pod_id.
  Resolves the forge repo ID before checking that all three mount directories exist;
  a missing directory takes precedence over a returned forge error. Other returned
  forge/profile/spawn errors propagate. Callers choose whether failure is fatal;
  this function does not rescue exceptions or schedule its own retry.
  """
  @spec ensure(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def ensure(repo, opts \\ []) when is_binary(repo) and is_list(opts) do
    spawner = Keyword.get(opts, :spawner, Fleet.Spawner)
    forge = Keyword.get(opts, :forge_client, Fleet.Forge.Client)
    loader = Keyword.get(opts, :loader, Fleet.CapProfile)
    forge_opts = Keyword.take(opts, [:token, :base_url])

    name = Layout.project_name(repo)
    proj_dir = Path.join(Keyword.get(opts, :code_root, Layout.code_root()), name)
    work_dir = Path.join(Keyword.get(opts, :ops_root, Layout.ops_root()), name)
    doc_dir = Path.join(Keyword.get(opts, :workshop_root, Layout.workshop_root()), name)
    repo_id_result = Fleet.Forge.repo_id(forge, repo, forge_opts)

    cond do
      # bwrap requires mount sources to exist; identify incomplete onboarding here.
      missing = Enum.find([proj_dir, work_dir, doc_dir], &(not File.dir?(&1))) ->
        {:error, {:not_onboarded, missing}}

      match?({:error, _}, repo_id_result) ->
        {:error, reason} = repo_id_result

        Logger.error(
          "Project.Architect: repo id unresolved for #{repo} (#{inspect(reason)}) — arch NOT ensured"
        )

        {:error, {:repo_id_unresolved, repo, reason}}

      true ->
        spawn_architect(
          repo,
          name,
          repo_id_result,
          {proj_dir, work_dir, doc_dir},
          spawner,
          loader
        )
    end
  end

  # Workshop is the only writable face; LaunchSpec uses the first writable mount
  # as a cwd fallback. Mount deduplication also keeps the first occurrence of a path.
  defp spawn_architect(repo, name, {:ok, repo_id}, {proj_dir, work_dir, doc_dir}, spawner, loader) do
    # Resolve the delegate capability through the same role authority used by callers.
    case Fleet.CapProfile.resolve(loader, Fleet.Project.Roles.project_delegate_role()) do
      {:ok, cap} ->
        pod_id = pod_id_for(name)

        spawn_opts = [
          pod_id: pod_id,
          # MCP tools infer the bound project from pod channel identity.
          repo: repo,
          repo_id: repo_id,
          rc_name: Layout.pod_label(name, "architect"),
          project_slug: name,
          mounts: [
            %{"mode" => "ro", "path" => proj_dir},
            %{"mode" => "ro", "path" => work_dir},
            %{"mode" => "rw", "path" => doc_dir}
          ]
        ]

        architect_spawn_outcome(spawner.spawn_pod(cap, pod_id, spawn_opts), repo, pod_id)

      {:error, reason} = err ->
        Logger.error(
          "Project.Architect: architect cap-profile load/compose failed (#{inspect(reason)})"
        )

        err
    end
  end

  defp architect_spawn_outcome({:ok, _pid}, repo, pod_id) do
    Logger.info("Project.Architect: architect ensured for #{repo} (pod #{pod_id}, spawned)")
    {:ok, pod_id}
  end

  defp architect_spawn_outcome({:error, {:already_started, _pid}}, _repo, pod_id),
    do: {:ok, pod_id}

  defp architect_spawn_outcome({:error, reason} = err, repo, _pod_id) do
    Logger.error(
      "Project.Architect: architect spawn for #{repo} FAILED (#{inspect(reason)}) — " <>
        "retried on the next open/escalation trigger"
    )

    err
  end
end
