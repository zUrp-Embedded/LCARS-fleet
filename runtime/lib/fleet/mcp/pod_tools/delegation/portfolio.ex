defmodule Fleet.MCP.PodTools.Delegation.Portfolio do
  @moduledoc """
  Onboarder-gated project lifecycle and catalogue/card operations.
  Targets are explicit portfolio arguments; Onboard owns filesystem and forge mechanics.
  Card discovery uses Loader and Catalogue so offered identities match runtime loading.
  """

  require Logger

  alias Fleet.Catalogue
  alias Fleet.MCP.PodTools.Delegation.{Gate, Render}
  alias Fleet.MCP.PodTools.ProjectPublish
  alias Fleet.Workflow.Loader

  @doc """
  Creates a project through the onboarding seam after the server-side gate.
  """
  @spec create_project(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def create_project(name, args, state) when is_binary(name) and is_map(args) do
    case Gate.require_onboarder(state) do
      {:error, reason} -> {:error, reason}
      {:ok, role} -> do_create_project(name, args, role)
    end
  end

  @doc """
  Imports an existing project through the onboarding seam without scaffolding its main content.
  """
  @spec import_project(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def import_project(full_name, state) when is_binary(full_name) do
    case Gate.require_onboarder(state) do
      {:error, reason} -> {:error, reason}
      {:ok, _role} -> do_import_project(full_name)
    end
  end

  @doc """
  Deletes through Onboard after the boolean deployment switch and onboarder gate.
  The adapter converts force to a boolean before forwarding; the default requires it.
  Onboard owns forge/worker/face teardown and returns partial local outcomes. After
  a successful result, publish-binding removal is attempted and failures are logged.
  """
  # Deployment availability is separate from force. Check this switch before the
  # capability gate and return delete_project_disabled when it is not explicitly true.
  @delete_flag :mcp_allow_delete_project

  @spec delete_project(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def delete_project(full_name, args, state) when is_binary(full_name) and is_map(args) do
    if delete_armed?() do
      case Gate.require_onboarder(state) do
        {:error, reason} -> {:error, reason}
        {:ok, _role} -> do_delete_project(full_name, args)
      end
    else
      Logger.warning(
        "Delegation: delete_project(#{full_name}) REFUSED — disarmed by deployment " <>
          "(config :lcars_fleet, #{inspect(@delete_flag)} is not true)"
      )

      {:error, :delete_project_disabled}
    end
  end

  # Reject truthy non-booleans so an accidental configuration value cannot arm deletion.
  defp delete_armed?, do: Application.get_env(:lcars_fleet, @delete_flag, false) === true

  @doc """
  Lists projects through Onboard, the owner of local layout and parked-state reads.
  Returns projects plus count rather than reconstructing existence in MCP.
  """
  @spec list_projects(map()) :: {:ok, map()} | {:error, term()}
  def list_projects(state) do
    with {:ok, _role} <- Gate.require_onboarder(state),
         {:ok, onboard} <- Gate.conforming_onboard(),
         {:ok, projects} <- onboard.list_projects([]) do
      {:ok, %{"projects" => projects, "count" => length(projects)}}
    end
  end

  @doc """
  Lists loadable canon, project-scoped cards behind the onboarder gate, using Loader's
  configured scopes and validation. name is the loadable basename; declared_name is
  metadata. Presentation uses presentation or description, with jury and sorted steps.
  Preserve catalogue identity because different catalogues can share card names.

  Empty offers are errors: workflow_catalogue_unavailable wraps enumeration RuntimeError;
  workflow_no_card_scope means no pairs were found; workflow_offer_empty distinguishes
  filtered-only material from load failures through its unreadable list. A mixed offer
  retains unreadable entries; no unreadable key is emitted when all offered reads succeed.
  """
  @spec list_workflow_cards(map()) :: {:ok, map()} | {:error, term()}
  def list_workflow_cards(state) do
    with {:ok, _role} <- Gate.require_onboarder(state),
         {:ok, pairs} <- catalogue_cards() do
      {cards, unreadable} = Enum.reduce(pairs, {[], []}, &offerable_card/2)

      # Match the empty error list first to omit unreadable rather than emit an empty key.
      case {length(pairs), Enum.reverse(cards), Enum.reverse(unreadable)} do
        {0, _, _} ->
          {:error,
           {:workflow_no_card_scope,
            "no installed catalogue carries a cards directory — nothing was scanned, so this is " <>
              "not an empty catalogue but a container serving none. `catalogue_list` says what it serves."}}

        {scanned, [], []} ->
          {:error,
           {:workflow_offer_empty, [],
            "#{scanned} card(s) scanned, none declarable for a PROJECT — they are all technical " <>
              "(smoke/demo) or ticket-scoped. A catalogue that ships no canon project card offers " <>
              "no framing choice."}}

        {scanned, [], bad} ->
          {:error,
           {:workflow_offer_empty, bad,
            "#{scanned} card(s) scanned, NONE of them loads — the offer is empty because the " <>
              "catalogue is broken, not because it is small. Each failure was logged as it happened."}}

        {_scanned, offer, []} ->
          {:ok, %{"cards" => offer}}

        {_scanned, offer, bad} ->
          {:ok, %{"cards" => offer, "unreadable" => bad}}
      end
    end
  end

  @doc """
  Lists installed catalogues, including those with no cards. Uses Catalogue's readers
  rather than deriving installation from card_list. name is declared identity;
  bundled compares the root path, not that name. Nil default_card is omitted.

  Roots omitted by installed_catalogues are logged and returned as unreadable basenames.
  This reports the consequence, not whether the manifest was missing, invalid or unnamed;
  lcars catalogue verify resolves the cause. An empty served list is an error carrying
  those rejected roots. No unreadable key is emitted for a successful clean listing.
  """
  @spec list_catalogues(map()) :: {:ok, map()} | {:error, term()}
  def list_catalogues(state) do
    with {:ok, _role} <- Gate.require_onboarder(state) do
      installed = Catalogue.installed_catalogues()
      bundled_root = Catalogue.root()

      answered = MapSet.new(installed, & &1.root)

      unreadable =
        Catalogue.installed_roots()
        |> Enum.reject(&MapSet.member?(answered, &1))
        |> Enum.map(&Path.basename/1)

      for name <- unreadable do
        Logger.warning(
          "Delegation: catalogue material '#{name}' carries a #{Catalogue.manifest_file()} " <>
            "that yields no declared name — served by NOTHING and offered to nobody. Its cause is " <>
            "not decided here (absent, unparseable, or without a `name:`): `lcars catalogue " <>
            "verify` names it. Without this line the directory would vanish in silence."
        )
      end

      served =
        Enum.map(installed, fn %{name: name, root: root} ->
          %{"name" => name, "bundled" => root == bundled_root}
          |> Render.put_present("default_card", Catalogue.default_card(root))
        end)

      # Match the empty error list before the general case to preserve key absence.
      case {served, unreadable} do
        {[], bad} ->
          {:error,
           {:catalogue_offer_unavailable, bad,
            "no installed catalogue declares a name — this container serves nothing"}}

        {offer, []} ->
          {:ok, %{"catalogues" => offer}}

        {offer, bad} ->
          {:ok, %{"catalogues" => offer, "unreadable" => bad}}
      end
    end
  end

  # Offer only canon cards declarable for a project; ticket-scoped cards such as
  # workshop-direct remain loadable but are not project framing choices.
  defp offerable_card({cat, name, opts}, {ok, bad}) do
    case read_card(name, opts) do
      {:ok, %{"status" => "canon", "scope" => "project"} = card} ->
        {[put_catalogue(card, cat) | ok], bad}

      {:ok, _technical_or_ticket_scoped} ->
        {ok, bad}

      :error ->
        {ok, [if(cat, do: "#{cat}/#{name}.yaml", else: "#{name}.yaml") | bad]}
    end
  end

  defp catalogue_cards do
    pairs =
      Enum.flat_map(Loader.card_scopes(), fn %{catalogue: cat, dir: dir} ->
        opts = [workflow_maps_root: dir]
        Enum.map(Loader.canon_names!(opts), &{cat, &1, opts})
      end)

    {:ok, pairs}
  rescue
    e in RuntimeError -> {:error, {:workflow_catalogue_unavailable, e.message}}
  end

  # A fine-grained root override may have no catalogue identity; do not invent one.
  defp put_catalogue(card, nil), do: card
  defp put_catalogue(card, cat), do: Map.put(card, "catalogue", cat)

  defp read_card(name, opts) do
    card = Loader.load!(name, opts)

    {:ok,
     %{
       "name" => name,
       "declared_name" => card["name"],
       "status" => card["status"],
       "scope" => card["scope"],
       "presentation" => card["presentation"] || card["description"],
       "jury" => card["jury"],
       "steps" => card["steps"] |> Map.keys() |> Enum.sort()
     }}
  rescue
    e ->
      Logger.warning(
        "Delegation: workflow card #{name} does not load (#{Exception.message(e)}) — " <>
          "excluded from the catalogue listing"
      )

      :error
  end

  # ============================================================
  # Forge mechanics (run ONLY after the gate)
  # ============================================================

  defp do_create_project(name, args, onboarder_role) do
    with {:ok, onboard} <- Gate.conforming_onboard(),
         {:ok, org} <- Gate.resolve_org(args) do
      pitch = Map.get(args, "pitch") || Map.get(args, "description", "")

      # Do not require a human-membership read here for writes performed by the system
      # account. Public-repo issue creation is not proof of organization membership.
      opts = [
        org: org,
        description: Map.get(args, "description", pitch),
        pitch: pitch,
        # Nil preserves undeclared framing; Onboard owns defaults and declaration validation.
        justification: Map.get(args, "justification"),
        workflow_map: Map.get(args, "workflow_map"),
        onboarded_by: onboarder_role
      ]

      case onboard.onboard(name, opts) do
        {:ok, %{repo: repo, project_dir: pdir, work_dir: wdir, doc_dir: ddir} = result} ->
          {:ok,
           %{
             "status" => "onboarded",
             "repo" => repo,
             "project_dir" => pdir,
             "work_dir" => wdir,
             "doc_dir" => ddir,
             "delegation_target" => repo
           }
           |> Render.put_architect(result)}

        {:error, reason} ->
          {:error, {:onboard_failed, inspect(reason)}}
      end
    end
  end

  defp do_import_project(full_name) do
    with {:ok, onboard} <- Gate.conforming_onboard() do
      # Import obtains the org from owner/name; it is not a new catalogue selection.
      case onboard.import(full_name, []) do
        {:ok, %{repo: repo, project_dir: pdir, work_dir: wdir, doc_dir: ddir} = result} ->
          {:ok,
           %{
             "status" => "imported",
             "repo" => repo,
             "project_dir" => pdir,
             "work_dir" => wdir,
             "doc_dir" => ddir,
             "delegation_target" => repo
           }
           |> Render.put_architect(result)}

        {:error, reason} ->
          {:error, {:import_failed, inspect(reason)}}
      end
    end
  end

  # Remove the binding after deletion so a future homonym does not inherit its destination.
  # Absence is normal; other removal errors are logged but also rendered as absent.
  defp remove_publish_binding(full_name) do
    path =
      Path.join([
        System.user_home!(),
        ".lcars",
        "publish",
        "#{ProjectPublish.binding_key(full_name)}.json"
      ])

    case File.rm(path) do
      :ok ->
        :removed

      {:error, :enoent} ->
        :absent

      {:error, reason} ->
        Logger.warning(
          "Delegation: delete_project left the publish binding behind (#{path}): #{inspect(reason)}"
        )

        :absent
    end
  end

  defp do_delete_project(full_name, args) do
    with {:ok, onboard} <- Gate.conforming_onboard() do
      opts = [force: Map.get(args, "force", false) == true]

      case onboard.delete_project(full_name, opts) do
        {:ok, %{repo: repo} = result} ->
          binding = remove_publish_binding(full_name)
          local = Map.get(result, :local, %{})

          {:ok,
           %{
             "status" => "deleted",
             "repo" => repo,
             "forge" => to_string(Map.get(result, :forge, "")),
             "architect" => to_string(Map.get(result, :architect, "")),
             # Preserve the worker count so deletion reports work interrupted.
             "workers_killed" => Map.get(result, :workers_killed, 0),
             "binding" => to_string(binding),
             # Preserve the wire's work key for the seam's ops face, alongside project and workshop.
             "local" => %{
               "project" => to_string(Map.get(local, :project, :absent)),
               "work" => to_string(Map.get(local, :ops, :absent)),
               "workshop" => to_string(Map.get(local, :workshop, :absent))
             }
           }}

        # Preserve typed destructive-operation errors (`:force_required` versus forge outage).
        {:error, _reason} = err ->
          err
      end
    end
  end

  @doc """
  Adopts a disk-only project via Onboard. Forwards description, workflow_map,
  justification and acting role into an explicitly selected catalogue; typed errors pass through.
  """
  @spec adopt_project(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def adopt_project(name, args, state) when is_binary(name) and is_map(args) do
    case Gate.require_onboarder(state) do
      {:error, reason} -> {:error, reason}
      {:ok, role} -> do_adopt_project(name, args, role)
    end
  end

  defp do_adopt_project(name, args, role) do
    # Adoption creates a forge repo, so require the same explicit catalogue selection as creation.
    with {:ok, onboard} <- Gate.conforming_onboard(),
         {:ok, org} <- Gate.resolve_org(args) do
      opts = [
        org: org,
        description: Map.get(args, "description", ""),
        justification: Map.get(args, "justification"),
        workflow_map: Map.get(args, "workflow_map"),
        onboarded_by: role
      ]

      case onboard.adopt_project(name, opts) do
        {:ok, %{repo: repo, project_dir: pdir, work_dir: wdir, doc_dir: ddir} = result} ->
          {:ok,
           %{
             "status" => "adopted",
             "repo" => repo,
             "project_dir" => pdir,
             "work_dir" => wdir,
             "doc_dir" => ddir,
             "delegation_target" => repo
           }
           |> Render.put_architect(result)}

        {:error, _reason} = err ->
          err
      end
    end
  end

  @doc """
  Imports external history through Onboard's URL/reception/branch checks after the gate.
  Forwards workflow_map, justification, acting role and explicit catalogue org.
  Typed errors remain intact so unsupported hosts, hostile material and collisions
  can lead to different operator actions.
  """
  @spec import_external_project(String.t(), String.t(), map(), map()) ::
          {:ok, map()} | {:error, term()}
  def import_external_project(url, name, args, state)
      when is_binary(url) and is_binary(name) and is_map(args) do
    case Gate.require_onboarder(state) do
      {:error, reason} -> {:error, reason}
      {:ok, role} -> do_import_external(url, name, args, role)
    end
  end

  defp do_import_external(url, name, args, role) do
    # External import creates a local-forge repo and requires an explicit destination catalogue.
    with {:ok, onboard} <- Gate.conforming_onboard(),
         {:ok, org} <- Gate.resolve_org(args) do
      opts = [
        org: org,
        justification: Map.get(args, "justification"),
        workflow_map: Map.get(args, "workflow_map"),
        onboarded_by: role
      ]

      case onboard.import_external(url, name, opts) do
        {:ok, %{repo: repo, project_dir: pdir, work_dir: wdir, doc_dir: ddir} = result} ->
          {:ok,
           %{
             "status" => "imported_external",
             "repo" => repo,
             "project_dir" => pdir,
             "work_dir" => wdir,
             "doc_dir" => ddir,
             "delegation_target" => repo
           }
           |> Render.put_architect(result)}

        {:error, _reason} = err ->
          err
      end
    end
  end

  @doc """
  Parks a project through Onboard, which posts the marker and attempts architect shutdown.
  """
  @spec close_project(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def close_project(full_name, state) when is_binary(full_name) do
    case Gate.require_onboarder(state) do
      {:error, reason} -> {:error, reason}
      {:ok, _role} -> do_close_project(full_name)
    end
  end

  defp do_close_project(full_name) do
    with {:ok, onboard} <- Gate.conforming_onboard() do
      case onboard.close_project(full_name, []) do
        {:ok, %{repo: repo, outcome: outcome} = result} ->
          {:ok,
           %{
             "status" => "closed",
             "repo" => repo,
             "outcome" => to_string(outcome),
             # FR: operator-facing — the one semantic the human must hear at this moment.
             "note" =>
               "la brique en vol finit, la suivante ne part pas ; réouverture par open_project " <>
                 "ou en fermant le ticket-marqueur"
           }
           |> Render.put_present("marker_issue", Map.get(result, :marker_issue))
           |> Render.put_present(
             "architect",
             case Map.get(result, :architect) do
               nil -> nil
               a -> to_string(a)
             end
           )}

        {:error, _reason} = err ->
          err
      end
    end
  end

  @doc """
  Revises an existing project's validation card through the onboarder seam (BL-6-29).

  Typed card errors pass through unchanged.
  """
  @spec revise_project_card(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def revise_project_card(full_name, args, state)
      when is_binary(full_name) and is_map(args) do
    case Gate.require_onboarder(state) do
      {:error, reason} -> {:error, reason}
      {:ok, role} -> do_revise_card(full_name, args, role)
    end
  end

  # Report shrinking jury size explicitly; a card rename alone hides that consequence.
  # Omit the field when the jury did not shrink.
  defp jury_reduction(delta) when is_integer(delta) and delta < 0, do: abs(delta)
  defp jury_reduction(_), do: nil

  defp do_revise_card(full_name, args, role) do
    with {:ok, onboard} <- Gate.conforming_onboard() do
      opts = [
        workflow_map: Map.get(args, "workflow_map"),
        justification: Map.get(args, "justification"),
        # Forward max_fan only as supplied; Onboard owns retention of an absent value.
        max_fan: Map.get(args, "max_fan"),
        revised_by: role
      ]

      case onboard.revise_card(full_name, opts) do
        {:ok, %{repo: repo, card: card, outcome: outcome} = result} ->
          {:ok,
           %{
             "status" => "card_revised",
             "repo" => repo,
             "card" => card,
             "outcome" => to_string(outcome),
             # FR: operator-facing payload — the ONE semantic the human must hear at this moment.
             "note" =>
               "les routes déjà gravées ne re-routent pas : la révision vaut pour les tickets FUTURS"
           }
           |> Render.put_present("jury_reduit_de", jury_reduction(Map.get(result, :jury_delta)))
           |> Render.put_present("previous_card", Map.get(result, :previous_card))
           |> Render.put_present(
             "protection",
             case Map.get(result, :protection) do
               nil -> nil
               p -> to_string(p)
             end
           )}

        {:error, _reason} = err ->
          err
      end
    end
  end

  @doc """
  Remet le rail CI d'un projet à l'état livré, sur `main`.
  """
  @spec reset_project_ci_rail(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def reset_project_ci_rail(full_name, args, state)
      when is_binary(full_name) and is_map(args) do
    case Gate.require_onboarder(state) do
      {:error, reason} -> {:error, reason}
      {:ok, role} -> do_reset_ci_rail(full_name, args, role)
    end
  end

  defp do_reset_ci_rail(full_name, args, role) do
    with {:ok, onboard} <- Gate.conforming_onboard() do
      opts = [justification: Map.get(args, "justification"), reset_by: role]

      case onboard.reset_ci_rail(full_name, opts) do
        {:ok, %{repo: repo, outcome: outcome} = result} ->
          {:ok,
           %{
             "status" => "ci_rail_reset",
             "repo" => repo,
             "outcome" => to_string(outcome),
             "files" => Map.get(result, :files, []),
             # FR : la seule sémantique que l'humain doit entendre à cet instant.
             "note" =>
               "le rail de `main` est remis a l'etat livre — une PR DEJA ouverte garde le sien " <>
                 "jusqu'a ce que son producteur le corrige ou qu'elle rebase"
           }
           |> Render.put_present("protection", Map.get(result, :protection))}

        {:error, _reason} = err ->
          err
      end
    end
  end

  @doc """
  Reopens an existing local project and ensures its per-project architect.
  """
  @spec open_project(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def open_project(full_name, state) when is_binary(full_name) do
    case Gate.require_onboarder(state) do
      {:error, reason} -> {:error, reason}
      {:ok, _role} -> do_open_project(full_name)
    end
  end

  defp do_open_project(full_name) do
    with {:ok, onboard} <- Gate.conforming_onboard() do
      case onboard.open(full_name, []) do
        {:ok, %{repo: repo, project_dir: pdir, work_dir: wdir, doc_dir: ddir} = result} ->
          {:ok,
           %{
             "status" => "opened",
             "repo" => repo,
             "project_dir" => pdir,
             "work_dir" => wdir,
             "doc_dir" => ddir
           }
           |> Render.put_architect(result)}

        {:error, reason} ->
          {:error, {:open_failed, inspect(reason)}}
      end
    end
  end
end
