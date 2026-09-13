defmodule Fleet.MCP.PodTools.Delegation.Deposits do
  @moduledoc """
  Onboarder operations for personal deposit imports and external publish bindings.
  Persist/read the chosen origin rather than inferring it from a short project name.
  """

  alias Fleet.EventRouter.Bus
  alias Fleet.MCP.PodTools.Delegation.{Gate, Render}
  alias Fleet.MCP.PodTools.ProjectPublish

  @doc """
  Queues a publish task after the onboarder gate and owner/name shape check.
  Returns queued after task start; completion/failure arrives on the lossy Bus with
  requester identity. Missing bindings are detected by the worker, not this call.
  Publication runs host-side so history rewriting does not block the tool turn.
  """
  @spec project_publish(map(), map()) :: {:ok, map()} | {:error, term()}
  def project_publish(%{"full_name" => repo}, state) when is_binary(repo) do
    case Gate.require_onboarder(state) do
      {:error, reason} ->
        {:error, reason}

      {:ok, _role} ->
        if valid_repo?(repo),
          do: enqueue_publish(repo, Map.get(state, :pod_id)),
          else: {:error, :invalid_arguments}
    end
  end

  def project_publish(_args, _state), do: {:error, :invalid_arguments}

  # Carry the requesting pod id into the completion event consumed by Spawner.
  defp enqueue_publish(repo, requester) do
    case Task.Supervisor.start_child(Fleet.MCP.PublishTaskSupervisor, fn ->
           ProjectPublish.run(repo, requester)
         end) do
      {:ok, _pid} ->
        # The task is already started; losing this observability event does not cancel it.
        _ =
          Bus.safe_emit(
            :mcp,
            :"project_publish.started",
            [payload: %{"repo" => repo, "requester_pod_id" => requester}],
            context: "project_publish"
          )

        {:ok, %{"status" => "queued", "repo" => repo}}

      {:error, reason} ->
        {:error, {:publish_enqueue_failed, reason}}
    end
  end

  # owner/name, exactly two non-empty segments, no path-traversal component.
  defp valid_repo?(repo) do
    case String.split(repo, "/") do
      [owner, name] ->
        owner != "" and name != "" and owner not in ~w(. ..) and name not in ~w(. ..)

      _ ->
        false
    end
  end

  @doc """
  Lists deposit candidates from the configured human's personal space through Onboard.
  The login comes from Human.current, never a wire argument naming another person.
  """
  @spec list_deposits(map()) :: {:ok, map()} | {:error, term()}
  def list_deposits(state) do
    with {:ok, _role} <- Gate.require_onboarder(state),
         {:ok, onboard} <- Gate.conforming_onboard(),
         {:ok, human} <- Fleet.Credentials.Human.current() do
      case onboard.deposit_candidates(human, []) do
        {:ok, candidates} ->
          {:ok, %{"status" => "listed", "human" => human, "candidates" => candidates}}

        {:error, reason} ->
          {:error, {:deposit_scan_failed, inspect(reason)}}
      end
    end
  end

  @doc """
  Lists ~/.lcars/forges JSON registrations, sorted by filename, behind the onboarder gate.
  Directory read errors yield an empty list; unreadable/invalid files are skipped.
  Entry fields can be nil. CLI authentication is a separate lcars forge status check.
  """
  @spec list_forges(map()) :: {:ok, map()} | {:error, term()}
  def list_forges(state) do
    with {:ok, _role} <- Gate.require_onboarder(state) do
      dir = Path.join([System.user_home!(), ".lcars", "forges"])

      forges =
        case File.ls(dir) do
          {:ok, files} ->
            files
            |> Enum.filter(&String.ends_with?(&1, ".json"))
            |> Enum.sort()
            |> Enum.flat_map(&read_forge_entry(dir, &1))

          {:error, _} ->
            []
        end

      {:ok, %{"status" => "listed", "forges" => forges}}
    end
  end

  defp read_forge_entry(dir, file) do
    with {:ok, raw} <- File.read(Path.join(dir, file)),
         {:ok, m} when is_map(m) <- Jason.decode(raw) do
      [
        %{
          "name" => String.replace_suffix(file, ".json", ""),
          "host" => m["host"],
          "dest_host" => m["dest_host"],
          "owner" => m["owner"]
        }
      ]
    else
      _ -> []
    end
  end

  @doc """
  Writes or overwrites a publish binding for a registered forge, behind the onboarder gate.
  full_name is the internal owner/name; as forms <forge.owner>/<as> at the destination.
  Currently pins base to main without destination discovery or validation of as.
  This call does not push. The later rail requires a destination base head, but
  there is no approval receipt checked here or by the worker.
  """
  @spec publish_link(map(), map()) :: {:ok, map()} | {:error, term()}
  def publish_link(%{"full_name" => repo, "forge" => forge_name, "as" => as}, state)
      when is_binary(repo) and is_binary(forge_name) and is_binary(as) do
    with {:ok, _role} <- Gate.require_onboarder(state),
         true <- valid_repo?(repo),
         {:ok, forge} <- read_forge(forge_name),
         dest_repo = "#{forge["owner"]}/#{as}",
         binding = %{
           "host" => forge["host"],
           "dest_host" => forge["dest_host"],
           "dest_repo" => dest_repo,
           "base" => "main"
         },
         :ok <- write_binding(repo, binding) do
      {:ok,
       %{
         "status" => "linked",
         "repo" => repo,
         "dest" => "#{forge["dest_host"]}/#{dest_repo}",
         "base" => "main"
       }}
    else
      false -> {:error, :invalid_repo}
      {:error, _} = err -> err
    end
  end

  def publish_link(_bad, _state), do: {:error, :invalid_arguments}

  # Forge names are filename components: reject traversal (same guard shape as `lcars forge add`).
  defp read_forge(name) do
    if name =~ ~r/^[a-z0-9][a-z0-9_-]*$/ do
      path = Path.join([System.user_home!(), ".lcars", "forges", "#{name}.json"])

      with {:ok, raw} <- File.read(path),
           {:ok, m} when is_map(m) <- Jason.decode(raw),
           true <- is_binary(m["host"]) and is_binary(m["dest_host"]) and is_binary(m["owner"]) do
        {:ok, m}
      else
        _ -> {:error, {:forge_unknown, name}}
      end
    else
      {:error, {:forge_name_invalid, name}}
    end
  end

  # Share ProjectPublish's org-qualified filename encoding. Binding contains no token.
  defp write_binding(repo, binding) do
    dir = Path.join([System.user_home!(), ".lcars", "publish"])
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{ProjectPublish.binding_key(repo)}.json")

    # Chmod failure is an error and triggers attempted removal. This is not an atomic
    # replacement: writing can overwrite an existing binding before chmod, and removal can fail.
    with {:ok, json} <- Jason.encode(binding, pretty: true),
         :ok <- File.write(path, json),
         :ok <- File.chmod(path, 0o600) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(path)
        {:error, {:binding_write_failed, inspect(reason)}}
    end
  end

  @doc """
  Imports a personal repository into the requested catalogue through Onboard.
  Forwards justification, workflow_map and the resolved acting role; reception
  filtering and source preservation belong to Onboard. Returns source and face paths.
  This adapter forwards no separate criticality field.
  """
  @spec import_deposit(String.t(), String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def import_deposit(source, catalogue, args, state)
      when is_binary(source) and is_binary(catalogue) and is_map(args) do
    with {:ok, role} <- Gate.require_onboarder(state),
         {:ok, onboard} <- Gate.conforming_onboard() do
      opts = [
        justification: Map.get(args, "justification"),
        workflow_map: Map.get(args, "workflow_map"),
        onboarded_by: role
      ]

      case onboard.import_deposit(source, catalogue, opts) do
        {:ok, %{repo: repo, project_dir: pdir, work_dir: wdir, doc_dir: ddir} = result} ->
          {:ok,
           %{
             "status" => "imported",
             "repo" => repo,
             "from" => source,
             "project_dir" => pdir,
             "work_dir" => wdir,
             "doc_dir" => ddir,
             "delegation_target" => repo
           }
           |> Render.put_architect(result)}

        {:error, reason} ->
          {:error, {:deposit_import_failed, inspect(reason)}}
      end
    end
  end
end
