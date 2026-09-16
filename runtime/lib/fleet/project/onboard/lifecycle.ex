defmodule Fleet.Project.Onboard.Lifecycle do
  @moduledoc """
  Lists, opens, parks and deletes local projects.
  Parking records forge marker issues while retaining project files. Deletion removes the
  forge repo first, then checks each local face for a matching parsed origin or empty debris.
  """

  alias Fleet.Forge.Client, as: ForgeClient
  alias Fleet.Forge.Protocol
  alias Fleet.Project.GitOps
  alias Fleet.Project.Onboard
  alias Fleet.Project.Onboard.Faces
  alias Fleet.Project.Onboard.Repo

  require Logger

  # Listing assigns opts[:org] or the first installed catalogue (fallback fleet) to every entry.
  # It does not read origins: mixed-catalogue directories can be labelled with the wrong repo,
  # and parking is then queried using that wrong key.
  defp listing_org_placeholder do
    case Onboard.installed_orgs() do
      [org | _] -> org
      [] -> Fleet.Catalogue.bundled_name()
    end
  end

  @doc """
  Opens a project after checking that all three local directories exist.
  Origins and branch contents are not verified. Closes all parked markers before architect
  ensure; a later close failure leaves earlier markers closed. Returns the common project result.
  """
  @spec open(String.t(), keyword()) :: {:ok, Onboard.result()} | {:error, term()}
  def open(full_name, opts \\ []) when is_binary(full_name) do
    name = Fleet.Layout.project_name(full_name)
    dirs = Faces.face_dirs(name, opts)

    with :ok <- Onboard.validate_name(name),
         :ok <- require_all_faces_on_machine(full_name, dirs),
         :ok <- unpark(full_name, opts) do
      result = Onboard.onboard_result(full_name, dirs, opts)
      Logger.info("ProjectOnboard: #{full_name} opened — architect #{result.architect.status}")
      {:ok, result}
    end
  end

  defp unpark(full_name, opts) do
    forge = forge_issues(opts)

    case forge.list_open_issues(full_name, Repo.fc_opts(opts)) do
      {:ok, issues} ->
        issues
        |> Enum.filter(&Protocol.parked_issue_title?(&1["title"]))
        |> close_markers(full_name, forge, opts)

      {:error, reason} ->
        {:error, {:unpark_failed, {:parked_state_unreadable, reason}}}
    end
  end

  defp close_markers([], _full_name, _forge, _opts), do: :ok

  defp close_markers(markers, full_name, forge, opts) do
    Enum.reduce_while(markers, :ok, fn %{"number" => n}, :ok ->
      # Marker closure must not stamp stage labels that would turn parking state into work.
      case forge.close_issue(full_name, n, Keyword.put(Repo.fc_opts(opts), :closure, :marker)) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:unpark_failed, {n, reason}}}}
      end
    end)
    |> case do
      :ok ->
        Logger.info("ProjectOnboard: #{full_name} UNPARKED (#{length(markers)} marker(s) closed)")

        :ok

      err ->
        err
    end
  end

  # Issue operations have a separate seam from forge_repo provisioning.
  defp forge_issues(opts), do: Keyword.get(opts, :forge_issues, ForgeClient)

  @doc """
  Lists sorted directories under code_root, without requiring Git or a project declaration.
  Uses opts[:org] or the listing placeholder for every repo identity, not its Git origin.

  Reports the stored card as declared/undeclared/invalid/unreadable, without resolving a
  fallback or recording Declaration reader incidents. A binary pipeline_default is accepted
  without loading the card. Reads parking from forge marker issues; failed reads produce
  unknown plus state_error, never a confident open.
  """
  @spec list_projects(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_projects(opts \\ []) do
    root = Faces.code_root(opts)

    case File.ls(root) do
      {:ok, entries} ->
        projects =
          entries
          |> Enum.filter(&File.dir?(Path.join(root, &1)))
          |> Enum.sort()
          |> Enum.map(&describe_project(&1, root, opts))

        {:ok, projects}

      {:error, reason} ->
        {:error, {:code_root_unreadable, root, reason}}
    end
  end

  @doc """
  Returns integer issue numbers from the current human's assigned open-issue listing,
  excluding parked markers. Closing a marker would reopen the project instead of stopping it.
  Kept in Project so MCP does not duplicate the forge protocol vocabulary.
  """
  @spec list_stoppable_issues(String.t(), keyword()) :: {:ok, [integer()]} | {:error, term()}
  def list_stoppable_issues(full_name, opts \\ []) when is_binary(full_name) do
    with {:ok, human} <- Fleet.Credentials.Human.current(),
         {:ok, issues} <-
           forge_issues(opts).list_open_issues(
             full_name,
             Keyword.put(Repo.fc_opts(opts), :assigned_by, human)
           ) do
      numbers =
        issues
        |> Enum.reject(&Protocol.parked_issue_title?(&1["title"]))
        |> Enum.map(&Map.get(&1, "number"))
        |> Enum.filter(&is_integer/1)

      {:ok, numbers}
    end
  end

  defp describe_project(name, root, opts) do
    full_name = "#{Keyword.get(opts, :org) || listing_org_placeholder()}/#{name}"

    %{"name" => name, "repo" => full_name}
    |> Map.merge(declaration_facts(Path.join(root, name)))
    |> Map.merge(parked_state(full_name, opts))
  end

  defp declaration_facts(proj_dir) do
    case File.read(Path.join(proj_dir, Fleet.Layout.project_declaration_file())) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, %{"pipeline_default" => card} = decl} when is_binary(card) ->
            %{
              "card" => card,
              "card_source" => "declared",
              "declared_by" => Map.get(decl, "declared_by")
            }

          _ ->
            %{"card" => nil, "card_source" => "invalid"}
        end

      {:error, :enoent} ->
        %{"card" => nil, "card_source" => "undeclared"}

      {:error, reason} ->
        %{
          "card" => nil,
          "card_source" => "unreadable",
          "card_error" => "#{:file.format_error(reason)}"
        }
    end
  end

  defp parked_state(full_name, opts) do
    case forge_issues(opts).list_open_issues(full_name, Repo.fc_opts(opts)) do
      {:ok, issues} ->
        parked? = Enum.any?(issues, &Protocol.parked_issue_title?(&1["title"]))
        %{"state" => if(parked?, do: "parked", else: "open")}

      {:error, reason} ->
        %{"state" => "unknown", "state_error" => inspect(reason)}
    end
  end

  @doc """
  Parks a project by creating a marker issue assigned to the current human, then stopping
  its architect. Existing markers avoid a second create but still retry the stop.
  Requires the main directory's parsed origin to match owner/name; host is not compared.

  In-flight workers are not stopped. The marker is written before architect stop, but this
  does not synchronize with a poller's already-read state. Stop exceptions/exits become an
  error outcome without undoing the marker. Reopen through project_open or by closing
  the marker in the forge UI.
  """
  @spec close_project(String.t(), keyword()) :: {:ok, Onboard.close_result()} | {:error, term()}
  def close_project(full_name, opts \\ []) when is_binary(full_name) do
    name = Fleet.Layout.project_name(full_name)
    proj_dir = Path.join(Faces.code_root(opts), name)
    forge = forge_issues(opts)

    with :ok <- Onboard.validate_name(name),
         :ok <- Onboard.require_on_machine(full_name, proj_dir),
         :ok <- require_proven_identity(full_name, proj_dir, opts),
         {:ok, issues} <- read_parked_state(forge, full_name, opts) do
      if Enum.any?(issues, &Protocol.parked_issue_title?(&1["title"])) do
        {:ok,
         %{
           repo: full_name,
           outcome: :already_closed,
           architect: stop_architect(full_name, opts)
         }}
      else
        do_close(full_name, forge, opts)
      end
    end
  end

  defp require_proven_identity(full_name, proj_dir, opts) do
    if Repo.origin_full_name(proj_dir, opts) == {:ok, full_name},
      do: :ok,
      else: {:error, {:identity_unproven, full_name}}
  end

  defp read_parked_state(forge, full_name, opts) do
    case forge.list_open_issues(full_name, Repo.fc_opts(opts)) do
      {:ok, issues} -> {:ok, issues}
      {:error, reason} -> {:error, {:close_failed, {:parked_state_unreadable, reason}}}
    end
  end

  defp do_close(full_name, forge, opts) do
    case Fleet.Credentials.Human.current() do
      {:ok, human} ->
        issue_opts = Keyword.put(Repo.fc_opts(opts), :assignees, [human])
        title = Protocol.parked_issue_title()

        case forge.create_issue(full_name, title, parked_marker_body(), issue_opts) do
          {:ok, n} ->
            arch = stop_architect(full_name, opts)

            Logger.info("ProjectOnboard: #{full_name} CLOSED (marker ##{n}) — architect #{arch}")

            {:ok, %{repo: full_name, outcome: :closed, marker_issue: n, architect: arch}}

          {:error, reason} ->
            {:error, {:close_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:close_failed, {:human_unresolved, inspect(reason)}}}
    end
  end

  defp parked_marker_body do
    "Projet fermé par la fleet (`project_close`) — le rail ne dispatche plus de ticket ici.\n\n" <>
      "Réouverture : fermer CE ticket relance le rail (l'architecte revient de lui-même à la " <>
      "première escalade) ; `project_open` fait la réouverture complète et immédiate."
  end

  @doc """
  Deletes the forge repository, then requests worker cleanup and removes eligible local faces.
  Requires a truthy force option. A failed forge probe/deletion returns before local cleanup.

  A matching parsed owner/name origin admits removal without comparing hosts. If the origin
  read fails, deletion requires no entries besides .git and an empty commit query; commit-query
  errors count as no commits. This is a heuristic, not proof against unreadable Git history.

  Architect stop runs only if at least one local face was removed, including empty debris.
  Local removal/stop failures do not undo forge deletion. Worker sweep errors may appear as
  zero killed; its exit signals are not caught by the sweep helper.
  """
  @spec delete_project(String.t(), keyword()) :: {:ok, Onboard.delete_result()} | {:error, term()}
  def delete_project(full_name, opts \\ []) when is_binary(full_name) do
    name = Fleet.Layout.project_name(full_name)
    dirs = Faces.face_dirs(name, opts)

    with :ok <- Onboard.validate_name(name),
         :ok <- require_force(full_name, opts),
         {:ok, forge} <- Repo.delete_forge(full_name, opts) do
      # Request worker cleanup before removing their project faces; forge deletion already happened.
      pods = kill_project_workers(full_name, opts)

      proj = nuke_if_is(full_name, dirs.code, opts)
      ops = nuke_if_is(full_name, dirs.ops, opts)
      workshop = nuke_if_is(full_name, dirs.workshop, opts)

      architect =
        if :removed in [proj, ops, workshop],
          do: stop_architect(full_name, opts),
          else: :skipped_identity

      Logger.info(
        "ProjectOnboard: DELETE #{full_name} — forge #{forge}, architect #{architect}, " <>
          "workers #{pods.killed}, project_dir #{proj}, ops_dir #{ops}, workshop_dir #{workshop}"
      )

      {:ok,
       %{
         repo: full_name,
         forge: forge,
         architect: architect,
         workers_killed: pods.killed,
         project_dir: dirs.code,
         work_dir: dirs.ops,
         doc_dir: dirs.workshop,
         local: %{project: proj, ops: ops, workshop: workshop}
       }}
    end
  end

  defp nuke_if_is(full_name, dir, opts) do
    if File.exists?(dir),
      do: nuke_proven(full_name, dir, Repo.origin_full_name(dir, opts)),
      else: :absent
  end

  defp nuke_proven(full_name, dir, {:ok, origin}) when origin == full_name, do: remove_proven(dir)

  defp nuke_proven(full_name, dir, {:ok, _elsewhere}),
    do: keep_unproven(full_name, dir, "its git origin does not resolve to #{full_name}")

  defp nuke_proven(full_name, dir, {:error, _no_origin}) do
    if empty_debris?(dir) do
      Logger.info(
        "ProjectOnboard: DELETE #{full_name} — removed #{dir}: no git origin and provably empty " <>
          "(no commit, nothing beside .git) — onboard debris, never a project"
      )

      remove_proven(dir)
    else
      keep_unproven(full_name, dir, "it has no readable git origin and is not empty")
    end
  end

  defp remove_proven(dir) do
    case Faces.nuke_dir(dir) do
      :ok -> :removed
      {:error, _} -> :removal_incomplete
    end
  end

  defp keep_unproven(full_name, dir, why) do
    Logger.warning(
      "ProjectOnboard: DELETE #{full_name} — KEPT #{dir}: #{why} " <>
        "(homonym or unprovable). A basename collision must never nuke another project."
    )

    :kept_identity_unproven
  end

  defp empty_debris?(dir), do: no_commit?(dir) and bare_of_content?(dir)

  defp no_commit?(dir) do
    case GitOps.read(["-C", dir, "rev-list", "-n", "1", "--all"]) do
      {:ok, out} -> out == ""
      {:error, _} -> true
    end
  end

  defp bare_of_content?(dir) do
    case File.ls(dir) do
      {:ok, entries} -> entries -- [".git"] == []
      {:error, _} -> false
    end
  end

  defp require_force(full_name, opts) do
    if Keyword.get(opts, :force, false), do: :ok, else: {:error, {:force_required, full_name}}
  end

  # Continue after returned errors or rescued exceptions; exits are not caught here.
  defp kill_project_workers(full_name, opts) do
    spawner = Keyword.get(opts, :spawner, Fleet.Spawner)

    case spawner.kill_project_pods(full_name) do
      {:ok, report} -> report
      other -> %{killed: 0, pod_ids: [], error: other}
    end
  rescue
    e ->
      Logger.warning(
        "ProjectOnboard: delete could not sweep the workers of #{full_name}: #{inspect(e)}"
      )

      %{killed: 0, pod_ids: []}
  end

  defp stop_architect(full_name, opts) do
    spawner = Keyword.get(opts, :spawner, Fleet.Spawner)
    pod_id = Fleet.Project.Architect.pod_id_for(full_name)

    case spawner.kill_pod(pod_id) do
      :ok -> :stopped
      {:error, :not_found} -> :none
    end
  rescue
    e ->
      Logger.warning(
        "ProjectOnboard: delete could not stop architect #{full_name}: #{inspect(e)}"
      )

      :error
  catch
    :exit, _ ->
      Logger.warning("ProjectOnboard: delete architect stop exited (#{full_name})")
      :error
  end

  # Require workshop too, so open does not hand the architect a missing writable path.
  defp require_all_faces_on_machine(full_name, dirs) do
    if Enum.all?([dirs.code, dirs.ops, dirs.workshop], &File.dir?/1),
      do: :ok,
      else: {:error, {:not_on_machine, full_name}}
  end
end
