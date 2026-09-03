defmodule Fleet.MCP.PodTools.Delegation.Deposits do
  @moduledoc """
  DEPOSIT channel — a project published as a deposit others can install, and the binding that ties
  an installed deposit back to the forge it came from.

  The binding is written on disk and READ back; it is never inferred from a name. Two projects can
  carry the same short name on two forges, and a deposit that guessed its origin would reinstall
  from the wrong one without a word.
  """

  alias Fleet.EventRouter.Bus
  alias Fleet.MCP.PodTools.Delegation.{Gate, Render}
  alias Fleet.MCP.PodTools.ProjectPublish

  @doc """
  ENQUEUES a phase-2 publish of `repo` to its linked external forge (chantier-publication-github).

  Gated behind the onboarder capability, then ASYNC: the actual rail (clone + filter-repo + push +
  PR/MR) runs OFF this call in a `Fleet.MCP.PublishTaskSupervisor` Task — it is O(history) minutes on
  a large repo, so blocking the pod's turn is not an option. Returns
  `{:ok, %{"status" => "queued", "repo" => _}}`
  immediately; the outcome (PR/MR url or failure) arrives later on the Bus as `project_publish.done` /
  `project_publish.failed`. The external token never enters a pod — the rail reads it host-side.

  A project with no publish binding (never `lcars approve`d) is not caught here: the Task resolves the
  binding and emits `project_publish.failed` — the request is well-formed, the target simply is not set.
  """
  @spec project_publish(map(), map()) :: {:ok, map()} | {:error, term()}
  def project_publish(%{"full_name" => repo}, state) when is_binary(repo) do
    case Gate.require_onboarder(state) do
      {:error, reason} ->
        {:error, reason}

      {:ok, _role} ->
        if valid_repo?(repo) do
          # The requesting pod, carried to the worker so its outcome wakes it back (notify_pod via a
          # Spawner-side consumer on project_publish.{done,failed}). nil for a caller without a pod_id.
          requester = Map.get(state, :pod_id)

          case Task.Supervisor.start_child(Fleet.MCP.PublishTaskSupervisor, fn ->
                 ProjectPublish.run(repo, requester)
               end) do
            {:ok, _pid} ->
              # `_ =` DELIBERE : le Bus est le rail LOSSY (doctrine D1), et cet evenement annonce un
              # travail deja lance — le perdre ne change rien a ce qui se passe. `safe_emit` porte
              # deja son propre log d'echec. Ce qui n'est PAS acceptable est de jeter le retour sans
              # le dire : `_ =` est la difference entre « on a choisi » et « on n'a pas regarde ».
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
        else
          {:error, :invalid_arguments}
        end
    end
  end

  def project_publish(_args, _state), do: {:error, :invalid_arguments}

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
  Lists a human's DEPOSIT candidates — the repos they pushed to their personal space that no
  catalogue org already carries.

  The human's login is not a wire parameter: it comes from `Fleet.Credentials.Human.current/0`,
  the same source that owns every issue this fleet creates. A login on the wire would let a caller
  enumerate somebody else's personal space, which is a listing tool wearing an import tool's name.
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
  Lists the human's registered EXTERNAL forges (the pool under `~/.lcars/forges/`, written by
  `lcars forge add`) — onboarder gate, read-only. Lets starfleet PRESENT the forges before proposing a
  publish link. Whether each forge's CLI is authenticated is a SEPARATE host check (`lcars forge
  status`), not this. Returns `{"status":"listed","forges":[{"name","host","dest_host","owner"}, ...]}`.
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
  Links a project to a registered forge — writes its publish binding
  (`~/.lcars/publish/<owner__name>.json`), onboarder gate. This is the REVERSIBLE intent ("this project
  publishes HERE"), NOT the push: nothing goes external until the human's `lcars approve` (first
  populate, the hard host gate) and the PR/MR merge. `repo` = internal `owner/name`; `forge` = a name
  from `list_forges`; `as` = the destination repo name (it becomes `<forge.owner>/<as>` on the forge).
  Fails if the forge is not in the pool. Returns `{"status":"linked","repo":...,"dest":...,"base":...}`.
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

  # The binding key is `ProjectPublish.binding_key/1` — the single source of the org-qualified format
  # the worker and `lcars approve` both use. Mode 600, no token in it (auth is the wired helper).
  defp write_binding(repo, binding) do
    dir = Path.join([System.user_home!(), ".lcars", "publish"])
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{ProjectPublish.binding_key(repo)}.json")

    # ⚠ LE CHMOD EST DANS LA CHAINE, PAS APRES ELLE. Il etait appele et son retour JETE : un fichier
    # ecrit dont la serrure n'a pas pu etre posee ressortait `:ok`, et le binding restait lisible par
    # tout le monde. Le commentaire au-dessus promet « Mode 600 » — c'est cette ligne qui le tient.
    # Meme forme fail-closed que `PodSocketAcceptor.restrict/2` : on ne laisse pas derriere soi une
    # porte sans verrou, on retire ce qu'on n'a pas su fermer.
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
  Adopts a DEPOSITED repo (`<login>/<name>`) into `catalogue`'s org — the third import door.

  The gate lives INSIDE the seam call (foreign `.claude/` refused en bloc, every `CLAUDE.md`
  through the reception filter, default branch normalized): this verb adds no filtering of its own,
  it names the actor, the destination and the FRAMING. The source is not consumed — the human keeps
  their repo.

  The framing (`workflow_map` + criticality) travels like it does on every other creation verb, and
  for the same reason: a project that lands without a declared card gets the default one at C0, and
  the declaration says it was never declared. That is a readable state; a project with no card at
  all is a hole.
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
