defmodule Fleet.MCP.PodTools.Delegation.Portfolio do
  @moduledoc """
  ONBOARDING channel — the portfolio verbs: what it takes for a project to exist on this machine,
  and to stop existing.

  create / import / open are the three ways IN (fresh repo, existing forge repo, project already
  on disk), close / delete the two ways OUT, adopt and import-external the two ways a project that
  started elsewhere becomes one of ours. The card verbs (`revise_project_card`,
  `list_workflow_cards`, `list_catalogues`) belong here for the same reason: a card DECIDES how a
  project is treated, and choosing it is a portfolio gesture, not a delegation one.

  The gate is the ONBOARDING one (`Gate.require_onboarder/1`): enrolling a project happens from
  OUTSIDE any project, which is exactly what separates it from the delegation head.
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
  DELETES a project `full_name` (`"owner/name"`) — general teardown via the `:mcp_project_onboard` seam,
  in order: forge repo first, then the face dirs, then the architect pod (stopped LAST, and only once a
  dir is proven to BE `full_name` — a homonym owned by someone else is never touched). Onboarder gate
  (starfleet/architect), same as create/import. FAIL-CLOSED: `args["force"]` MUST be the boolean `true` to act — without it the seam
  returns `{:error, {:force_required, _}}` and destroys nothing (the target is a free argument and the
  delete is irreversible; there is no reliable "valueless" heuristic).
  """
  # DISARMED BY DEPLOYMENT, checked before the gate and before the arguments.
  #
  # `force: true` already made the gesture deliberate, and deliberate is not the same as available.
  # This is the only irreversible act in the whole tool surface — it destroys the forge repo AND
  # the three local faces — reachable by any onboarder pod, on a target that is a free argument.
  # Nothing in the fleet's normal life needs it: end-of-life teardown is an operator
  # decision, not an agent one.
  #
  # Same shape as the bench's `--human-admin`: a real power, off by default, whose cost is written
  # next to its switch. Off, the refusal is NAMED (`:delete_project_disabled`) rather than looking
  # like a missing tool — an agent told "disabled" asks its human, an agent told nothing invents a
  # workaround.
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

  # `=== true`, not truthiness: a flag set to a string, a 1 or an accidental non-nil value must NOT
  # arm an irreversible gesture. Only the boolean says yes.
  defp delete_armed?, do: Application.get_env(:lcars_fleet, @delete_flag, false) === true

  @doc """
  Lists the projects on this container (pure read).

  The onboarder can create, open, import, adopt, close, revise AND DELETE a project; without a
  listing, the most destructive surface in the fleet is aimed by a name it can only have been told.

  Straight pass-through to the onboard seam, which owns both the disk layout and the parked-marker
  read. Nothing is derived here: re-deriving "which projects exist" MCP-side would be a second
  authority next to the one that creates and destroys them.
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
  Reads the validation-card catalogue for the framing interview — from the LOADING authority:
  `Loader.canon_names!/0` (the configured maps root, never a hardcoded priv path) and
  `Loader.load!/1` (schema + graph validated — the listing can only offer what the engine can
  actually load). For each card: `name` (the LOADABLE id — the `workflow_map` value of
  `project_create`), `declared_name` (the card's self-declared label, for reference — the two
  identities are distinct, never collapsed), FR `presentation` (shown to the human VERBATIM —
  the card's own voice), `jury` (PR judges) and `steps`.
  Architect gate (framing is the arch's job). A card that fails to load is SKIPPED loud and
  reported in `unreadable` (the catalogue never lies silently); an empty OFFER is an ERROR, never
  an empty listing — "no card exists" would be the vacuous lie.

  ## QUATRE ROUTES VERS UNE OFFRE VIDE, TROIS REFUS QUI LES DISTINGUENT

  Rendre `{:ok, %{"cards" => []}}` sur l'une quelconque d'entre elles donnerait a l'architecte un
  succes avec zero choix, au moment precis ou on lui demande de choisir. Les refus distinguent donc
  ce que le geste suivant distingue :

    * `{:workflow_catalogue_unavailable, message}` — le repertoire de cartes existe et ne porte
      AUCUN `*.yaml`. Il precede les deux autres et ne vient pas d'ici : `canon_names!/1` leve, et
      `catalogue_cards/0` rattrape.
    * `{:workflow_no_card_scope, why}` — rien a balayer : aucun catalogue installe ne porte de
      repertoire de cartes. `card_scopes/0` filtre sur `File.dir?`, donc il n'y a meme pas de quoi
      lever. C'est un fait de DEPLOIEMENT (cf. `list_catalogues/1`).
    * `{:workflow_offer_empty, unreadable, why}` — balaye, rien a offrir. C'est un fait de
      CATALOGUE, et `unreadable` tranche les deux sous-cas : non vide, les cartes existent et
      AUCUNE ne charge ; vide, elles existent et sont toutes TECHNIQUES ou a portee ticket, donc
      rien n'est declarable pour un projet.
  """
  @spec list_workflow_cards(map()) :: {:ok, map()} | {:error, term()}
  def list_workflow_cards(state) do
    with {:ok, _role} <- Gate.require_onboarder(state),
         {:ok, pairs} <- catalogue_cards() do
      {cards, unreadable} = Enum.reduce(pairs, {[], []}, &offerable_card/2)

      # ⚠ L'ORDRE DES DEUX DERNIERES CLAUSES EST PORTEUR, meme regle que chez `list_catalogues/1` :
      # `{_, offer, bad}` filtre aussi `bad == []`, donc les intervertir poserait `"unreadable" => []`
      # dans la reponse nominale — une cle vide la ou l'absence est la reponse.
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
  The catalogues this container SERVES — the mirror of `list_workflow_cards/1`, one level up.

  The listing comes from the pairing the boot already resolves on. Re-deriving "which catalogues
  exist" MCP-side would be a second authority beside it — and deriving it from the CARDS is wrong
  in a specific way: a catalogue shipping no card is invisible to that route, so the answer comes
  back confidently short rather than wrong-looking.

  ## What each entry carries, and what it deliberately does NOT

    * `name` — the DECLARED identity, carried by the catalogue and not by the directory it was
      unpacked into. It is what addresses the catalogue OUTSIDE this container.
    * `bundled` — it ships INSIDE the release, so it cannot be removed. An availability guarantee,
      not an authority: a bundled catalogue is a peer.

      ⚠ C'EST LA RACINE QUI EST LIVREE, JAMAIS LE NOM, et les deux ne coincident pas toujours.
      Comparer l'identite DECLAREE au nom livre se lit comme le meme test et ne l'est pas : le
      filtrage se fait sur le chemin, donc un repertoire nomme autrement dont le manifeste declare
      ce nom-la ressortirait marque `bundled` — une seconde entree pretendant vivre dans un release
      qui n'en porte qu'une.
    * `default_card` — the card a project takes when it declares none. ABSENT, never `null`:
      "ships no card" and "default unknown" are two answers, and only the first exists here.

  No card list: a second rendering of the same table is the copy that drifts.

  ## `unreadable`, and it is REACHABLE — that is why it is here

  The boot verifies the BUNDLED root alone; converged material is verified by an operator gesture.
  A root whose manifest yields no declared name is therefore present, served by nothing, and
  dropped in SILENCE. Reporting it is the rule this module holds throughout: never lie by omission.

  ⚠ IL NOMME UNE CONSEQUENCE, PAS UNE CAUSE. La racine est ecartee sur un catch-all qui couvre
  aussi un YAML invalide et un manifeste illisible ; trancher entre ces causes demanderait de
  relire le manifeste ICI, c'est-a-dire un second lecteur de sa regle a cote de son autorite — le
  defaut precis que ce module ferme. Le mot rendu est donc la consequence commune, et le geste qui
  nomme la cause est `lcars catalogue verify <racine>`.

  L'avertissement par racine ecartee n'est pas un doublon du payload : si l'agent ne rend pas la
  reponse, la racine morte ne laisse AUCUNE trace cote serveur.

  ## L'offre VIDE est une erreur, et le refus PORTE ce qu'il a vu

  « Aucun catalogue n'existe » est le mensonge vide : ce conteneur sert toujours au moins le
  catalogue livre. Le refus emporte les racines ecartees, parce que « rien d'installe » et « tout
  installe, tout casse » appellent deux gestes differents.
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

      # ⚠ L'ORDRE DES DEUX DERNIERES CLAUSES EST PORTEUR : `{offer, bad}` filtre aussi `bad == []`,
      # donc les intervertir poserait `"unreadable" => []` dans la reponse nominale — une cle vide la
      # ou l'absence est la reponse, exactement ce que `put_present` refuse un cran plus haut.
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

  # Le TABLEAU catalogue x carte : chaque carte nommee par le catalogue qui la porte. Avec un seul
  # metier la question ne se pose pas ; des qu'il y en a deux, `standard` peut exister
  # des deux cotes et un nom seul ne designe plus rien. Le guichet presente donc l'offre ENTIERE en
  # une fois — c'est deja ce que son commentaire d'outil promettait (« framing FIRST: the catalogue
  # the human picks the card from »), sur un catalogue au lieu de N.

  # DEUX AXES, et les deux doivent tenir pour qu'une carte soit OFFERTE ici. `status: canon` = c'est
  # une carte de production, pas une fixture de fumee ou de demo. `scope: project` = elle est
  # declarable pour un PROJET ENTIER, la seule question que ce listing pose — l'humain choisit la
  # criticite d'un projet. Une carte a portee TICKET (`workshop-direct`, atteinte par le genre d'une
  # issue) y a ete offerte et n'aurait jamais du l'etre : presenter un choix qui ne peut pas se
  # faire a cette portee invite exactement la declaration que le reste du rail refuse ensuite.
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

  # `nil` sous une surcharge fine : la fixture n'appartient a aucun catalogue, et lui en inventer un
  # nom serait une reponse fabriquee a une question qui ne se pose pas la.
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

  # The onboarding sequence proper. The SYSTEM runs the mechanics (forge repo +
  # three faces main/ops/workshop + scaffold + push) via the :project_onboard seam (contract =
  # behaviour Delegation.ProjectOnboard; default Fleet.Project.Onboard, runtime dispatch —
  # no compile-time dep on fleet_pilot).
  defp do_create_project(name, args, onboarder_role) do
    with {:ok, onboard} <- Gate.conforming_onboard(),
         {:ok, org} <- Gate.resolve_org(args) do
      # The org is the CATALOGUE the caller declares (`Gate.resolve_org/1`), and it must be
      # installed here: the poller only discovers on installed catalogue orgs, so a project onboarded
      # anywhere else is a DEAD RAIL, silently — nothing would ever dispatch it (BL-6-05). No knob overrides
      # it: a permanent decision is stated, never defaulted.
      pitch = Map.get(args, "pitch") || Map.get(args, "description", "")

      # ⚠ AUCUNE GARDE D'ADHESION ICI, ET CE N'EST PAS UN OUBLI. Exiger que le jeton runtime PROUVE
      # l'adhesion de l'humain a `<org>:humans` reclame un `read` qu'il a deja (org publique, depots
      # publics) pour des ecritures qu'il ne fait pas — c'est le jeton SYSTEME qui ecrit. Et
      # `create_issue` en aval n'est pas le filet qu'on croit : mesure, un non-membre de l'org cree
      # une issue sur un depot public (201).
      opts = [
        org: org,
        description: Map.get(args, "description", pitch),
        pitch: pitch,
        # Criticality declaration RELAYED from the human (nil entries = undeclared → the onboard records an HONEST
        # undeclared default (the delegation default card), marked undeclared; never fabricated facts, never a wall — a
        # blocked declaration teaches the human to lie to the arch).
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

  # Import sequence — same :project_onboard seam, callback :import instead of :onboard.
  defp do_import_project(full_name) do
    with {:ok, onboard} <- Gate.conforming_onboard() do
      # PAS D'OPTS, ET RIEN A Y METTRE. L'org n'a rien a faire ici : `import/2` la LIT du depot
      # (`owner/nom`), elle ne se declare pas. Et aucune garde d'adhesion ne s'y ajoute non plus,
      # pour la raison ecrite chez `do_onboard_project`.
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

  # Delete sequence — same :project_onboard seam, callback :delete_project. `force` bypasses the
  # anti-work safety guard (deliberate end-of-life delete).
  # A deleted project must not leave its publish binding behind: a future project of the SAME name
  # would silently inherit a dead external destination. Host-side (`~/.lcars`, per-human — the BEAM
  # runs as the human). Best-effort: an absent binding is the NOMINAL case (most projects never
  # publish), and the delete has already succeeded, so a leftover binding is logged, not fatal. The key
  # is `ProjectPublish.binding_key/1` — the single source of the org-qualified format the writer uses.
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
             # A deletion that cost work in flight must not read as free: the seam counts the
             # workers it swept, and the wire carries the count to the human who may not have known
             # anything was running. Dropped between 2026-08 and 2026-09-04 — `Lifecycle` computed
             # and tested it, this map never named it.
             "workers_killed" => Map.get(result, :workers_killed, 0),
             "binding" => to_string(binding),
             # The seam returns `%{project:, ops:, workshop:}` (`Lifecycle.delete_project/2`). The
             # wire keeps `work` for the ops face and adds `workshop`: a verdict the runtime
             # produces and the wire drops is a removal nobody can audit.
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
  Adopts a disk-only project through the onboarder seam (BL-6-32).

  Criticality is relayed unchanged; typed adoption errors pass through.
  """
  @spec adopt_project(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def adopt_project(name, args, state) when is_binary(name) and is_map(args) do
    case Gate.require_onboarder(state) do
      {:error, reason} -> {:error, reason}
      {:ok, role} -> do_adopt_project(name, args, role)
    end
  end

  defp do_adopt_project(name, args, role) do
    # LE CATALOGUE, RESOLU PAR LA MEME PORTE QUE `project_create` : adopter cree un depot sur la
    # forge, donc c'est une creation, donc l'org est une DECLARATION. La faire tomber sur le premier
    # catalogue installe enverrait tout projet adopte dans `fleet`, quel que soit le metier auquel
    # il appartient.
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
  IMPORTS a repo from an EXTERNAL forge (BL-6-31) — onboarder gate. The mechanics live
  pilot-side (`import_external` seam callback: URL gate, scratch repatriation, adoption gate,
  branch normalization, org creation, standard import leg). The criticality declaration is
  RELAYED like `project_create`'s. Typed errors pass through unflattened
  (`{:unsupported_forge, _}`, `{:foreign_claude_dir, _}`, `{:hostile_material, _, _}`,
  `{:branch_collision, _}`, `{:already_on_machine, _}`, `{:repo_already_exists, _}` — each
  names a DIFFERENT operator action).
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
    # Meme porte que les deux autres creations : importer un depot EXTERNE cree un depot sur NOTRE
    # forge, donc l'org est une declaration, jamais le premier catalogue installe.
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
  Closes a project through the onboarder seam (BL-6-30).

  The pilot posts the marker respected by the poller, then stops the architect best-effort.
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

  # THE CONSEQUENCE, RELAYED. The card NAME does not say what the card does: `standard-qa` carries
  # two judges and `c0-poc` carries none, so a revision between them removes a jury while reading
  # like a rename. The arch relays this payload to its human, and a downgrade the human never hears
  # named is a wall that came down in a sentence about configuration.
  #
  # ABSENT when the jury did not shrink (`put_present` drops nil): one meaning per shape — a key
  # that appeared with `0` on every ordinary revision would be noise, and noise is what a reader
  # learns to skip before the one time it matters.
  defp jury_reduction(delta) when is_integer(delta) and delta < 0, do: abs(delta)
  defp jury_reduction(_), do: nil

  defp do_revise_card(full_name, args, role) do
    with {:ok, onboard} <- Gate.conforming_onboard() do
      opts = [
        workflow_map: Map.get(args, "workflow_map"),
        justification: Map.get(args, "justification"),
        # Throughput of THIS project (workflow_runs in flight). Absent leaves the declaration
        # untouched — the fleet default answers, and it is not frozen into the project's record.
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

  # Open sequence — same :project_onboard seam, callback :open.
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
