defmodule Fleet.Project.Onboard.Lifecycle do
  @moduledoc """
  Ce qui arrive a un projet APRES son entree : le rouvrir, l'enumerer, le parquer, le supprimer.

  `close_project/2` PARQUE — le materiel reste, un marqueur dit que le projet dort — la ou
  `delete_project/2` detruit, et n'accepte de le faire que sur des preuves : un depot dont l'origin
  prouve l'identite, ou un arbre prouve vide. Il n'y a pas de `rm` de confiance dans ce fichier.
  """

  alias Fleet.Forge.Client, as: ForgeClient
  alias Fleet.Forge.Protocol
  alias Fleet.Project.GitOps
  alias Fleet.Project.Onboard
  alias Fleet.Project.Onboard.Faces
  alias Fleet.Project.Onboard.Repo

  require Logger

  # Le defaut vaut le PREMIER catalogue installe, toujours celui du release : il vit dedans, donc il
  # est installe par construction et en tete. Un deploiement qui apporte le sien nomme son org au
  # guichet, ce qui est le geste voulu — un defaut ne devine pas quel metier l'appelant visait.
  #
  # ⚖ L'org d'un projet est fixee POUR SA VIE : elle s'ENONCE, elle ne se devine pas. Les verbes
  # d'entree l'exigent donc tous.
  #
  # ⚠ DEFAUT CONNU, MESURE, NON CORRIGE ICI : `describe_project/3` recoit `[]` de ses deux
  # appelants, donc tout projet est etiquette sous l'org du catalogue racine — y compris ceux d'un
  # AUTRE catalogue — et l'etat de parking est ensuite interroge avec cette mauvaise cle. La bonne
  # source est l'ORIGINE git du projet, qu'aucun lecteur de ce depot ne lit encore.
  defp listing_org_placeholder do
    case Onboard.installed_orgs() do
      [org | _] -> org
      [] -> "fleet"
    end
  end

  @doc """
  Opens a project already present on the machine.

  All parked markers must be read and closed before the per-project architect is ensured. Missing
  local faces or an unreadable/unclosable parked state are refusals. Returns the common project
  result shape used by `onboard/2` and `import/2`.
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

  # BL-6-30
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
      # `closure: :marker` — ce ne sont PAS des tickets mais les marqueurs de parking de l'onboard :
      # rien a estampiller, et surtout pas un `stage/*` qui les ferait ressembler a du travail.
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

  # Issue-side forge seam of the close/open verbs (the repo seam `:forge_repo` carries only the
  # provisioning ops). Default = the real client; injectable for tests.
  defp forge_issues(opts), do: Keyword.get(opts, :forge_issues, ForgeClient)

  @doc """
  Enumerates the projects on this box, with what governs each one.

  The onboarder can `create`, `open`, `import`, `adopt`, `close`, `revise` and `delete` a project.
  Without this verb it could destroy a project it had no way to name. A pure read — the only
  listing in the delegation surface that writes nothing.

  Enumerated from DISK (`code_root`), which is what "this fleet's projects" means: a repo on
  the forge that was never cloned here is not something this box can act on, and a disk project not
  yet published is precisely what `project_adopt` exists for.

  Per project, three facts and no derivation:

    * the DECLARED card (`.lcars.json`), reported as declared or NOT — criticality IS the card,
      no separate level field. An undeclared
      project falls back to the fleet default at burn time, and that fallback is deliberately NOT
      applied here: reporting the effective card would make an undeclared project indistinguishable
      from one that declared the default on purpose, and `ProjectDeclaration.pipeline_default/2`
      records an INCIDENT on the invalid path — a listing must not have side effects.
    * the STATE, read from the forge: an open parked-marker issue is the state machine
      (`project_close`'s own truth, not a second reading of it).
    * `state: "unknown"` with `state_error` when that forge read fails. Never a silent "open" — an
      unreadable state and a running project must not look the same to the actor that can delete
      either one.
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
  The open tickets of `full_name` that this fleet would act on — the scope an emergency stop closes.

  Lives here and not on the caller's side for the same reason `list_projects/1` does: "which tickets
  is the fleet working on" is composed of two facts that belong to this domain — the poller's own
  scoping (issues assigned to the human owner) and the parked-marker vocabulary. Re-deriving either
  MCP-side would put a second authority next to the one that creates and closes them, and MCP cannot
  reference the forge protocol at all (upward boundary).

  The PARKED MARKER IS EXCLUDED, and it is not a detail: that marker is an open issue assigned to
  the same human, and closing it means UNPARKING the project. A brake that reopens a deliberately
  closed project does the opposite of stopping.
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

  # What the project DECLARES, never what it would fall back to.
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
  CLOSES a project (BL-6-30) — the verb between `open` and `delete`: stops the fleet ON this
  project while disk and forge stay intact. The closed state is a FORGE OBJECT (the forge IS
  the state machine): an OPEN marker issue (`ForgeProtocol.parked_issue_title/0`, assignee =
  the human — the same fixed point `issue_create` uses, and REQUIRED for the poller's
  `assigned_by` scoping to see it). The poller reads it in the per-repo listing it already
  does and skips the whole step rail; the marker is posted BEFORE the architect stops, so a
  tick between the two gestures dispatches nothing. In-flight workers are NOT reaped — the
  running brick finishes, the skip stops the NEXT one (same philosophy as the lease). Reopen:
  `project_open` (immediate, closes the marker(s) then ensures the architect), or the human
  closing the marker in the forge UI (a LEGITIMATE unpark — the rail resumes, and the
  architect self-respawns at the first pending escalation via the ArchWake net).

  Identity preflight at the delete standard (proj_dir's git origin must PROVE `full_name` — a
  basename homonym is never the project we close); already parked → honest no-op
  (`outcome: :already_closed`, the architect stop still converges). The architect stop is
  best-effort (`:stopped` / `:none` / `:error` — a spawner hiccup never fails the close: the
  MARKER is the state, and it is already posted).
  """
  @spec close_project(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
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
  Deletes a project's forge repository and proven local runtime footprint. `CI-07`

  `force: true` is mandatory. A forge outage refuses the operation. Each local directory is removed
  only when its origin resolves to `full_name`, or when it has no origin and is proven empty of both
  commits and content; ambiguous state is kept. The architect is stopped only after local ownership
  is proven. Local removal and architect-stop failures are reported but do not reverse a decided forge
  deletion.
  """
  @spec delete_project(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def delete_project(full_name, opts \\ []) when is_binary(full_name) do
    name = Fleet.Layout.project_name(full_name)
    dirs = Faces.face_dirs(name, opts)

    with :ok <- Onboard.validate_name(name),
         :ok <- require_force(full_name, opts),
         {:ok, forge} <- Repo.delete_forge(full_name, opts) do
      # THE WORKERS DIE BEFORE THEIR WORLD DOES. Stop the architect alone and an engineer in flight
      # outlives the removal of its own project: its workspace still exists, so it does not even
      # crash — it keeps reading a reference that is no longer there and carries on.
      # Killed FIRST, before the faces go: a pod losing its world mid-read has nothing to say about
      # it, whereas one killed outright is indistinguishable from a crash, which the reconciliation
      # is built to handle.
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
         # REPORTED, because a deletion that cost work in flight must not read as free. The caller
         # relays this to a human who may not know anything was running.
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

  # Best-effort like `stop_architect/2` below, and for the same reason: the faces are already
  # committed to going. A sweep that failed must not turn a deletion into a half-state.
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

  # ALL THREE faces, and the doc one is not optional here: `open` is what hands a project to the
  # architect, whose producer path is on `doc`. Opening a project whose doc face never landed would
  # succeed and then fail at the first documentary ticket, far from the cause.
  defp require_all_faces_on_machine(full_name, dirs) do
    if Enum.all?([dirs.code, dirs.ops, dirs.workshop], &File.dir?/1),
      do: :ok,
      else: {:error, {:not_on_machine, full_name}}
  end
end
