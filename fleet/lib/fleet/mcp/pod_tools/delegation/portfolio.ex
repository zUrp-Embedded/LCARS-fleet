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

  alias Fleet.MCP.PodTools.Delegation.{Gate, Render}
  alias Fleet.MCP.PodTools.ProjectPublish

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
  DELETES a project `full_name` (`"owner/name"`) — general teardown via the `:project_onboard` seam,
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
  # both worktrees — and it was permanently reachable by any onboarder pod, on a target that is a
  # free argument. Nothing in the fleet's normal life needs it: end-of-life teardown is an operator
  # decision, not an agent one.
  #
  # Same shape as the bench's `--human-admin`: a real power, off by default, whose cost is written
  # next to its switch. Off, the refusal is NAMED (`:delete_project_disabled`) rather than looking
  # like a missing tool — an agent told "disabled" asks its human, an agent told nothing invents a
  # workaround.
  @delete_flag :mcp_allow_delete_project

  @spec delete_project(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def delete_project(full_name, args, state) when is_binary(full_name) and is_map(args) do
    cond do
      not delete_armed?() ->
        Logger.warning(
          "Delegation: delete_project(#{full_name}) REFUSED — disarmed by deployment " <>
            "(config :lcars_fleet, #{inspect(@delete_flag)} is not true)"
        )

        {:error, :delete_project_disabled}

      true ->
        case Gate.require_onboarder(state) do
          {:error, reason} -> {:error, reason}
          {:ok, _role} -> do_delete_project(full_name, args)
        end
    end
  end

  # `=== true`, not truthiness: a flag set to a string, a 1 or an accidental non-nil value must NOT
  # arm an irreversible gesture. Only the boolean says yes.
  defp delete_armed?, do: Application.get_env(:lcars_fleet, @delete_flag, false) === true

  @doc """
  Lists the projects on this box (pure read).

  The onboarder could create, open, import, adopt, close, revise AND DELETE a project, and had no
  way to enumerate them: the most destructive surface in the fleet, aimed by a name it could only
  have been told. Zero occurrences of any listing — not a filter to widen, a half that was never
  built.

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

  ## ⚠ CETTE PROMESSE ETAIT ECRITE ET TENUE SUR UN CHEMIN SUR QUATRE

  La ligne au-dessus disait deja « an ERROR, never an empty listing », et seule la racine
  CONFIGUREE sans aucun `*.yaml` la tenait — parce que `canon_names!/1` leve, pas parce que quelque
  chose ici le decidait. Les trois autres routes vers une offre vide rendaient `{:ok, %{"cards" =>
  []}}` :

    * aucun catalogue installe ne porte de repertoire de cartes — `card_scopes/0` filtre sur
      `File.dir?`, donc il n'y a meme pas de quoi lever : RIEN n'a ete balaye ;
    * des cartes existent et AUCUNE ne charge — l'offre est vide, la cause est dans `unreadable` ;
    * des cartes existent et toutes sont TECHNIQUES ou a portee ticket — rien de declarable pour un
      projet.

  Dans les trois cas, l'architecte recevait un succes avec zero choix, au moment precis ou on lui
  demande de choisir. Releve le 2026-08-22 par relecture independante en marge du chantier
  `catalogue_list`, et laisse ouvert un tour de trop au motif que c'etait « hors perimetre » — le
  perimetre est le projet.

  Les refus distinguent donc ce que le geste suivant distingue :

    * `{:workflow_no_card_scope, why}` — rien a balayer. C'est un fait de DEPLOIEMENT : la boite ne
      sert aucun catalogue portant des cartes (cf. `list_catalogues/1`).
    * `{:workflow_offer_empty, unreadable, why}` — balaye, rien a offrir. C'est un fait de
      CATALOGUE, et `unreadable` tranche les deux sous-cas : non vide, les cartes ne chargent pas ;
      vide, elles sont toutes techniques ou a portee ticket.
    * `{:workflow_catalogue_unavailable, message}` — le repertoire de cartes existe et ne porte
      AUCUN `*.yaml`. Il precede les deux autres et ne vient pas d'ici : `canon_names!/1` leve, et
      `catalogue_cards/0` rattrape. C'est le seul des trois qui existait avant le 2026-08-22.

      ⚠ IL EST DANS CETTE LISTE PARCE QU'ELLE PRETEND ETRE COMPLETE. Ecrite sans lui, elle
      enumerait deux gestes sur trois sous un titre qui annonce le decoupage entier — une prose
      fausse par omission, dans la section meme qui vient de fermer une promesse a moitie tenue.
      Relevee par relecture independante le 2026-08-22, sur le texte ecrit la veille.
  """
  @spec list_workflow_cards(map()) :: {:ok, map()} | {:error, term()}
  def list_workflow_cards(state) do
    with {:ok, _role} <- Gate.require_onboarder(state),
         {:ok, pairs} <- catalogue_cards() do
      {cards, unreadable} =
        Enum.reduce(pairs, {[], []}, fn {cat, name, opts}, {ok, bad} ->
          # TWO axes, and both must hold for a card to be OFFERED here. `status: canon` = it is a
          # production card and not a smoke/demo fixture. `scope: project` = it is declarable for a
          # WHOLE project, which is the only question this listing asks — the human is choosing a
          # project's criticality. A ticket-scoped card (`workshop-direct`, reached by an issue's
          # genre) was offered here and should never have been: presenting a choice that cannot be
          # made at this scope invites exactly the declaration the rest of the rail then refuses.
          case read_card(name, opts) do
            {:ok, %{"status" => "canon", "scope" => "project"} = card} ->
              {[put_catalogue(card, cat) | ok], bad}

            {:ok, _technical_or_ticket_scoped} ->
              {ok, bad}

            :error ->
              {ok, [if(cat, do: "#{cat}/#{name}.yaml", else: "#{name}.yaml") | bad]}
          end
        end)

      # ⚠ L'ORDRE DES DEUX DERNIERES CLAUSES EST PORTEUR, meme regle que chez `list_catalogues/1` :
      # `{_, offer, bad}` filtre aussi `bad == []`, donc les intervertir poserait `"unreadable" => []`
      # dans la reponse nominale — une cle vide la ou l'absence est la reponse.
      case {length(pairs), Enum.reverse(cards), Enum.reverse(unreadable)} do
        {0, _, _} ->
          {:error,
           {:workflow_no_card_scope,
            "no installed catalogue carries a cards directory — nothing was scanned, so this is " <>
              "not an empty catalogue but a box serving none. `catalogue_list` says what it serves."}}

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
  The catalogues this box SERVES — the mirror of `list_workflow_cards/1`, one level up.

  Same gate, same shape, same authority discipline: the listing is read from
  `Fleet.Catalogue.installed_catalogues/0`, the pairing that already answers this for the poller,
  the card scopes and the enroller. Re-deriving "which catalogues exist" MCP-side would be a second
  authority next to the one the boot resolves on.

  ## Why the tool exists, measured

  An agent asked for the catalogues and had no verb for it, so it DERIVED the answer from
  `card_list` — which names each card's catalogue. That derivation is right only while every
  installed catalogue ships at least one card: a catalogue with none is invisible to it, and the
  answer is confidently short rather than wrong-looking. The same hole is why the listing here does
  not go through `Loader.card_scopes/0` either.

  ## What each entry carries, and what it deliberately does NOT

    * `name` — the DECLARED identity, carried by the catalogue and not by the directory it was
      unpacked into. It is what addresses the catalogue outside this box: the forge org that holds
      its projects, and the prefix of its role logins.
    * `bundled` — it ships INSIDE the release, so it is installed by construction and cannot be
      removed. That is an availability guarantee, not an authority: a bundled catalogue is a peer.

      ⚠ C'EST LA RACINE QUI EST LIVREE, JAMAIS LE NOM, et les deux ne coincident pas toujours.
      Comparer l'identite declaree a `bundled_name/0` se LIT comme le meme test et ne l'est pas :
      `installed_dirs/0` ecarte le catalogue livre sur le `Path.basename`, donc un repertoire nomme
      autrement dont le manifeste declare ce nom-la passe le filtre et ressortait marque `bundled` —
      une seconde entree pretendant vivre dans un release qui n'en porte qu'une. La racine EST la
      definition (`Fleet.Catalogue.root/0`, la tete de `installed_roots/0`), donc c'est elle qu'on
      compare. Releve par relecture independante le 2026-08-22.
    * `default_card` — the card a project of this catalogue takes when it declares none. Absent
      when the catalogue ships no card at all. ABSENT, never `null`: "ships no card" and "default
      unknown" are two answers, and only the first exists here.

  No card list: `card_list` already names each card's catalogue, and a second rendering of the
  same table is the copy that drifts. The two tools are complementary halves, never nested ones.

  ## `unreadable`, and it is REACHABLE — that is why it is here

  `Fleet.Catalogue.verify!/0` runs at boot on the BUNDLED root alone. The material converged under
  `catalogue_install_dirs` is verified by an operator gesture (`lcars catalogue verify`), never by
  the boot, so a root whose manifest yields no declared name is present, served by nothing, and
  dropped from `installed_catalogues/0` in SILENCE. Reporting it is the same rule
  `list_workflow_cards/1` holds for a card that fails to load: the catalogue never lies by omission.

  ⚠ IL NOMME UNE CONSEQUENCE, PAS UNE CAUSE, et la premiere redaction disait « no `name:` » — plus
  precis que le code. `installed_catalogues/0` ecarte une racine sur un catch-all qui couvre AUSSI
  un YAML invalide, un manifeste illisible et un `name` qui n'est pas une chaine. Trancher entre ces
  causes demanderait de relire le manifeste ici, c'est-a-dire un second lecteur de la regle du
  manifeste a cote de son autorite — le defaut precis que ce module passe son temps a fermer.
  Le mot rendu est donc la consequence commune (« servi par rien »), et le geste est `lcars
  catalogue verify <racine>`, dont c'est le metier de nommer la cause.

  Le `Logger.warning` par racine ecartee n'est pas un doublon du payload : si l'agent ne rend pas la
  reponse, la racine morte ne laisse aucune trace cote serveur. `list_workflow_cards/1` crie deja
  chaque carte qui ne charge pas, pour cette raison-la.

  Les deux moities se lisent dans UN module, un appel chacune — la difference ensembliste de
  `installed_roots/0` et des racines qui ont repondu — donc rien ici ne relit un manifeste.

  ## L'offre VIDE est une erreur, et le refus PORTE ce qu'il a vu

  « Aucun catalogue n'existe » est le mensonge vide : cette boite sert toujours au moins le
  catalogue livre. Le refus emporte les racines ecartees, parce que « rien d'installe » et « tout
  installe, tout casse » appellent deux gestes differents et qu'un refus qui les confond envoie
  l'operateur chercher le mauvais objet.

  `list_workflow_cards/1` tient la meme regle, et ne la tenait que sur un chemin sur quatre jusqu'au
  2026-08-22 — son propre `@doc` porte la cicatrice. Les deux refus sont donc symetriques : une
  offre vide n'est jamais un succes, ni ici ni un cran plus bas.
  """
  @spec list_catalogues(map()) :: {:ok, map()} | {:error, term()}
  def list_catalogues(state) do
    with {:ok, _role} <- Gate.require_onboarder(state) do
      installed = Fleet.Catalogue.installed_catalogues()
      bundled_root = Fleet.Catalogue.root()

      answered = MapSet.new(installed, & &1.root)

      unreadable =
        Fleet.Catalogue.installed_roots()
        |> Enum.reject(&MapSet.member?(answered, &1))
        |> Enum.map(&Path.basename/1)

      for name <- unreadable do
        Logger.warning(
          "Delegation: catalogue material '#{name}' carries a #{Fleet.Catalogue.manifest_file()} " <>
            "that yields no declared name — served by NOTHING and offered to nobody. Its cause is " <>
            "not decided here (absent, unparseable, or without a `name:`): `lcars catalogue " <>
            "verify` names it. Without this line the directory would vanish in silence."
        )
      end

      served =
        Enum.map(installed, fn %{name: name, root: root} ->
          %{"name" => name, "bundled" => root == bundled_root}
          |> Render.put_present("default_card", Fleet.Catalogue.default_card(root))
        end)

      # ⚠ L'ORDRE DES DEUX DERNIERES CLAUSES EST PORTEUR : `{offer, bad}` filtre aussi `bad == []`,
      # donc les intervertir poserait `"unreadable" => []` dans la reponse nominale — une cle vide la
      # ou l'absence est la reponse, exactement ce que `put_present` refuse un cran plus haut. Mesure
      # du 2026-08-22 : aucun temoin ne rougissait sur cette permutation ; il en existe un depuis.
      case {served, unreadable} do
        {[], bad} ->
          {:error,
           {:catalogue_offer_unavailable, bad,
            "no installed catalogue declares a name — this box serves nothing"}}

        {offer, []} ->
          {:ok, %{"catalogues" => offer}}

        {offer, bad} ->
          {:ok, %{"catalogues" => offer, "unreadable" => bad}}
      end
    end
  end

  # Le TABLEAU catalogue x carte : chaque carte nommee par le catalogue qui la porte. Ce n'etait pas
  # une question tant qu'il n'y avait qu'un metier ; des qu'il y en a deux, `standard` peut exister
  # des deux cotes et un nom seul ne designe plus rien. Le guichet presente donc l'offre ENTIERE en
  # une fois — c'est deja ce que son commentaire d'outil promettait (« framing FIRST: the catalogue
  # the human picks the card from »), sur un catalogue au lieu de N.
  defp catalogue_cards do
    pairs =
      Enum.flat_map(Fleet.Workflow.Loader.card_scopes(), fn %{catalogue: cat, dir: dir} ->
        opts = [workflow_maps_root: dir]
        Enum.map(Fleet.Workflow.Loader.canon_names!(opts), &{cat, &1, opts})
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
    card = Fleet.Workflow.Loader.load!(name, opts)

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
      # SAME config key as the poller's discovery org (`:lcars_fleet, :pilot_fleet_org`) — a project
      # onboarded into an org the poller never scans is a DEAD RAIL, silently: nothing would ever
      # dispatch it. Two knobs with two inline defaults were one edit away from diverging with no
      # gate to catch it. Reading another domain's config ATOM creates no module edge (the boundary
      # stays intact; the config lives under `:lcars_fleet` with a `mcp_` prefix, BL-6-05) — the config IS the shared
      # authority here. `:delegation_org` survives as an explicit OVERRIDE for the rare case where
      # onboarding must target another org than the one being polled.
      pitch = Map.get(args, "pitch") || Map.get(args, "description", "")

      # ⚠ `allow_unverifiable_human_team?` VIVAIT ICI (DR-018) ET N'EXISTE PLUS (2026-08-17). Il
      # ouvrait un mode degrade quand le jeton runtime ne pouvait pas PROUVER l'adhesion de l'humain a
      # `<org>:humans`. La garde qu'il assouplissait est morte avec lui : elle exigeait un `read` que
      # l'humain a deja (org publique, depots publics) pour des ecritures qu'il ne fait pas — c'est le
      # jeton systeme qui ecrit. Son propre message de repli invoquait « downstream create_issue
      # remains the net » : mesure du 2026-08-17, un non-membre de l'org cree une issue sur un depot
      # public (201). Le filet n'existait pas.
      opts = [
        org: org,
        description: Map.get(args, "description", pitch),
        pitch: pitch,
        # Criticality declaration RELAYED from the human (nil entries = undeclared → the
        # onboard records an HONEST undeclared default (the delegation default card), marked undeclared; never fabricated facts,
        # never a wall — a blocked declaration teaches the human to lie to the arch).
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
      # PAS D'OPTS, ET C'EST UN RESTE QUI PART. Ce verbe ne portait que le drapeau
      # `allow_unverifiable_human_team?` (DR-018), mort avec la garde qu'il assouplissait — cf. le
      # commentaire de `do_onboard_project` plus haut. L'org, elle, n'a rien a faire ici : `import/2`
      # la LIT du depot (`owner/nom`), elle ne se declare pas.
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
             "binding" => to_string(binding),
             "local" => %{
               "project" => to_string(Map.get(local, :project, :absent)),
               "work" => to_string(Map.get(local, :work, :absent))
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
    # forge, donc c'est une creation, donc l'org est une declaration. Elle tombait sur le premier
    # catalogue installe (`Onboard.default_org/0`, mort le 2026-08-17) — un projet adopte partait
    # donc dans `fleet` quel que soit le metier auquel il appartient.
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
    # forge, donc l'org est une declaration. Elle tombait sur le premier catalogue installe.
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
