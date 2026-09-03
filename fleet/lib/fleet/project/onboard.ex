defmodule Fleet.Project.Onboard do
  @moduledoc """
  Onboarding of a project: "idea → the project exists".

  Replicates the multi-face architecture of LCARS itself (one forge repo, **three local repos**):

    * `/home/projects/<name>`       → clone, branch `main`       (the deliverable, push origin)
    * `/home/projects.ops/<name>`  → STANDALONE repo, branch `ops` (orphan) — the RECORD:
      briefs, gate-briefs, verdicts, provenance. Written by the RUNTIME; no pod writes here.
      Qui le monte, et en quel mode, est declare dans les `mounts:` des cap-profiles.
    * `/home/projects.workshop/<name>`   → STANDALONE repo, branch `workshop` (orphan) — the WORKSHOP:
      plans, backlog, scratchpad, specs in progress. Written by a PRODUCER, ships with nothing.

  Each writer face is STANDALONE and not a linked worktree, and the reason is the same for both:
  its ENTIRE gitdir must live on its own side (F-24). A linked worktree keeps its gitdir under the
  parent repo, which a pod mounting that parent read-only could then not commit into
  (`add_work_ops` carries the full rationale).

  ⚠ The documentation that SHIPS is none of the above two: it lives in `docs/` on `main`, is
  written by a producer working the code face, and is judged like any other deliverable. The
  criterion separating the workshop from it is the DESTINATION, never the nature of the artefact.

  It is a **mechanical rail** (structural compliance): starfleet (the fleet-master) *triggers* via the
  MCP tool `project_create`, the SYSTEM *executes* this deterministic sequence — the caller never types
  git. Onboarding also spawns the project's per-project architect (`maybe_open_architect`).

  Sequence (FAIL-LOUD if the repo already exists on the forge — onboard CREATES, it must NOT
  scaffold over a pre-existing `main`; `import/2` is the safe adopt-an-existing-repo path — and fails
  clearly if the local folder already exists):

    1. `ForgeClient.create_repo` (org `fleet`, `auto_init` → `main` cloneable) — 409 ⇒ `{:error, {:repo_already_exists, _}}`
    2. `git clone --branch main` → `/home/projects/<name>`
    3. scaffold `main` (README, CLAUDE.md, .gitignore, .editorconfig, CI) — PAS de spec : la matiere de
       cadrage vit sur `workshop`, la seule face dont l architecte ait la plume avant la 1re livraison
    4. commit (author=`system_starfleet`, committer=git config runtime = the human) + push `main`
    5. the two WRITER faces, same shape each (`build_writer_face/7`): `git init -b <branch>` +
       `remote add origin` → standalone clone, scaffold its template subtree, commit, push `-u`
       * `ops` → `/home/projects.ops/<name>` — the RECORD the runtime keeps (README only:
         briefs, gate-briefs, verdicts and provenance are written there BY the runtime, never by a pod)
       * `workshop` → `/home/projects.workshop/<name>` — the project's WORKSHOP (CLAUDE.md, backlog.md,
         scratchpad.md, plans/), the material the project is built FROM and that never ships with it

  THREE faces, not two, and the third is not a variation on the second: `ops` is written by the
  runtime and `workshop` by a producer. Reading the planning material as living on the ops face —
  as this list did until the split caught up with it — puts a pod's workspace on the tree that
  records how that pod was judged.

  Identity (onboarding is an act of system INFRA, not creative work):
  `author=system_starfleet` (the SYSTEM generates the scaffold from templates; the arch writes no file,
  it **relays** `name`+`pitch` — it is transparent in the git attribution, its trace lives in the request),
  `committer`=the human (git config runtime = **the user who initiated the project → traced**),
  `pusher`=`system_starfleet` (`ForgeAuth.git_env`, fleet-wide owner). All avatared (emails → Gitea accounts).
  No GenServer (Iron Law — I/O orchestration without shared state).

  ⚠ CROSS CONTRACT (seam `fleet_mcp`): `onboard/2` is the REAL impl (default) of the behaviour
  `Fleet.MCP.PodTools.Delegation.ProjectOnboard`. It CANNOT be adopted as `@behaviour`:
  `Fleet.Pilot` does not depend on `Fleet.MCP` and the compile reference would be a Boundary
  violation (`Fleet.MCP` is absent from `Fleet.Pilot`'s `use Boundary` deps → compile error).
  Duck-typed impl — any evolution of the signature/of the
  `result()` shape MUST be reflected on the behaviour's `@callback` (and vice-versa).
  """

  alias Fleet.Project.Roles

  # Content + writing of the scaffold (pure templates, one subtree per face) — extracted:
  # no dependency on the orchestration, onboard calls it at the right moments of its sequence.
  alias Fleet.Project.Onboard.Adopt
  alias Fleet.Project.Onboard.Card
  alias Fleet.Project.Onboard.Create
  alias Fleet.Project.Onboard.Faces
  alias Fleet.Project.Onboard.Import
  alias Fleet.Project.Onboard.Lifecycle
  alias Fleet.Project.Onboard.Repo
  alias Fleet.Project.Onboard.Scaffold

  require Logger

  @type result :: %{
          :repo => String.t(),
          :project_dir => Path.t(),
          :work_dir => Path.t(),
          :doc_dir => Path.t(),
          # Per-project architect ensure outcome — reported, never dropped:
          # %{status: "up", pod_id: _} | %{status: "failed", reason: _}.
          :architect => map(),
          # LA RE-EMISSION CONVERGENTE SE DIT DANS LE RESULTAT, donc ce type la declare.
          # `refute_existing_or_converge` pose cette cle quand l'etat de fin est deja realise : le
          # verbe rend alors `{:ok, result}` sans rien avoir cree. Absente de la declaration, elle
          # rend `%{idempotent: true}` formellement INATTEIGNABLE — un appelant qui distingue
          # « importe » de « deja la » ecrivait un motif que Dialyzer refusait, sur une valeur que
          # le code produit vraiment.
          optional(:idempotent) => true
        }

  # ── LA SURFACE DU SEAM, RE-EXPORTEE ─────────────────────────────────
  # ⚠ CES TREIZE VERBES SONT LE CONTRAT, PAS DU CONFORT. Le behaviour
  # `Fleet.MCP.PodTools.Delegation.ProjectOnboard` designe CE module comme son implementation par
  # defaut, et `Gate.conforming/2` verifie par `function_exported?/3` que chacun de ses `@callback`
  # est exporte ICI. Un verbe descendu dans un sous-module sans etre re-exporte ne casse pas la
  # compilation : il rend `{:seam_misconfigured, Fleet.Project.Onboard, [...]}` a la premiere
  # delegation reelle. Le meme trou a coute `put_file/4` sur `Fleet.Forge.Client`, deux fois de
  # suite, a un architecte qui tirait une toolchain.
  #
  # Le CONTRAT de chaque verbe vit dans son `@doc`, a cote de son code, dans le module qui
  # l'implemente. Ici ne restent que la signature et l'adresse.

  @spec onboard(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  defdelegate onboard(name, opts \\ []), to: Create

  @spec import(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  defdelegate import(full_name, opts \\ []), to: Create

  @spec open(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  defdelegate open(full_name, opts \\ []), to: Lifecycle

  @spec list_projects(keyword()) :: {:ok, [map()]} | {:error, term()}
  defdelegate list_projects(opts \\ []), to: Lifecycle

  @spec list_stoppable_issues(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  defdelegate list_stoppable_issues(full_name, opts \\ []), to: Lifecycle

  @spec close_project(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate close_project(full_name, opts \\ []), to: Lifecycle

  @spec delete_project(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate delete_project(full_name, opts \\ []), to: Lifecycle

  @spec adopt_project(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  defdelegate adopt_project(name, opts \\ []), to: Adopt

  @spec import_external(String.t(), String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  defdelegate import_external(url, name, opts \\ []), to: Import

  @spec deposit_candidates(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  defdelegate deposit_candidates(human, opts \\ []), to: Import

  @spec import_deposit(String.t(), String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  defdelegate import_deposit(source, catalogue, opts \\ []), to: Import

  # ⚠ RE-EXPORTE POUR NE PAS ELARGIR LA FRONTIERE. `Fleet.Pilot` cable cette fonction comme defaut
  # de son seam de reconvergence, et `Fleet.Project` n'exporte pas `Onboard.Migration` — l'ajouter
  # aux `exports:` serait un changement d'API du domaine pour un besoin qui n'en demande aucun.
  # Le verbe reste a son adresse d'origine ; seule son implementation a demenage.
  @spec reconcile_main_protection(String.t(), keyword()) :: :ok | {:error, term()}
  defdelegate reconcile_main_protection(repo, opts \\ []), to: Fleet.Project.Onboard.Migration

  @spec revise_card(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate revise_card(full_name, opts \\ []), to: Card

  @spec reset_ci_rail(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate reset_ci_rail(full_name, opts \\ []), to: Card

  @doc false
  @spec onboard_result(String.t(), map(), keyword()) :: map()
  def onboard_result(full_name, dirs, opts) do
    %{
      repo: full_name,
      project_dir: dirs.code,
      work_dir: dirs.ops,
      doc_dir: dirs.workshop,
      architect: ensure_architect(full_name, opts)
    }
  end

  # TROIS ISSUES, ET LA TROISIEME N'EST NI UN SUCCES NI UN ECHEC. Un appelant qui n'a pas de fleet
  # sous la main — la porte de reconvergence tourne dans un `eval`, donc dans une VM qui a CHARGE
  # l'app sans la demarrer — ne peut pas assurer d'architecte : il n'y a aucun superviseur a qui le
  # demander. Le dire « failed » accuserait le projet d'un defaut qu'il n'a pas ; le dire « up »
  # serait un mensonge sur un pod qui n'existe pas. `deferred` dit ce qui est vrai, et qui prend la
  # suite : le poller de la fleet assure l'architecte de chaque projet qu'il sert.
  @doc false
  @spec ensure_architect(String.t(), keyword()) :: map()
  def ensure_architect(repo, opts) do
    ensure = Keyword.get(opts, :ensure_architect, &Fleet.Project.Architect.ensure/2)

    case ensure.(repo, opts) do
      {:ok, pod_id} -> %{status: "up", pod_id: pod_id}
      {:deferred, reason} -> %{status: "deferred", reason: reason}
      {:error, reason} -> %{status: "failed", reason: inspect(reason)}
    end
  end

  @doc """
  The forge orgs a project can be onboarded into — one per INSTALLED catalogue, and the org IS the
  catalogue's name.

  Lives here rather than being read from `Fleet.Catalogue` by every caller: "where can a project
  live" is an onboarding question, and the MCP surface reaches this domain but not the catalogue —
  the graph says so, and widening it to answer a project question would be widening it for the
  wrong reason.
  """
  @spec installed_orgs() :: [String.t()]
  def installed_orgs, do: Fleet.Catalogue.installed_names()

  @doc false
  # ─── L'ADMISSION, UNE FOIS, POUR LES CINQ VERBES QUI FONT ENTRER UN PROJET ─────────────────────
  #
  # ⚠ DES RAILS PARALLELES NE DIVERGENT PAS D'UN COUP, ILS DIVERGENT D'UNE LIGNE — et la ligne
  # manquante ne ressemble a rien. Les cinq preambules posaient les memes questions chacun a sa
  # facon, et UN SEUL ne verifiait pas que la carte est declarable : un depot importe avec une carte
  # d'atelier ou une faute de frappe y passait, la ou les quatre autres refusaient.
  #
  # L'ORG N'EST PAS DANS LE FILTRE, seule chose qui differe legitimement : certains verbes la
  # RECOIVENT declaree — creer une chose neuve n'a pas de source d'ou la tirer — et d'autres la
  # LISENT de leur source. Chaque verbe resout donc la sienne, puis passe par ici.
  #
  # ⚠ PUREMENT LOCAL, ET LA FRONTIERE EST L'ORDRE LUI-MEME : y glisser un controle qui APPELLE LA
  # FORGE ferait payer un aller-retour a une entree refusee jusque-la sans toucher au monde. La loi
  # est donc en trois temps — cette admission locale, les gardes PURES du verbe, puis le monde.
  #
  # ⚠ LA CLE DE VOUTE, A CHERCHER ICI AVANT D'AJOUTER UNE GARDE : aucun de ces verbes ne verifie que
  # l'humain qui les joue est legitime, et ce n'est PAS un trou. Le BEAM refuse de demarrer sous un
  # uid systeme et herite de cet uid pour lui comme pour ses pods, donc quiconque atteint ce code
  # EST un humain de la fleet, par construction. Une garde par verbe ne mesurerait que le uid qui
  # l'execute, c'est-a-dire l'INSTRUMENT.
  @spec admit(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def admit(org, name, opts) when is_binary(org) and is_binary(name) do
    with :ok <- require_installed(org),
         :ok <- validate_name(name) do
      Fleet.Project.Declaration.refute_unloadable_card("#{org}/#{name}", opts)
    end
  end

  # L'ORG EST UNE DECLARATION, PAS UNE DEDUCTION. Les verbes de creation la recoivent ou refusent en
  # nommant ce qui est installe — le meme refus que le guichet, pour que les deux portes disent la
  # meme chose. Les verbes qui ont une SOURCE (un depot, un catalogue nomme) la lisent d'elle.
  @doc false
  @spec required_org(keyword()) :: {:ok, String.t()} | {:error, term()}
  def required_org(opts) do
    case Keyword.get(opts, :org) do
      org when is_binary(org) and org != "" -> {:ok, org}
      _ -> {:error, {:catalogue_required, installed_orgs()}}
    end
  end

  @doc """
  The single not-installed refusal — ONE atom, ONE payload shape, for every caller inside and
  outside this module.

  ## Why the payload is a SENTENCE and not the installed list

  Two sites answering the same atom with different third elements — a LIST of installed names from
  the local guards, a gestures STRING from the forge preflight — leave a caller holding
  `{:catalogue_not_installed, name, x}` unable to know which it has: an ambiguity moved down one
  level instead of removed. ⚖ The ACTION is identical in both cases (a
  forge admin installs it), and an inventory is only worth printing inside a sentence that says
  what to do with it. The sentence carries the inventory.

  Public so the MCP delegation door cannot grow a second wording of it: two phrasings of one
  refusal is how the vocabulary split in the first place.
  """
  @spec catalogue_not_installed(String.t()) ::
          {:error, {:catalogue_not_installed, String.t(), String.t()}}
  def catalogue_not_installed(name) do
    installed = installed_orgs()

    {:error,
     {:catalogue_not_installed, name,
      "the catalogue '#{name}' is not installed on this box (installed: " <>
        "#{Enum.join(installed, ", ")}). A project outside an installed catalogue is INVISIBLE — " <>
        "the poller only discovers on installed orgs. An admin installs it, inside the box: " <>
        "`lcars catalogue install #{name}`."}}
  end

  @doc false
  @spec require_installed(String.t()) :: :ok | {:error, term()}
  def require_installed(name) do
    if name in installed_orgs(), do: :ok, else: catalogue_not_installed(name)
  end

  # LE DEPOT N'EST PAS A NOUS, et c'est ce qui change tout par rapport aux deux autres verbes :
  # `adopt` et `import_external` CREENT le repo, donc leur compensation le supprime en entier.
  # Ici il preexiste, on ne peut donc defaire QUE ce qu'on a soi-meme pousse — d'ou l'inventaire
  # remonte par `ensure_writer_faces/5`.
  @doc false
  @spec finish_import(String.t(), map(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def finish_import(full_name, dirs, name, opts) do
    with {:ok, url} <- Repo.repo_url(full_name, opts),
         :ok <- Faces.clone_main(url, dirs.code) do
      case Faces.ensure_writer_faces(full_name, url, dirs, name, opts) do
        {:ok, published} -> lock_and_announce(full_name, dirs, published, opts)
        {:error, reason, published} -> Faces.undo_published(full_name, published, reason, opts)
      end
    end
  end

  @doc false
  @spec lock_and_announce(String.t(), map(), [String.t()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def lock_and_announce(full_name, dirs, published, opts) do
    case Faces.lock_main(full_name, opts) do
      :ok ->
        Logger.info(
          "ProjectOnboard: #{full_name} imported — main=#{dirs.code}, " <>
            "#{Fleet.Layout.ops_branch()}=#{dirs.ops}, #{Fleet.Layout.workshop_branch()}=#{dirs.workshop}"
        )

        {:ok, onboard_result(full_name, dirs, opts)}

      {:error, reason} ->
        Faces.undo_published(full_name, published, reason, opts)
    end
  end

  @doc false
  @spec with_ci_stance(String.t(), keyword()) :: keyword()
  def with_ci_stance(repo, opts),
    do: Keyword.put_new(opts, :ci_stance, ci_stance(repo, opts))

  @doc false
  @spec ci_stance(String.t(), keyword()) :: atom()
  def ci_stance(repo, opts) do
    case Keyword.get(opts, :workflow_map) do
      card when is_binary(card) and card != "" ->
        loader_opts =
          case Keyword.take(opts, [:workflow_maps_root]) do
            [] -> Fleet.Workflow.Loader.card_opts_for_repo(repo)
            given -> given
          end

        try do
          Roles.ci(Fleet.Workflow.Loader.load!(card, loader_opts))
        rescue
          _ -> :required
        end

      _ ->
        :required
    end
  end

  @doc false
  @spec ensure_ci_workflows(String.t(), String.t(), keyword(), String.t()) ::
          :ok | {:error, term()}
  def ensure_ci_workflows(proj_dir, name, opts, msg) do
    case Scaffold.ci_workflows(proj_dir, name, opts) do
      {:ok, []} ->
        :ok

      {:ok, added} ->
        Logger.info(
          "ProjectOnboard: rail CI pose sur un depot importe — #{Enum.join(added, ", ")}"
        )

        Faces.commit(proj_dir, msg)

      {:error, _} = err ->
        err
    end
  end

  # A present declaration is LEFT AS-IS (the burn validates loudly; adopt does not overwrite the
  # user's engraving) — an absent one is written from the relayed declaration (or the honest undeclared
  # default) and committed, BEFORE the single main push (v2-1 of the 6-16/6-31 plan: pushed
  # AFTER, it would never reach the forge and both lock_main reads would fall back to the
  # default-card jury in silence).
  @doc false
  @spec ensure_declaration(String.t(), String.t(), keyword(), String.t()) ::
          :ok | {:error, term()}
  def ensure_declaration(
        proj_dir,
        full_name,
        opts,
        msg \\ "chore(adopt): déclaration de criticité (.lcars.json)"
      ) do
    if File.exists?(Path.join(proj_dir, Fleet.Layout.project_declaration_file())) do
      :ok
    else
      with :ok <- write_declaration(proj_dir, full_name, opts) do
        Faces.commit(proj_dir, msg)
      end
    end
  end

  # ─── LE DEPOT SE NOMME, IL NE SE DEDUIT PAS ─────────────────────────────────────────────────────
  #
  # ⚠ L'ENTONNOIR, ET SON ARGUMENT EST POSITIONNEL EXPRES. L'ecriture d'une declaration resout la
  # carte dans le catalogue DU PROJET, qu'elle apprend par les opts. Sans lui, elle la cherche dans
  # le catalogue RACINE : le guichet presente les cartes d'un catalogue, l'agent en choisit une, et
  # le refus enumere celles d'un AUTRE. Une porte qui valide puis ecrit ne peut pas poser la
  # question a deux catalogues.
  #
  # POURQUOI UN POSITIONNEL ET PAS UNE CLE : une cle optionnelle s'oublie, et son oubli est
  # SILENCIEUX — litteralement le defaut qu'on ferme ici. L'appele ne peut pas l'exiger de son cote,
  # ayant des appelants legitimes qui prennent le catalogue racine a bon droit ; ce module, lui, le
  # peut, parce qu'ICI l'ignorer est toujours un defaut. Le compilateur devient le garde.
  #
  # ⚠ LA FUSION SE FAIT ICI ET APRES, jamais dans l'appelant : `revision_write_opts/2` reconstruit
  # une liste NEUVE et jetterait un `repo:` pose en amont. Fusionne au dernier moment, il survit a
  # tout ce que les appelants font de leurs options.
  @doc false
  @spec write_declaration(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def write_declaration(proj_dir, full_name, opts) do
    Fleet.Project.Declaration.write(proj_dir, Keyword.put(opts, :repo, full_name))
  end

  @doc false
  @spec require_on_machine(String.t(), String.t()) :: :ok | {:error, term()}
  def require_on_machine(full_name, proj_dir) do
    if File.dir?(proj_dir), do: :ok, else: {:error, {:not_on_machine, full_name}}
  end

  # 6-079 — LA CHARTE EST UNE VALEUR, PLUS UN LITTERAL RECOPIE. Toute la non-collision de l'espace
  # projet sur disque repose sur elle : `Fleet.Layout.project_slug/1` n'est pas injective, et ce qui
  # rend la collision inatteignable est que cette charte est STRICTEMENT INCLUSE dans ce que le slug
  # preserve. `Fleet.LayoutTest` epinglait cette inclusion — contre SA PROPRE COPIE du motif, donc
  # sans rien tenir : elargir la charte ici ne le faisait pas rougir, alors que son commentaire
  # l'affirmait. Une source, lue des deux cotes.
  @name_re ~r/^[a-z0-9][a-z0-9-]*[a-z0-9]$/

  @doc false
  @spec name_charset() :: Regex.t()
  def name_charset, do: @name_re

  @doc false
  @spec validate_name(String.t()) :: :ok | {:error, term()}
  def validate_name(name) do
    if Regex.match?(@name_re, name),
      do: :ok,
      else: {:error, {:invalid_name, name}}
  end
end
