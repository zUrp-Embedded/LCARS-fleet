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

  alias Fleet.Forge.Client, as: ForgeClient
  alias Fleet.Project.GitOps
  alias Fleet.Project.Roles

  # Content + writing of the scaffold (pure templates, one subtree per face) — extracted:
  # no dependency on the orchestration, onboard calls it at the right moments of its sequence.
  alias Fleet.Project.Onboard.Scaffold

  require Logger

  # Derived from the single authority of the container layout (Fleet.Layout).
  @code_root Fleet.Layout.code_root()
  @ops_root Fleet.Layout.ops_root()
  @workshop_root Fleet.Layout.workshop_root()
  # onboarding author = the system (it GENERATES the scaffold) — not the arch (mere relay), not the user
  # (wrote nothing). committer = the human (git config) traces who initiated.
  # System identity: SINGLE AUTHORITY = Fleet.Credentials.ForgeIdentity.system_identity/0
  # (a name/email retyped here would be a divergence in the making with the gate).
  defp onboard_author, do: Fleet.Credentials.ForgeIdentity.system_identity()

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

  @doc """
  Onboard the project `name` (kebab-case slug). `opts`:

    * `:org`           — forge org (default `"fleet"`)
    * `:description`   — repo description (default `""`)
    * `:pitch`         — pitch phrase (README/spec scaffold; default = description)
    * `:code_root` / `:ops_root` / `:workshop_root` — FS roots, one per face (defaults:
      `/home/projects`, `/home/projects.ops`, `/home/projects.workshop`)
    * `:base_url` / `:token` — forge override (otherwise config `:lcars_fleet, :pilot_forge`)

  Returns `{:ok, %{repo, project_dir, work_dir, doc_dir}}` or `{:error, term()}` (fail-fast) —
  one key per face. On an error return AND on an exception the sequence compensates automatically:
  the forge repo and all three local dirs are removed so a clean retry is possible (see
  `compensate_onboard/5` and `guarded_finish/5`; the two exits are covered because only one used
  to be, and the uncovered one left a repo on the forge with two of its faces built).

  What still skips the unwind is a BEAM crash — the process dies with the `catch`, not through it.
  Its residue is recoverable agent-side via `delete_project(force: true)`: the dirs it can leave are
  either origin-carrying (identity provable) or empty (provable as debris), which are exactly the
  two proofs that teardown accepts — no host-side `rm` in the loop.
  """
  @spec onboard(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def onboard(name, opts \\ []) when is_binary(name) do
    dirs = face_dirs(name, opts)

    # `admit/3` porte le preambule commun aux cinq verbes d'entree — dont le refus de carte, qui
    # doit tomber AVANT que le depot existe : la regle vit chez le seul ecrivain
    # (`Declaration.write/2`) pour qu'aucune porte ne la contourne, et ici on lui evite de refuser
    # apres une creation, donc une compensation.
    with {:ok, org} <- required_org(opts),
         :ok <- admit(org, name, opts),
         :ok <- ensure_catalogue_org_on_forge(org, opts),
         :ok <- refute_existing_or_converge("#{org}/#{name}", dirs, opts),
         {:ok, full_name} <- create_repo(name, org, opts) do
      case guarded_finish(full_name, dirs, name, opts) do
        {:ok, result} ->
          {:ok, result}

        {:error, reason} = err ->
          compensate_onboard(full_name, dirs, reason, opts)
          err
      end
    else
      {:already_satisfied, result} -> {:ok, result}
      {:error, _} = err -> err
    end
  end

  # `finish_onboard` has TWO ways out and compensation covered ONE. An exception — a face root that
  # cannot be created, a git binary gone, a full disk — walks straight past the `case` above, and
  # what it leaves is a repo on the forge plus however many face trees were already built.
  #
  # Measured on a fresh bench, and it is the shape of the whole failure: `/home/projects.doc` does
  # not exist, `mkdir_p!` raises, and the forge repo, the cloned-and-committed code face and the
  # initialised ops face ALL survive. The caller gets `tool_crashed` and no way to know a cleanup
  # is owed; the next attempt then meets the 409/refute_existing walls this compensation exists to
  # prevent.
  #
  # RE-RAISED, NOT SWALLOWED. The crash stays a crash, with its kind and its stacktrace — only the
  # machine is left clean. Converting it to `{:error, _}` here would dress an unforeseen failure as
  # a handled one, and a caller cannot tell those apart afterwards.
  defp guarded_finish(full_name, dirs, name, opts) do
    finish_onboard(full_name, dirs, name, opts)
  catch
    kind, payload ->
      compensate_onboard(full_name, dirs, {kind, payload}, opts)
      :erlang.raise(kind, payload, __STACKTRACE__)
  end

  defp finish_onboard(full_name, dirs, name, opts) do
    with :ok <- Fleet.Forge.WriteSpacing.gap(opts),
         {:ok, url} <- repo_url(full_name, opts),
         :ok <- seed_protocol_labels(full_name, opts),
         :ok <- clone_main(url, dirs.code),
         :ok <- Scaffold.main(dirs.code, name, with_ci_stance(full_name, opts)),
         :ok <- write_declaration(dirs.code, full_name, opts),
         :ok <- commit(dirs.code, "chore(onboard): scaffold initial du projet"),
         :ok <- push(dirs.code, "main", false),
         :ok <- Fleet.Forge.WriteSpacing.gap(opts),
         :ok <-
           build_writer_face(
             full_name,
             url,
             dirs.ops,
             Fleet.Layout.ops_branch(),
             "ops",
             name,
             opts
           ),
         :ok <- Fleet.Forge.WriteSpacing.gap(opts),
         :ok <-
           build_writer_face(
             full_name,
             url,
             dirs.workshop,
             Fleet.Layout.workshop_branch(),
             "workshop",
             name,
             opts
           ),
         :ok <- lock_main(full_name, opts) do
      Logger.info(
        "ProjectOnboard: #{full_name} ready — main=#{dirs.code}, " <>
          "#{Fleet.Layout.ops_branch()}=#{dirs.ops}, #{Fleet.Layout.workshop_branch()}=#{dirs.workshop}"
      )

      {:ok, onboard_result(full_name, dirs, opts)}
    end
  end

  # Build-and-publish, for a repo we just created: the branch cannot pre-exist, so unlike
  # `ensure_face/7` there is nothing to clone.
  defp build_writer_face(_full_name, url, dir, branch, template, name, opts) do
    with :ok <- init_face(dir, url, branch),
         :ok <- Scaffold.face(dir, template, name, opts),
         :ok <- commit(dir, "chore(onboard): init #{branch}") do
      publish_face(dir, branch)
    end
  end

  defp onboard_result(full_name, dirs, opts) do
    %{
      repo: full_name,
      project_dir: dirs.code,
      work_dir: dirs.ops,
      doc_dir: dirs.workshop,
      architect: ensure_architect(full_name, opts)
    }
  end

  defp compensate_onboard(full_name, dirs, reason, opts) do
    forge =
      case delete_forge(full_name, opts) do
        {:ok, verdict} -> verdict
        {:error, e} -> {:delete_failed, e}
      end

    Logger.warning(
      "ProjectOnboard: onboard #{full_name} FAILED (#{inspect(reason)}) — compensated: " <>
        "forge #{inspect(forge)}, project_dir #{inspect(compensate_dir(dirs.code))}, " <>
        "work_dir #{inspect(compensate_dir(dirs.ops))}, " <>
        "doc_dir #{inspect(compensate_dir(dirs.workshop))} " <>
        "(a clean retry is possible; incomplete legs above must be cleared first)"
    )
  end

  defp compensate_dir(dir) do
    if File.exists?(dir) do
      case nuke_dir(dir) do
        :ok -> :removed
        {:error, _} -> :removal_incomplete
      end
    else
      :absent
    end
  end

  # TROIS ISSUES, ET LA TROISIEME N'EST NI UN SUCCES NI UN ECHEC. Un appelant qui n'a pas de fleet
  # sous la main — la porte de reconvergence tourne dans un `eval`, donc dans une VM qui a CHARGE
  # l'app sans la demarrer — ne peut pas assurer d'architecte : il n'y a aucun superviseur a qui le
  # demander. Le dire « failed » accuserait le projet d'un defaut qu'il n'a pas ; le dire « up »
  # serait un mensonge sur un pod qui n'existe pas. `deferred` dit ce qui est vrai, et qui prend la
  # suite : le poller de la fleet assure l'architecte de chaque projet qu'il sert.
  defp ensure_architect(repo, opts) do
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
    case installed_orgs() do
      [org | _] -> org
      [] -> "fleet"
    end
  end

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
  defp required_org(opts) do
    case Keyword.get(opts, :org) do
      org when is_binary(org) and org != "" -> {:ok, org}
      _ -> {:error, {:catalogue_required, installed_orgs()}}
    end
  end

  @doc """
  MIGRE un projet d'un catalogue vers un autre — le transfert forge ET le repointage local.

  L'org d'un projet EST le nom de son catalogue : migrer, c'est donc transferer le depot dans l'org
  du catalogue cible. Le transfert est un seul appel et tout survit (issues, PR, labels, protection,
  attribution) ; ce qui NE suit pas est ce qu'on ne veut pas voir suivre — les droits se REDERIVENT
  des teams de l'org d'arrivee, donc les roles de l'ancien catalogue perdent l'ecriture et leur
  historique reste a leur nom, ce qui est la verite : ce travail-la a bien ete fait par ce catalogue.

  Les trois faces locales sont clees par le NOM du projet, pas par l'org : elles survivent. Mais leur
  `origin` pointe l'ancienne URL et ne vit plus que par la redirection `301` de Gitea — les repointer
  fait partie du geste, sans quoi la migration laisse un projet qui marche par accident.

  Ce que cette fonction NE fait pas, et ne peut pas faire : attendre la quiescence. Elle n'en a pas
  besoin — un catalogue ne change pas sous un projet vivant (les images gelent au boot, et le boot
  refuse une carte nommant un role absent). Ce qui reste est le cas ou l'operateur migre pendant
  qu'un step-run est ouvert : la PR en vol a ete produite par un role que le nouveau catalogue ne
  porte pas, et c'est a lui de le savoir.
  """
  @spec migrate(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def migrate(full_name, target_catalogue, opts \\ [])
      when is_binary(full_name) and is_binary(target_catalogue) do
    name = Fleet.Layout.project_name(full_name)
    dirs = face_dirs(name, opts)

    # La loi d'ordre, la meme qu'a l'import : les refus PURS et LOCAUX d'abord, la forge ensuite.
    # `refute_store` lit le manifeste de la cible ; le faire avant `require_target_installed` ferait
    # payer un aller-retour a une migration refusee sur un fait que le disque portait deja.
    with :ok <- refute_same_catalogue(full_name, target_catalogue),
         :ok <- require_target_installed(target_catalogue),
         :ok <- refute_store(full_name, opts),
         {:ok, new_full_name} <-
           repo_mod(opts).transfer_repo(full_name, target_catalogue, fc_opts(opts)),
         {:ok, url} <- repo_url(new_full_name, opts),
         {:ok, repointed} <- repoint_faces(dirs, url) do
      Logger.info(
        "ProjectOnboard: #{full_name} MIGRE vers #{new_full_name} — " <>
          "#{length(repointed)}/#{map_size(dirs)} faces repointees sur #{url}"
      )

      {:ok,
       %{
         repo: new_full_name,
         from: full_name,
         faces: Enum.reverse(repointed),
         absent: Enum.sort(Map.values(dirs) -- repointed)
       }}
    end
  end

  defp refute_same_catalogue(full_name, target) do
    case String.split(full_name, "/") do
      [^target | _] -> {:error, {:already_in_catalogue, target}}
      _ -> :ok
    end
  end

  @doc """
  Refuses to treat a catalogue's STORE as a project — `:ok` when the repo is not one.

  ## Why the explicit doors need this and `reconcile` does not

  `reconcile/2` is already guarded, and better than by a name: it asks every repo *"do you carry a
  project declaration (`.lcars.json` on `main`)?"* — a guard by PROPERTY, which holds without ever
  knowing the word `catalogue`.

  The doors where an ADMIN TYPES THE NAME have no such shield. An admin imports `web/_catalogue` to
  see what happens, the fleet lays three faces and writes `.lcars.json` at its root — and the store
  becomes a declared project. The property guard then turns around: from the next pass on, it
  DEFENDS the property that was laid by mistake. That is why this is a refusal at the door and not
  a repair afterwards.

  ## The discriminant is the identity, and an unknown is a REFUSAL

  `owner == manifest.name`, read from the repo's own `catalogue.yaml` — the same question
  `Fleet.Application.CatalogueDeposits.split/2` asks, so the two cannot disagree about what a
  store is.

  A `:not_found` is an ANSWER (not a catalogue — the overwhelmingly common case, and silent). Any
  OTHER read failure is an ABSENCE of an answer, and it refuses: importing a store is expensive and
  self-defending, retrying an import is free. ⚖ user: an explicit failure beats an ambiguous
  success. The refusal for that case says what it could not read, never that this IS a store — a
  refusal that named the wrong cause would send the admin to delete a repo that is fine.
  """
  @spec refute_store(String.t(), keyword()) ::
          :ok
          | {:error, {:repo_is_catalogue_store | :store_check_unreadable, String.t(), String.t()}}
  def refute_store(full_name, opts \\ []) when is_binary(full_name) do
    owner = full_name |> String.split("/", parts: 2) |> hd()

    case declared_catalogue_name(full_name, opts) do
      {:ok, ^owner} ->
        {:error,
         {:repo_is_catalogue_store, full_name,
          "'#{full_name}' is the STORE of the catalogue '#{owner}' — the source the fleet pushed " <>
            "into its own org, not a project. Laying project faces on it would write a project " <>
            "declaration into a catalogue's source, and every later pass would then read it as a " <>
            "project. To (re)install that catalogue, inside the box: " <>
            "`lcars catalogue install #{owner}`."}}

      {:ok, _other} ->
        :ok

      :not_a_catalogue ->
        :ok

      {:error, reason} ->
        {:error,
         {:store_check_unreadable, full_name,
          "could not read '#{full_name}''s #{Fleet.Catalogue.manifest_file()} " <>
            "(#{inspect(reason)}), so it is unknown whether this repo is a catalogue's store. NOT " <>
            "refused as one — refused as UNREADABLE. Retry; if it persists, the forge is the thing " <>
            "to look at."}}
    end
  end

  @doc """
  Refuses to CREATE a repo at the address the fleet pushes a store to — `:ok` otherwise.

  ## Why this door asks a different question, and why the answer is a name

  `refute_store/2` asks an EXISTING repo what it declares. `adopt_project/2` publishes a disk-only
  project to a repo that does not exist yet, so there is nothing to ask. What it can collide with is
  the ADDRESS: `push_store` force-pushes there, so a project adopted at that name is a project the
  next `catalogue install` silently overwrites.

  `require_forge_absent/2` already covers the case where the store is there — but the dangerous
  window is precisely the one it does not see: the org exists, its catalogue is NOT installed yet,
  nothing occupies the name, and the collision arrives later.

  Checking a name here is not the defect this chantier closed. That one answered "what IS this repo"
  with a name; this one answers "may I WRITE here", which is what an address is for. Cf.
  `Fleet.Catalogue.store_repo/0`, which says it and says why in the same breath.
  """
  @spec refute_store_address(String.t(), String.t()) ::
          :ok | {:error, {:store_address, String.t(), String.t()}}
  def refute_store_address(full_name, name) do
    store = Fleet.Catalogue.store_repo()

    if name == store do
      {:error,
       {:store_address, full_name,
        "'#{name}' is the repo name the fleet pushes a catalogue's source under, so " <>
          "'#{full_name}' is where `catalogue install` force-pushes. A project adopted there is a " <>
          "project the next install overwrites without a word. Rename the local project and adopt " <>
          "it again."}}
    else
      :ok
    end
  end

  # LA REGLE DU MANIFESTE N'EST PAS RECOPIEE ICI. `Fleet.Catalogue` la porte — colonne zero,
  # guillemets, commentaire de fin de ligne — et une seconde ecriture de la meme regle serait
  # exactement le defaut que ce garde ferme, un cran plus bas : deux lecteurs d'un discriminant est
  # un discriminant qui derive le jour ou un seul est corrige. Elle vit dans la FONDATION parce que
  # l'autre lecteur (`Fleet.Application.CatalogueDeposits`) est derriere une frontiere que
  # `Fleet.Project` ne peut pas referencer — et on n'elargit pas une frontiere pour avoir raison.
  defp declared_catalogue_name(full_name, opts) do
    fc = Keyword.put(fc_opts(opts), :ref, "HEAD")

    case files_mod(opts).get_file(full_name, Fleet.Catalogue.manifest_file(), fc) do
      {:ok, %{content: yaml}} ->
        case Fleet.Catalogue.manifest_name(yaml) do
          {:ok, name} -> {:ok, name}
          {:error, :no_name_in_manifest} -> :not_a_catalogue
        end

      {:error, :not_found} ->
        :not_a_catalogue

      {:error, _} = err ->
        err
    end
  end

  # Meme refus que l'import, et pour la meme raison : migrer vers un catalogue que cette boite n'a
  # pas produirait un projet dont personne ne sait lire le metier — et le poller ne decouvre que sur
  # les orgs des catalogues INSTALLES, donc le projet deviendrait invisible, pas casse.
  #
  # ⚠ DEUX ETATS, ET PAS TROIS. Une declaration locale d'ACTIVITE serait un troisieme etat entre
  # « le materiel est la » et « la forge le porte », tenu a la main. Deux etats qui repondent a la
  # meme question finissent par se contredire, et l'ecart tue une flotte entiere : mesure au banc,
  # declare actif et jamais installe, le poller derive ses orgs de la declaration et cherche des
  # jetons de role que personne n'a frappes.
  #
  # Ce qui reste tient en une phrase : le materiel est ICI ou il n'y est pas, et il n'y arrive que
  # par la forge. Le pendant forge (le preflight, plus bas) n'est PAS un
  # troisieme etat — c'est le meme fait mesure a sa source, pour le cas ou l'install a ete
  # interrompu entre l'org et le materiel.
  defp require_target_installed(target), do: require_installed(target)

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

  defp require_installed(name) do
    if name in installed_orgs(), do: :ok, else: catalogue_not_installed(name)
  end

  # Rend les faces REELLEMENT repointees, pas celles qu'on visait. La difference n'est pas
  # cosmetique : sur un banc, ce geste annonce « trois faces repointees » sur une boite ou les
  # trois sont absentes — la moitie forge est juste, et le rapport ment. Un appelant qui
  # affiche la liste visee affirme un travail qu'il n'a pas fait.
  defp repoint_faces(dirs, url) do
    Enum.reduce_while(Map.values(dirs), {:ok, []}, fn dir, {:ok, done} ->
      if File.dir?(Path.join(dir, ".git")) do
        case GitOps.run(["-C", dir, "remote", "set-url", "origin", url], auth: false) do
          :ok -> {:cont, {:ok, [dir | done]}}
          {:error, reason} -> {:halt, {:error, {:remote_repoint_failed, dir, reason}}}
        end
      else
        # Une face absente n'est pas un echec : un projet peut n'avoir jamais ete ouvert ICI. Le
        # transfert forge a deja eu lieu, et refuser maintenant laisserait les deux moities en
        # desaccord. Elle n'entre simplement pas dans le compte rendu.
        {:cont, {:ok, done}}
      end
    end)
  end

  @doc """
  Porte RELEASE de la migration : rend un verdict sur stdout et sort par le CODE.

      bin/lcars_fleet eval 'Fleet.Project.Onboard.eval_migrate("fleet/vitrine", "web")'

  Meme forme que `CatalogueVerify.eval_main/1`, et pour la meme raison : `bin/lcars` n'a aucun acces
  forge, et lui en donner un ferait d'une commande locale un acteur distant. La boite, elle, porte
  deja les jetons et la config.
  """
  @spec eval_migrate(String.t(), String.t()) :: no_return()
  def eval_migrate(full_name, target) when is_binary(full_name) and is_binary(target) do
    # `eval` LOADS the app, it does not START it: the forge HTTP pool has no supervisor here, and
    # the transfer died on `unknown registry: Fleet.Forge.Finch`. Started standalone, like the mix
    # task that already does it — never `app.start`, because a second fleet must not boot from a
    # tool. The door needs exactly this one process and starts exactly it.
    {:ok, _sup} = Supervisor.start_link([Fleet.Forge.finch_spec()], strategy: :one_for_one)

    # Le rapport de cette porte est lu par un operateur, pas parse — mais un « migre : a -> b »
    # entrelace d'avertissements du transfert se lit tout aussi mal. Meme regle, meme geste.
    Fleet.ReleaseDoor.claim_stdout!()

    case migrate(full_name, target) do
      {:ok, %{repo: new_name, faces: faces, absent: absent}} ->
        IO.puts("migre : #{full_name} -> #{new_name}")
        for d <- faces, do: IO.puts("  origin repointe : #{d}")

        # Une face jamais ouverte ICI est normale, et le taire ferait lire « rien a repointer »
        # comme « tout est repointe ». On dit ce qu'on n'a pas fait.
        for d <- absent, do: IO.puts("  face absente (jamais ouverte ici) : #{d}")

        System.halt(0)

      {:error, {:catalogue_not_installed, cat, gestures}} ->
        IO.puts(
          :stderr,
          "REFUSE : le catalogue #{inspect(cat)} n'est pas installe sur cette boite."
        )

        IO.puts(:stderr, "  #{gestures}")
        System.halt(1)

      {:error, {:already_in_catalogue, cat}} ->
        IO.puts(:stderr, "REFUSE : #{full_name} est deja dans le catalogue #{inspect(cat)}.")
        System.halt(1)

      # Gitea demande le PROPRIETAIRE du depot pour un transfert — pas l'admin, mesure : un compte
      # membre avec write recoit ce 403 mot pour mot. Le compte systeme n'est proprietaire d'aucune
      # org, par construction : c'est une identite de service, pas une autorite d'onboarding. Nomme,
      # parce qu'un tuple HTTP brut envoie l'operateur debugger la porte au lieu de lire la reponse.
      {:error, {:http, 403, %{"message" => "user should be the owner of the repo"}}} ->
        IO.puts(:stderr, "REFUSE : le compte de service n'est pas proprietaire de #{full_name}.")

        IO.puts(
          :stderr,
          "  un transfert Gitea exige le PROPRIETAIRE du depot (pas l'admin) — le compte qui"
        )

        IO.puts(:stderr, "  fait tourner la fleet est membre, pas proprietaire.")
        IO.puts(:stderr, "  il faut une identite de classe onboarding : c'est une decision de")
        IO.puts(:stderr, "  deploiement, pas un reglage de cette commande.")
        System.halt(1)

      {:error, reason} ->
        IO.puts(:stderr, "ECHEC : #{inspect(reason)}")
        System.halt(2)
    end
  end

  @doc """
  Porte RELEASE de la reconvergence de `/home` : la forge dit quels projets existent, le disque suit.

      bin/lcars_fleet eval 'Fleet.Project.Onboard.eval_reconcile(:check)'
      bin/lcars_fleet eval 'Fleet.Project.Onboard.eval_reconcile(:apply)'

  L'INVENTAIRE N'EXISTE QUE SUR LA FORGE, et c'est ce qui rend cette porte necessaire.
  `list_projects/1` enumere le DISQUE (`code_root`) : sur une boite neuve — ou apres un nuke, ou
  pour un second humain qui arrive sur une fleet deja peuplee — il n'y a rien a enumerer, alors que
  les projets, eux, sont intacts. Aucun verbe n'est ecrit ici : `import/2` est deja le rail
  forge→boite et deja idempotent. Ce qui n'existe nulle part ailleurs, c'est la LISTE.

  Sortie : un mot par projet, sur une ligne. `check` ne touche rien (`DEJA` / `MANQUE`), `apply`
  importe (`DEJA` / `IMPORTE`). Un projet en echec n'arrete pas les autres — une boite a laquelle il
  manque neuf projets sur dix doit en recuperer neuf, pas zero.

  Codes de sortie : `0` tout converge · `1` au moins un `ECHEC` · `2` au moins un `MANQUE` et aucun
  echec. Le module de provisioning qui joue cette porte lit les LIGNES et rend son propre verdict ;
  ces codes sont la pour l'operateur qui l'appelle a la main.
  """
  @spec eval_reconcile(:check | :apply) :: no_return()
  def eval_reconcile(mode) when mode in [:check, :apply] do
    # Meme raison qu'`eval_migrate` : `eval` CHARGE l'app, il ne la demarre pas, et le premier appel
    # forge meurt alors en `unknown registry: Fleet.Forge.Finch`.
    {:ok, _sup} = Supervisor.start_link([Fleet.Forge.finch_spec()], strategy: :one_for_one)

    # Le module qui lit cette porte parse un mot par ligne : `stdout` est un format de fil, pas une
    # console. Le pourquoi et la mesure vivent dans `Fleet.ReleaseDoor`.
    Fleet.ReleaseDoor.claim_stdout!()

    entries = reconcile(mode)

    case entries do
      [] -> IO.puts("RIEN aucun projet declare dans les catalogues installes")
      _ -> Enum.each(entries, &IO.puts(reconcile_line(&1)))
    end

    cond do
      Enum.any?(entries, &(&1.status == :failed)) -> System.halt(1)
      Enum.any?(entries, &(&1.status == :missing)) -> System.halt(2)
      true -> System.halt(0)
    end
  end

  @doc """
  L'etat de reconvergence de chaque projet des catalogues installes — la porte sans la sortie.

  Rend une liste de `%{repo:, status:, reason:}`. `:check` lit (`:present` / `:missing`), `:apply`
  agit (`:already` / `:imported`), les deux rendent `:failed` avec sa raison.

  LE FILTRE EST `.lcars.json` SUR `main`, et il ne se derive pas du nom. Une org de catalogue porte
  aussi des depots qui ne sont pas des projets — a commencer par le `catalogue` qui la signe — et les
  importer creerait trois faces autour d'un depot qu'aucun humain n'a ouvert. Mesure sur la forge du
  banc : un projet rend `200` sur ce fichier, le magasin rend `404`.

  La liste de ces depots n'est PAS fermee, et c'est la raison d'etre du filtre par propriete : un
  humain depose ce qu'il veut dans son org, et un garde qui enumererait des noms devrait etre corrige
  a chaque depot nouveau — et a chaque depot retire, ce qui arrive aussi. Le filtre par propriete ne
  bouge d'aucune ligne dans les deux cas.
  """
  @spec reconcile(:check | :apply, keyword()) :: [
          %{repo: String.t(), status: atom(), reason: term()}
        ]
  def reconcile(mode, opts \\ []) when mode in [:check, :apply] do
    Enum.flat_map(installed_orgs(), &reconcile_org(&1, mode, opts))
  end

  # UNE ORG ILLISIBLE EST UN ECHEC, PAS UNE ORG VIDE. Rendre `[]` ferait lire « rien a importer » a
  # un `check` qui n'a simplement pas su demander, et les autres orgs, elles, restent lisibles.
  defp reconcile_org(org, mode, opts) do
    case repo_mod(opts).list_org_repos(org, fc_opts(opts)) do
      {:ok, names} ->
        names |> Enum.sort() |> Enum.flat_map(&reconcile_repo(&1, mode, opts))

      {:error, reason} ->
        [%{repo: "#{org}/*", status: :failed, reason: {:org_unreadable, reason}}]
    end
  end

  defp reconcile_repo(full_name, mode, opts) do
    case declared_project?(full_name, opts) do
      {:ok, true} -> [converge_project(full_name, mode, opts)]
      {:ok, false} -> []
      {:error, reason} -> [%{repo: full_name, status: :failed, reason: reason}]
    end
  end

  defp declared_project?(full_name, opts) do
    file = Fleet.Layout.project_declaration_file()
    fc = Keyword.put(fc_opts(opts), :ref, "main")

    case files_mod(opts).get_file(full_name, file, fc) do
      {:ok, _} -> {:ok, true}
      {:error, :not_found} -> {:ok, false}
      # Une forge muette ne prouve pas l'absence de declaration : la nommer ici evite qu'un projet
      # bien reel disparaisse de l'inventaire sur un timeout.
      {:error, reason} -> {:error, {:declaration_unreadable, file, reason}}
    end
  end

  defp converge_project(full_name, :check, opts) do
    dirs = face_dirs(Fleet.Layout.project_name(full_name), opts)

    # LES TROIS FACES, PAS UNE. Un projet dont il manque une seule face n'est pas ouvert ici : son
    # architecte monterait un chemin absent. `check` ne tranche pas plus finement — il dit qu'il y a
    # a faire, et `apply` dit quoi, avec le refus exact d'`import/2` si l'etat est a moitie pose.
    if Enum.all?([dirs.code, dirs.ops, dirs.workshop], &File.dir?/1),
      do: %{repo: full_name, status: :present, reason: nil},
      else: %{repo: full_name, status: :missing, reason: nil}
  end

  # ⚠ L'ARCHITECTE NE S'ASSURE PAS D'ICI, ET CE N'EST PAS UN RACCOURCI. Mesure au banc : l'import
  # pose ses trois faces puis MEURT sur
  # `GenServer.call(Fleet.Spawner.Supervisor, …) ** (EXIT) no process` — `eval` charge l'app, il ne
  # la demarre pas, donc aucun superviseur de spawn n'existe dans cette VM. La convergence
  # aboutit sur le disque et rend un echec, sans compensation, a la derniere jambe.
  #
  # Ce qui prend la suite existe deja : le poller de la fleet assure l'architecte de chaque projet
  # qu'il sert (`Architect.ensure_alive/2`, a chaque tour). La reconvergence pose les FACES ; les
  # pods appartiennent au cycle de vie d'une fleet vivante, qui n'est pas celui d'un provisionnement.
  defp converge_project(full_name, :apply, opts) do
    opts =
      Keyword.put_new(opts, :ensure_architect, fn _repo, _o ->
        {:deferred, "aucune fleet dans cette VM — le poller l'assure au demarrage"}
      end)

    # `__MODULE__.` obligatoire : `import/2` nu est la forme speciale du compilateur, pas ce verbe.
    case __MODULE__.import(full_name, opts) do
      {:ok, %{idempotent: true}} -> %{repo: full_name, status: :already, reason: nil}
      {:ok, _} -> %{repo: full_name, status: :imported, reason: nil}
      {:error, reason} -> %{repo: full_name, status: :failed, reason: reason}
    end
  end

  defp reconcile_line(%{repo: repo, status: :failed, reason: reason}),
    do: "ECHEC   #{repo} — #{inspect(reason)}"

  defp reconcile_line(%{repo: repo, status: status}) do
    word =
      case status do
        :present -> "DEJA"
        :already -> "DEJA"
        :imported -> "IMPORTE"
        :missing -> "MANQUE"
      end

    "#{String.pad_trailing(word, 7)} #{repo}"
  end

  @doc """
  Imports an existing `owner/name` forge repository without changing its `main` content.

  The repository must belong to the configured org and use `main` as its default branch. The call
  creates the three local faces, creates or clones each writer branch and reapplies branch
  protection.

  On failure it compensates its local artifacts AND the writer branches this attempt pushed —
  those alone: a branch it cloned belonged to the repository already, and a branch whose existence
  it could not read is never written in the first place. When every removal succeeds the caller
  keeps its clean retry and gets the original error unchanged; when one does not, the error becomes
  `{:import_not_compensated, reason, left}`, because a repository that still carries this attempt's
  branches must not be retried as if it were untouched.
  """
  @spec import(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def import(full_name, opts \\ []) when is_binary(full_name) do
    # L'ORG VIENT DU DEPOT, pas d'une option ni d'un defaut. L'argument de ce verbe EST
    # `owner/nom`, et un projet vit dans l'org de son catalogue : le proprietaire NOMME l'org, il
    # n'y a rien a choisir. Un `opts[:org] || default_org()` rendrait le PREMIER catalogue actif, et
    # l'humain serait alors verifie contre l'org d'un autre catalogue que celui du depot.
    org = full_name |> String.split("/") |> List.first()
    name = Fleet.Layout.project_name(full_name)
    dirs = face_dirs(name, opts)

    # ⚠ CE VERBE VERIFIE QUE LA CARTE EST DECLARABLE, COMME LES QUATRE AUTRES. Sans ce controle, un
    # depot importe avec une carte d'atelier (`scope: ticket`) ou une faute de frappe passe ici, la
    # ou les quatre autres refusent.
    # `admit` (local) avant `refute_store` (un aller-retour forge) : la loi d'ordre en trois temps.
    with :ok <- admit(org, name, opts),
         :ok <- refute_store(full_name, opts),
         :ok <- ensure_catalogue_org_on_forge(org, opts),
         :ok <- refute_existing_or_converge(full_name, dirs, opts),
         :ok <- require_default_branch_main(full_name, opts) do
      case finish_import(full_name, dirs, name, opts) do
        {:ok, result} ->
          {:ok, result}

        {:error, reason} = err ->
          Logger.warning(
            "ProjectOnboard: import #{full_name} FAILED (#{inspect(reason)}) — compensated: " <>
              "project_dir #{inspect(compensate_dir(dirs.code))}, " <>
              "work_dir #{inspect(compensate_dir(dirs.ops))}, " <>
              "doc_dir #{inspect(compensate_dir(dirs.workshop))} #{remote_state(reason)}"
          )

          err
      end
    else
      {:already_satisfied, result} -> {:ok, result}
      {:error, _} = err -> err
    end
  end

  # CETTE PHRASE EST LUE, JAMAIS AFFIRMEE. « repo untouched — pre-existing » n'est vrai que tant que
  # rien n'a ete pousse, et `ensure_writer_faces` publie `ops` avant de tenter `workshop` : affirmee,
  # la ligne annoncerait un depot intact au moment precis ou il ne l'est plus.
  defp remote_state({:import_not_compensated, _reason, left}),
    do:
      "(⚠ REPO MUTATED — branches pushed by this attempt SURVIVE: " <>
        "#{inspect(Enum.map(left, &elem(&1, 0)))}; a retry is NOT clean)"

  defp remote_state(_reason), do: "(repo untouched — pre-existing; a clean retry is possible)"

  # LE TROISIEME REFUS, et c'est celui qui empeche le mensonge silencieux. L'org d'un projet EST le
  # nom de son catalogue, et ce lien est fixe pour sa vie : importer `web/vitrine` sur une boite qui
  # n'a pas le catalogue `web` ne doit PAS retomber sur le catalogue local. Le projet tournerait avec
  # les roles, les cartes et les SP d'un autre metier, sans que rien ne le dise — c'est exactement
  # l'etat que le lien fixe existe pour interdire.
  #
  # Le refus NOMME le catalogue manquant et le geste qui le pose, parce qu'un refus qui ne dit pas
  # quoi faire ne se distingue pas d'une panne.
  @doc """
  DEPOT : enrole un depot depuis l'espace PERSONNEL d'un humain vers l'org du catalogue choisi.

  C'est la troisieme porte d'entree, et elle existe parce que les deux autres refusent ce cas par
  construction, chacune pour sa bonne raison :

    * `import/2` ne prend que des depots DEJA dans une org de catalogue (`require_catalogue_installed`)
      et ne filtre donc rien — il n'a pas a le faire ;
    * `import_external/3` exige `https` + un hote de son allowlist, et notre forge est en `http` :
      elle serait refusee sur le SCHEMA. Cette garde borne « depuis quel hote ETRANGER on clone »,
      et un depot personnel sur notre forge n'est pas un hote etranger — c'est une PROVENANCE
      etrangere. Deux notions, deux gardes.

  La frontiere d'adoption n'est donc pas « notre forge / forge externe » mais **« dans une org de
  catalogue / hors org »** : tout ce qui vient d'un espace personnel passe le gate, meme depose par
  un humain de confiance sur notre propre forge. Le transport ne change pas la provenance.

  Le depot source n'est PAS consomme : il reste chez son proprietaire, c'est sa copie.
  """
  @spec import_deposit(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def import_deposit(source, catalogue, opts \\ [])
      when is_binary(source) and is_binary(catalogue) do
    with {:ok, owner, src_name} <- split_repo(source),
         :ok <- refute_source_in_org(owner, source),
         :ok <- require_destination_catalogue(catalogue),
         # LAST of the admission checks: the only one that costs a forge read. The three above
         # answer from the catalogue alone, so a malformed name or an unknown destination is
         # refused without touching the network.
         :ok <- require_public_source(source, opts) do
      name = Keyword.get(opts, :name, src_name)
      full_name = "#{catalogue}/#{name}"
      dirs = face_dirs(name, opts)

      with :ok <- admit(catalogue, name, opts),
           :ok <- ensure_catalogue_org_on_forge(catalogue, opts),
           :ok <- require_machine_absent(full_name, dirs),
           :ok <- require_forge_absent(full_name, opts),
           {:ok, source_url} <- repo_url(source, opts) do
        scratch = external_scratch_dir(name)

        try do
          with :ok <- clone_deposit(source_url, scratch, opts),
               :ok <- adoption_gate(scratch),
               :ok <- normalize_default_branch(scratch),
               {:ok, forge_url} <- repo_url(full_name, opts),
               {:ok, full_name} <- create_empty_repo(name, catalogue, opts) do
            case finish_external(
                   full_name,
                   forge_url,
                   scratch,
                   dirs,
                   name,
                   Keyword.put(opts, :source_host, "depot:#{owner}")
                 ) do
              {:ok, result} ->
                {:ok, Map.put(result, :from, source)}

              {:error, reason} = err ->
                compensate_external(full_name, dirs, reason, opts)
                err
            end
          end
        after
          _ = File.rm_rf(scratch)
        end
      end
    end
  end

  @doc """
  A human's DEPOSIT CANDIDATES: the repos in their personal space that no catalogue org already
  carries under the same name.

  THE LOCATION IS THE STATE: a repo in a personal space is a candidate, a repo in a catalogue org is
  enrolled. So there is no marker, no label and no registry to keep — "is this project in LCARS?"
  is answered by an `ls` on the forge. Multiple catalogues REINFORCE that rather than weaken it:
  whatever the number of orgs, *outside every org* stays one unambiguous location.

  The filter is by NAME because the source repo is NOT consumed — importing takes a copy and leaves
  the original with its owner — so without it every pass would propose the same repo again.

  Each candidate carries whether its NAME is admissible, and the rule when it is not. The name is
  checked here rather than at import alone because the import is too late: the human has already
  pushed everything by then, and learning the rule at that point is learning it after paying for
  it. The listing is the first moment the fleet can say it.
  """
  @spec deposit_candidates(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def deposit_candidates(human, opts \\ []) when is_binary(human) do
    repo = repo_mod(opts)
    fc = fc_opts(opts)

    with {:ok, mine} <- repo.list_user_repos(human, fc),
         {:ok, enrolled} <- enrolled_names(repo, fc) do
      {:ok,
       mine
       |> Enum.reject(&(Fleet.Layout.project_name(&1) in enrolled))
       |> Enum.sort()
       |> Enum.map(&describe_candidate/1)}
    end
  end

  # The name rule, rendered rather than merely applied: an agent that must PRESENT a candidate to a
  # human needs to say what is wrong with it, and `{:error, {:invalid_name, _}}` at import time
  # says it to the wrong reader at the wrong moment.
  defp describe_candidate(full_name) do
    name = Fleet.Layout.project_name(full_name)

    case validate_name(name) do
      :ok ->
        %{"source" => full_name, "name" => name, "admissible" => true}

      {:error, {:invalid_name, _}} ->
        %{
          "source" => full_name,
          "name" => name,
          "admissible" => false,
          "reason" =>
            "le nom doit être en kebab-case minuscule (`[a-z0-9]`, tirets internes) — " <>
              "renomme le dépôt sur la forge, ou donne-lui son nom de destination à l'import"
        }
    end
  end

  # The names already carried by an INSTALLED catalogue org. Fail-loud: an unreachable org would make
  # the candidate list too WIDE, i.e. offer to import what is already in.
  defp enrolled_names(repo, fc) do
    Enum.reduce_while(installed_orgs(), {:ok, MapSet.new()}, fn org, {:ok, acc} ->
      case repo.list_org_repos(org, fc) do
        {:ok, names} ->
          {:cont, {:ok, Enum.into(Enum.map(names, &Fleet.Layout.project_name/1), acc)}}

        {:error, reason} ->
          {:halt, {:error, {:enrolled_scan_failed, org, reason}}}
      end
    end)
  end

  defp split_repo(full_name) do
    case String.split(full_name, "/") do
      [owner, name] when owner != "" and name != "" -> {:ok, owner, name}
      _ -> {:error, {:not_a_repo_name, full_name}}
    end
  end

  # Un depot deja dans une org de catalogue n'est pas un DEPOT : c'est un projet enrolle. Le
  # reprendre par cette porte le clonerait puis le recreerait ailleurs, alors que les verbes justes
  # existent — `import/2` pour l'adopter localement, `migrate/3` pour le changer de catalogue.
  defp refute_source_in_org(owner, source) do
    if owner in installed_orgs(),
      do: {:error, {:source_already_enrolled, source, owner}},
      else: :ok
  end

  defp require_destination_catalogue(catalogue), do: require_installed(catalogue)

  # A PRIVATE deposit is refused, and it is refused HERE rather than left to the clone.
  #
  # There is no config lever to force public repos on this forge: `[repository] DEFAULT_PRIVATE`
  # does NOT exist in the Gitea we run (measured on the image's own binary, with a witness — the
  # neighbouring `DEFAULT_SHOW_FULL_NAME` is there, this one is not). So a private repo stays
  # creatable, and the only honest place to stop it is the door.
  #
  # Asking the forge is not the same as watching the clone fail: this runtime's git carries the
  # system token, so a private source would clone WITHOUT error and its content would land in a
  # public org repo. A visibility change nobody asked for is worse than a refusal, and it is
  # invisible exactly when it happens.
  defp require_public_source(source, opts) do
    case repo_mod(opts).private?(source, fc_opts(opts)) do
      {:ok, false} -> :ok
      {:ok, true} -> {:error, {:deposit_not_public, source}}
      {:error, reason} -> {:error, {:deposit_visibility_unreadable, source, reason}}
    end
  end

  # Clones the deposit. The visibility question is settled BEFORE this, by `require_public_source/2`
  # — not by letting the clone fail, because this call carries the system token and a private repo
  # would clone just fine, copying private content into a public org repo with nothing said.
  defp clone_deposit(url, scratch, opts) do
    timeout = Keyword.get(opts, :clone_timeout_ms, 120_000)

    case Fleet.Credentials.Shell.git(["clone", "--no-recurse-submodules", url, scratch],
           timeout_ms: timeout
         ) do
      {:ok, {_, 0}} ->
        :ok

      {:ok, {out, code}} ->
        {:error, {:deposit_clone_failed, {code, String.slice(out, 0, 500)}}}

      {:error, reason} ->
        {:error, {:deposit_clone_failed, reason}}
    end
  end

  # LE DEPOT N'EST PAS A NOUS, et c'est ce qui change tout par rapport aux deux autres verbes :
  # `adopt` et `import_external` CREENT le repo, donc leur compensation le supprime en entier.
  # Ici il preexiste, on ne peut donc defaire QUE ce qu'on a soi-meme pousse — d'ou l'inventaire
  # remonte par `ensure_writer_faces/5`.
  defp finish_import(full_name, dirs, name, opts) do
    with {:ok, url} <- repo_url(full_name, opts),
         :ok <- clone_main(url, dirs.code) do
      case ensure_writer_faces(full_name, url, dirs, name, opts) do
        {:ok, published} -> lock_and_announce(full_name, dirs, published, opts)
        {:error, reason, published} -> undo_published(full_name, published, reason, opts)
      end
    end
  end

  defp lock_and_announce(full_name, dirs, published, opts) do
    case lock_main(full_name, opts) do
      :ok ->
        Logger.info(
          "ProjectOnboard: #{full_name} imported — main=#{dirs.code}, " <>
            "#{Fleet.Layout.ops_branch()}=#{dirs.ops}, #{Fleet.Layout.workshop_branch()}=#{dirs.workshop}"
        )

        {:ok, onboard_result(full_name, dirs, opts)}

      {:error, reason} ->
        undo_published(full_name, published, reason, opts)
    end
  end

  # LA COMPENSATION SE DIT DANS LE RETOUR, pas seulement dans un log — parce que l'appelant decide
  # a partir du retour, et que ce qu'il en deduit ici est « je peux retenter proprement ». Tant que
  # tout a ete retire, c'est vrai et l'erreur d'origine passe intacte. Des qu'une suppression
  # echoue, elle devient fausse : le depot d'un tiers porte une branche que cette tentative y a
  # laissee, et le retry la lira comme preexistante. Ce cas-la porte donc son propre nom.
  #
  # ⚠ On ne supprime QUE `published`. Une branche clonee etait deja la ; une branche dont la
  # lecture a echoue n'a jamais ete touchee (`ensure_face` refuse avant d'ecrire).
  defp undo_published(_full_name, [], reason, _opts), do: {:error, reason}

  defp undo_published(full_name, published, reason, opts) do
    outcomes =
      Enum.map(published, fn branch ->
        {branch, repo_mod(opts).delete_branch(full_name, branch, fc_opts(opts))}
      end)

    case Enum.reject(outcomes, &match?({_b, {:ok, _}}, &1)) do
      [] ->
        Logger.warning(
          "ProjectOnboard: import #{full_name} FAILED (#{inspect(reason)}) — forge compensated: " <>
            "#{inspect(Enum.map(outcomes, fn {b, {:ok, o}} -> {b, o} end))}"
        )

        {:error, reason}

      left ->
        Logger.error(
          "ProjectOnboard: import #{full_name} FAILED (#{inspect(reason)}) and its forge " <>
            "compensation did NOT complete — branches pushed by this attempt SURVIVE on a " <>
            "third-party repo: #{inspect(left)}"
        )

        {:error, {:import_not_compensated, reason, left}}
    end
  end

  @doc """
  Opens a project already present on the machine.

  All parked markers must be read and closed before the per-project architect is ensured. Missing
  local faces or an unreadable/unclosable parked state are refusals. Returns the common project
  result shape used by `onboard/2` and `import/2`.
  """
  @spec open(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def open(full_name, opts \\ []) when is_binary(full_name) do
    name = Fleet.Layout.project_name(full_name)
    dirs = face_dirs(name, opts)

    with :ok <- validate_name(name),
         :ok <- require_all_faces_on_machine(full_name, dirs),
         :ok <- unpark(full_name, opts) do
      result = onboard_result(full_name, dirs, opts)
      Logger.info("ProjectOnboard: #{full_name} opened — architect #{result.architect.status}")
      {:ok, result}
    end
  end

  # BL-6-30
  defp unpark(full_name, opts) do
    forge = forge_issues(opts)

    case forge.list_open_issues(full_name, fc_opts(opts)) do
      {:ok, issues} ->
        issues
        |> Enum.filter(&Fleet.Forge.Protocol.parked_issue_title?(&1["title"]))
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
      case forge.close_issue(full_name, n, Keyword.put(fc_opts(opts), :closure, :marker)) do
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
  defp forge_issues(opts), do: Keyword.get(opts, :forge_issues, Fleet.Forge.Client)

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
    root = Keyword.get(opts, :code_root, @code_root)

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
             Keyword.put(fc_opts(opts), :assigned_by, human)
           ) do
      numbers =
        issues
        |> Enum.reject(&Fleet.Forge.Protocol.parked_issue_title?(&1["title"]))
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
    case forge_issues(opts).list_open_issues(full_name, fc_opts(opts)) do
      {:ok, issues} ->
        parked? = Enum.any?(issues, &Fleet.Forge.Protocol.parked_issue_title?(&1["title"]))
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
    proj_dir = Path.join(Keyword.get(opts, :code_root, @code_root), name)
    forge = forge_issues(opts)

    with :ok <- validate_name(name),
         :ok <- require_on_machine(full_name, proj_dir),
         :ok <- require_proven_identity(full_name, proj_dir, opts),
         {:ok, issues} <- read_parked_state(forge, full_name, opts) do
      if Enum.any?(issues, &Fleet.Forge.Protocol.parked_issue_title?(&1["title"])) do
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
    if origin_full_name(proj_dir, opts) == {:ok, full_name},
      do: :ok,
      else: {:error, {:identity_unproven, full_name}}
  end

  defp read_parked_state(forge, full_name, opts) do
    case forge.list_open_issues(full_name, fc_opts(opts)) do
      {:ok, issues} -> {:ok, issues}
      {:error, reason} -> {:error, {:close_failed, {:parked_state_unreadable, reason}}}
    end
  end

  defp do_close(full_name, forge, opts) do
    case Fleet.Credentials.Human.current() do
      {:ok, human} ->
        issue_opts = Keyword.put(fc_opts(opts), :assignees, [human])
        title = Fleet.Forge.Protocol.parked_issue_title()

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
  Publishes a disk-only project to a new empty forge repository. `BL-6-32`

  The local `main` and any valid local `ops` history are preserved. The call seeds protocol
  labels, ensures the project declaration, publishes both faces, protects `main`, and ensures the
  architect. It refuses conflicting origins, existing forge state and malformed local faces.
  Compensation removes only the forge repository and a `ops` directory created by this call.
  """
  @spec adopt_project(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def adopt_project(name, opts \\ []) when is_binary(name) do
    dirs = face_dirs(name, opts)

    with {:ok, org} <- required_org(opts),
         full_name = "#{org}/#{name}",
         :ok <- refute_store_address(full_name, name),
         :ok <- admit(org, name, opts),
         :ok <- require_local_main(dirs.code),
         :ok <- ensure_catalogue_org_on_forge(org, opts),
         :ok <- require_adoptable_origin(full_name, dirs.code, opts),
         {:ok, states} <- classify_adopt_writer_faces(dirs),
         :ok <- require_forge_absent(full_name, opts),
         {:ok, url} <- repo_url(full_name, opts),
         {:ok, full_name} <- create_empty_repo(name, org, opts) do
      case finish_adopt(full_name, url, dirs, states, name, opts) do
        {:ok, result} ->
          {:ok, result}

        {:error, reason} = err ->
          compensate_adopt(full_name, dirs, states, reason, opts)
          err
      end
    end
  end

  defp require_local_main(proj_dir) do
    with true <- File.dir?(proj_dir),
         {:ok, _sha} <-
           GitOps.read(["-C", proj_dir, "rev-parse", "--verify", "--quiet", "refs/heads/main"]) do
      :ok
    else
      _ -> {:error, {:not_adoptable, {:no_local_main, proj_dir}}}
    end
  end

  defp require_adoptable_origin(full_name, proj_dir, opts) do
    case origin_full_name(proj_dir, opts) do
      {:ok, ^full_name} -> :ok
      {:ok, other} -> {:error, {:origin_conflict, other}}
      {:error, _no_origin} -> :ok
    end
  end

  # Per WRITER face: absent (we build it), already a git dir on that face's branch (we adopt it),
  # or a directory that is something else — which is a refusal, never a thing to overwrite. The
  # directory belongs to the user; adopt publishes what is there, it does not replace it.
  defp classify_adopt_face(dir, branch) do
    cond do
      not File.exists?(dir) ->
        {:ok, :absent}

      match?(
        {:ok, _},
        GitOps.read(["-C", dir, "rev-parse", "--verify", "--quiet", "refs/heads/" <> branch])
      ) ->
        {:ok, :present_git}

      true ->
        {:error, {:not_adoptable, {:face_dir_not_on_branch, dir, branch}}}
    end
  end

  defp classify_adopt_writer_faces(dirs) do
    with {:ok, ops} <- classify_adopt_face(dirs.ops, Fleet.Layout.ops_branch()),
         {:ok, workshop} <-
           classify_adopt_face(dirs.workshop, Fleet.Layout.workshop_branch()) do
      {:ok, %{ops: ops, workshop: workshop}}
    end
  end

  defp require_forge_absent(full_name, opts) do
    case repo_mod(opts).default_branch(full_name, fc_opts(opts)) do
      {:ok, _branch} -> {:error, {:repo_already_exists, full_name}}
      {:error, {:http, 404, _}} -> :ok
      {:error, reason} -> {:error, {:forge_unverifiable, reason}}
    end
  end

  defp create_empty_repo(name, org, opts) do
    desc = Keyword.get(opts, :description, "")

    result =
      repo_mod(opts).create_repo(
        name,
        Keyword.merge(opts, org: org, description: desc, auto_init: false)
      )

    classify_create_repo(result, org, name)
  end

  defp finish_adopt(full_name, url, dirs, states, name, opts) do
    with :ok <- Fleet.Forge.WriteSpacing.gap(opts),
         :ok <- seed_protocol_labels(full_name, opts),
         :ok <- set_origin(dirs.code, url),
         :ok <- ensure_declaration(dirs.code, full_name, opts),
         :ok <-
           ensure_ci_workflows(
             dirs.code,
             name,
             with_ci_stance(full_name, opts),
             "ci(adopt): rail CI du depot (.gitea/workflows)"
           ),
         :ok <- push(dirs.code, "main", true),
         :ok <- Fleet.Forge.WriteSpacing.gap(opts),
         :ok <-
           adopt_face(
             states.ops,
             url,
             dirs.ops,
             Fleet.Layout.ops_branch(),
             "ops",
             name,
             opts
           ),
         :ok <- Fleet.Forge.WriteSpacing.gap(opts),
         :ok <-
           adopt_face(
             states.workshop,
             url,
             dirs.workshop,
             Fleet.Layout.workshop_branch(),
             "workshop",
             name,
             opts
           ),
         :ok <- lock_main(full_name, opts) do
      Logger.info(
        "ProjectOnboard: #{full_name} ADOPTED from disk — main published, " <>
          "#{Fleet.Layout.ops_branch()} and #{Fleet.Layout.workshop_branch()} up, protection placed"
      )

      {:ok, onboard_result(full_name, dirs, opts)}
    end
  end

  defp set_origin(dir, url) do
    case GitOps.read(["-C", dir, "config", "--get", "remote.origin.url"]) do
      {:ok, _present} -> GitOps.run(["-C", dir, "remote", "set-url", "origin", url], auth: false)
      {:error, _} -> GitOps.run(["-C", dir, "remote", "add", "origin", url], auth: false)
    end
  end

  # ─── LE RAIL CI D'UN DEPOT QUI VIENT D'AILLEURS ─────────────────────────────────────────────────
  #
  # La protection de `main` exige un statut `CI / *`. Un depot sans `.gitea/workflows/` n'en produit
  # AUCUN, jamais : aucune PR ne peut fusionner, et la chaine de livraison est morte avant son
  # premier ticket. `CIGate` lit deja cette impasse et la nomme (`{:ci_impossible, :no_workflow}`),
  # mais la NOMMER laisse quelqu'un ecrire le fichier — et c'est ainsi qu'il atterrit avec un
  # `runs-on:` qu'aucun runner ne sert, en attente pour toujours au lieu d'echouer.
  #
  # SEULES LES PORTES QUI FONT ENTRER DU CONTENU ETRANGER l'appellent. `import/2` RAPATRIE un depot
  # deja dans l'org : il y est arrive par la creation, l'adoption ou l'import externe, donc il porte
  # deja ses workflows par construction.
  #
  # ⚠ `Scaffold.main/3` NE POUVAIT PAS SERVIR : il ecrit la face ENTIERE (README, CLAUDE.md,
  # .gitignore), ce qui est juste pour un depot que la fleet vient de creer et destructeur pour un
  # depot qu'elle importe. Cette porte-ci n'ajoute que ce qui MANQUE.
  # LA POSTURE DU RAIL SE LIT SUR LA CARTE, ET LE DEFAUT EST L'INVITATION A PROUVER. Une carte
  # illisible, absente, ou un catalogue casse rendent `:required` : le projet recoit un rail qui
  # l'invite a poser sa suite. La dispense ne s'obtient que d'une carte qui la DECLARE.
  @doc """
  RÉÉCRIT le rail CI de `full_name` sur `main` depuis le template livré, et le pousse.

  ⚠ **LA SORTIE DE SECOURS DU PLANCHER, ET RIEN D'AUTRE.** `protect_main` exige un statut `CI / *`
  de tout le monde ; un `ci.yml` cassé — image sans `node`, `runs-on:` qu'aucun runner ne sert,
  workflow renommé hors de `CI` — n'en produit plus. Aucune PR ne fusionne, et **personne ne peut le
  réparer côté forge** : les humains y sont en `read`. Ce verbe remet le rail livré, vert par
  construction, et le pousse par le même lift ponctuel que la révision de carte.

  ⚠ **IL ÉCRASE, ET C'EST TOUT SON OBJET.** `Scaffold.ci_workflows/3` ne touche jamais un fichier
  existant — la bonne règle quand on ADOPTE. Ici on répare : le fichier existant EST le défaut.
  D'où `justification` requise, comme pour une révision de carte : ce geste remplace le travail de
  quelqu'un, il ne se joue pas par accident.

  ⚠ **SUR `main`, PAS SUR UNE BRANCHE DE PR.** Le rail de `main` est ce dont héritent les branches
  suivantes ; une PR déjà ouverte se répare par son producteur, à qui le brief de rework nomme
  désormais le job en échec. Pousser sur la branche d'un pod vivant courserait avec lui.

  `opts` : `:justification` (requise), `:reset_by` (le rôle qui agit).
  Rend `%{repo:, outcome: :reset | :unchanged, files:}`.
  """
  @spec reset_ci_rail(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def reset_ci_rail(full_name, opts \\ []) when is_binary(full_name) do
    name = Fleet.Layout.project_name(full_name)
    proj_dir = Path.join(Keyword.get(opts, :code_root, @code_root), name)

    with :ok <- require_on_machine(full_name, proj_dir),
         :ok <- require_justification(opts),
         {:ok, url} <- repo_url(full_name, opts) do
      scratch = scratch_dir(name)

      try do
        with :ok <- clone_main(url, scratch),
             {:ok, files} <-
               Scaffold.reset_ci_workflows(scratch, name, with_ci_stance(full_name, opts)),
             {:ok, :changed} <- revision_changed(scratch) do
          publish_ci_rail(full_name, scratch, files, opts)
        else
          {:ok, :unchanged} ->
            {:ok, %{repo: full_name, outcome: :unchanged, files: []}}

          {:error, _} = err ->
            err
        end
      after
        _ = File.rm_rf(scratch)
      end
    end
  end

  defp publish_ci_rail(full_name, scratch, files, opts) do
    msg = "ci(reset): rail CI remis a l'etat livre (#{Enum.join(files, ", ")})"

    with :ok <- commit(scratch, msg),
         :ok <- lift_protection(full_name, opts) do
      case push(scratch, "main", false) do
        :ok ->
          protection = restore_protection(full_name, opts)

          Logger.info(
            "ProjectOnboard: #{full_name} rail CI remis a l'etat livre — #{Enum.join(files, ", ")}"
          )

          {:ok,
           %{repo: full_name, outcome: :reset, files: files, protection: to_string(protection)}}

        {:error, reason} ->
          _ = restore_protection(full_name, opts)
          {:error, {:ci_rail_push_failed, reason}}
      end
    end
  end

  defp with_ci_stance(repo, opts),
    do: Keyword.put_new(opts, :ci_stance, ci_stance(repo, opts))

  defp ci_stance(repo, opts) do
    case Keyword.get(opts, :workflow_map) do
      card when is_binary(card) and card != "" ->
        loader_opts =
          case Keyword.take(opts, [:workflow_maps_root]) do
            [] -> Fleet.Workflow.Loader.card_opts_for_repo(repo)
            given -> given
          end

        try do
          Fleet.Project.Roles.ci(Fleet.Workflow.Loader.load!(card, loader_opts))
        rescue
          _ -> :required
        end

      _ ->
        :required
    end
  end

  defp ensure_ci_workflows(proj_dir, name, opts, msg) do
    case Scaffold.ci_workflows(proj_dir, name, opts) do
      {:ok, []} ->
        :ok

      {:ok, added} ->
        Logger.info(
          "ProjectOnboard: rail CI pose sur un depot importe — #{Enum.join(added, ", ")}"
        )

        commit(proj_dir, msg)

      {:error, _} = err ->
        err
    end
  end

  # A present declaration is LEFT AS-IS (the burn validates loudly; adopt does not overwrite the
  # user's engraving) — an absent one is written from the relayed declaration (or the honest undeclared
  # default) and committed, BEFORE the single main push (v2-1 of the 6-16/6-31 plan: pushed
  # AFTER, it would never reach the forge and both lock_main reads would fall back to the
  # default-card jury in silence).
  defp ensure_declaration(
         proj_dir,
         full_name,
         opts,
         msg \\ "chore(adopt): déclaration de criticité (.lcars.json)"
       ) do
    if File.exists?(Path.join(proj_dir, Fleet.Layout.project_declaration_file())) do
      :ok
    else
      with :ok <- write_declaration(proj_dir, full_name, opts) do
        commit(proj_dir, msg)
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
  defp write_declaration(proj_dir, full_name, opts) do
    Fleet.Project.Declaration.write(proj_dir, Keyword.put(opts, :repo, full_name))
  end

  defp adopt_face(:absent, url, dir, branch, template, name, opts) do
    with :ok <- init_face(dir, url, branch),
         :ok <- Scaffold.face(dir, template, name, opts),
         :ok <- commit(dir, "chore(adopt): init #{branch}") do
      publish_face(dir, branch)
    end
  end

  defp adopt_face(:present_git, url, dir, branch, _template, _name, _opts) do
    with :ok <- set_origin(dir, url) do
      publish_face(dir, branch)
    end
  end

  defp compensate_adopt(full_name, dirs, states, reason, opts) do
    forge =
      case repo_mod(opts).delete_repo(full_name, fc_opts(opts)) do
        :ok -> :deleted
        {:error, e} -> {:delete_failed, e}
      end

    # A face we BUILT is removed; a face that was already the user's is KEPT. The distinction is
    # per-face because the states are: adopting a project with a ops of its own and no
    # workshop must not delete the former while cleaning up the latter.
    undo = fn state, dir ->
      if state == :absent, do: compensate_dir(dir), else: :kept_preexisting
    end

    Logger.warning(
      "ProjectOnboard: adopt #{full_name} FAILED (#{inspect(reason)}) — compensated: " <>
        "forge #{inspect(forge)}, work_dir #{inspect(undo.(states.ops, dirs.ops))}, " <>
        "doc_dir #{inspect(undo.(states.workshop, dirs.workshop))} (proj_dir untouched — the user's; " <>
        "a clean retry is possible)"
    )
  end

  # External forges this verb repatriates from (BL-6-31, user perimeter). Everything else is a
  # named refusal — extending the list is a deliberate one-line decision here.
  @external_hosts ~w(github.com gitlab.com)

  @doc """
  IMPORTS a repo from an EXTERNAL forge (GitHub/GitLab — BL-6-31): repatriate → adoption gate →
  create in the org → push → the existing local import leg. One-way: the external origin is
  LEFT BEHIND (origin is re-pointed at OUR forge — an import, never a mirror).

  The sequence (plan 6-16/6-31 v2.1, orchestration NEW, primitives reused):
    1. URL gate — https + host ∈ #{inspect(@external_hosts)}; anything else refuses
       `{:unsupported_forge, _}`.
    2. System clone into a per-gesture SCRATCH (`--no-recurse-submodules` — a hostile submodule
       is never repatriated silently), cleaned on EVERY exit. Auth is the WIRED git credential
       helper (gh/glab Tier 1, or the operator's own helper Tier 2), reached via the inherited HOME
       under `GIT_TERMINAL_PROMPT=0` — the same tiered model as publish, no external token handled.
       Public repos clone tokenless; a private one needs gh/glab authed (or a wired helper).
    3. ADOPTION GATE (the parking-lot USB, BL-6-16): a non-empty `.claude/` tree is refused EN
       BLOC (`{:foreign_claude_dir, _}` — we do not adopt someone else's hooks; org repos
       re-enter via `import/2`, never through this verb), and every `CLAUDE.md` must pass
       `Fleet.ReceptionFilter` (`{:hostile_material, label, path}` otherwise). Nothing reaches
       the org on a refusal — the operator expurges at the SOURCE and retries.
    4. Default branch → `main`, THREE cases: already main → no-op; main absent → rename;
       default ≠ main while a remote `main` EXISTS → `{:branch_collision, _}` (half-migrated
       repos are common; we never guess which is the real one).
    5. Empty org repo + protocol labels + declaration committed IN the scratch BEFORE the push
       (the push must CARRY .lcars.json or every later jury read falls back in silence) →
       push main (full history) → the local `finish_import` leg (clone from OUR forge,
       ops, protection — its `lock_main` reads the now-present local declaration).

  Refusals before any effect: dirs already on machine (`{:already_on_machine, _}` — that
  project wants `open`/`import`), forge repo existing (`{:repo_already_exists, _}`).
  Compensation: forge repo deleted DIRECT (the 6-32 lesson — an empty just-created repo probes
  absent through delete_forge and would leak) + both local dirs; the scratch dies in `after`.
  """
  @spec import_external(String.t(), String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def import_external(url, name, opts \\ []) when is_binary(url) and is_binary(name) do
    dirs = face_dirs(name, opts)
    # Injection seam over the pure gate (tests drive file:// fixtures) — prod default enforces.
    url_gate = Keyword.get(opts, :url_gate, &default_external_url_gate/1)

    # L'ADMISSION COMMUNE D'ABORD, LES SPECIFICITES ENSUITE — uniformement sur les cinq verbes.
    with {:ok, org} <- required_org(opts),
         :ok <- admit(org, name, opts),
         full_name = "#{org}/#{name}",
         :ok <- url_gate.(url),
         :ok <- ensure_catalogue_org_on_forge(org, opts),
         :ok <- require_machine_absent(full_name, dirs),
         :ok <- require_forge_absent(full_name, opts) do
      scratch = external_scratch_dir(name)

      try do
        with :ok <- clone_external(url, scratch, opts),
             :ok <- adoption_gate(scratch),
             :ok <- normalize_default_branch(scratch),
             {:ok, forge_url} <- repo_url(full_name, opts),
             {:ok, full_name} <- create_empty_repo(name, org, opts) do
          source_host =
            case URI.parse(url).host do
              h when h in [nil, ""] -> "external"
              h -> h
            end

          case finish_external(
                 full_name,
                 forge_url,
                 scratch,
                 dirs,
                 name,
                 Keyword.put(opts, :source_host, source_host)
               ) do
            {:ok, result} ->
              {:ok, result}

            {:error, reason} = err ->
              compensate_external(full_name, dirs, reason, opts)
              err
          end
        end
      after
        _ = File.rm_rf(scratch)
      end
    end
  end

  # The compensable window — finish_adopt's proven order (declaration BEFORE push), then the
  # existing local import leg for what it does (clone from OUR forge brings .lcars.json
  # back down, so ITS lock_main reads the right jury).
  defp declaration_commit_message(opts) do
    door =
      case Keyword.get(opts, :source_host, "") do
        "depot:" <> _ -> "import-depot"
        _ -> "import-externe"
      end

    "chore(#{door}): déclaration de criticité (.lcars.json)"
  end

  defp finish_external(full_name, forge_url, scratch, dirs, name, opts) do
    with :ok <- Fleet.Forge.WriteSpacing.gap(opts),
         :ok <- seed_protocol_labels(full_name, opts),
         # The commit message names the ACTUAL door: this leg is shared by the external import and
         # the deposit, and a deposit whose history says "import-externe" tells the project's own
         # log something that did not happen.
         :ok <- ensure_declaration(scratch, full_name, opts, declaration_commit_message(opts)),
         :ok <-
           ensure_ci_workflows(
             scratch,
             name,
             with_ci_stance(full_name, opts),
             "ci(import): rail CI du depot (.gitea/workflows)"
           ),
         :ok <- set_origin(scratch, forge_url),
         :ok <- push(scratch, "main", true),
         :ok <- Fleet.Forge.WriteSpacing.gap(opts),
         {:ok, result} <- finish_import(full_name, dirs, name, opts) do
      Logger.info(
        "ProjectOnboard: #{full_name} imported from EXTERNAL " <>
          "#{Keyword.get(opts, :source_host, "external")} — history preserved, origin " <>
          "re-pointed at the org (the source URL is never logged: it may carry the operator token)"
      )

      {:ok, result}
    end
  end

  defp default_external_url_gate(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme != "https" -> {:error, {:unsupported_forge, {:scheme, uri.scheme}}}
      uri.host in @external_hosts -> :ok
      true -> {:error, {:unsupported_forge, uri.host}}
    end
  end

  defp require_machine_absent(full_name, dirs) do
    if Enum.any?([dirs.code, dirs.ops, dirs.workshop], &File.exists?/1),
      do: {:error, {:already_on_machine, full_name}},
      else: :ok
  end

  # Per-gesture unique scratch (two concurrent imports of the same name never share one; the
  # NAME collision itself is refused upstream by require_forge_absent). BEAM-side, outside any
  # pod sandbox. (NOT the card-revision scratch_dir/1 above — different lifecycle, per-gesture.)
  defp external_scratch_dir(name) do
    Path.join(
      System.tmp_dir!(),
      "lcars-import-#{name}-#{:erlang.unique_integer([:positive])}"
    )
  end

  defp clone_external(url, scratch, opts) do
    timeout = Keyword.get(opts, :clone_timeout_ms, 120_000)

    # Auth is the WIRED git credential helper — gh/glab (Tier 1) or the operator's own helper (Tier 2),
    # reached via the inherited HOME, the SAME tiered model as publish. No external token is read,
    # stored, or passed: LCARS_EXTERNAL_GIT_TOKEN is retired. Shell.git's default env is
    # ForgeAuth.git_env/0 — GIT_TERMINAL_PROMPT=0 (a missing helper fails LOUD, never hangs a headless
    # clone) plus the INTERNAL forge extraheader, scoped to the internal host and so inert for an
    # external clone (a private external repo needs gh/glab authed, or a wired helper — Tier 2).
    case Fleet.Credentials.Shell.git(
           ["clone", "--no-recurse-submodules", url, scratch],
           timeout_ms: timeout
         ) do
      {:ok, {_, 0}} ->
        :ok

      {:ok, {out, code}} ->
        {:error, {:external_clone_failed, {code, String.slice(out, 0, 500)}}}

      {:error, reason} ->
        {:error, {:external_clone_failed, reason}}
    end
  end

  # The parking-lot USB check (BL-6-16/6-31): instruction-tier material only — scanning the
  # whole code would drown in false positives (a README legitimately says "force-push").
  #
  # ⚠ DECLARED BLIND SPOT — `.gitmodules` IS NOT READ. This gate probes exactly two things,
  # `**/.claude` and `**/CLAUDE.md`, and a foreign repo can carry a `.gitmodules` pointing anywhere.
  # Nothing is fetched from it: `clone_external` passes `--no-recurse-submodules`, and the fleet
  # never runs `git submodule update` on an imported project — so the practical risk today is low.
  # This sentence exists because an unwritten limit makes a gate people lean on too hard, and a
  # perimeter nobody knows is exactly that. Widening the probe is a decision, not
  # a reflex; the honest minimum is to say what is not looked at, next to what is.
  defp adoption_gate(scratch) do
    case foreign_claude_dirs(scratch) do
      [] -> scan_claude_mds(scratch)
      dirs -> {:error, {:foreign_claude_dir, dirs}}
    end
  end

  defp foreign_claude_dirs(scratch) do
    scratch
    |> Path.join("**/.claude")
    |> Path.wildcard(match_dot: true)
    |> Enum.reject(&(".git" in Path.split(Path.relative_to(&1, scratch))))
    |> Enum.filter(&File.dir?/1)
    |> Enum.map(&Path.relative_to(&1, scratch))
  end

  defp scan_claude_mds(scratch) do
    scratch
    |> Path.join("**/CLAUDE.md")
    |> Path.wildcard(match_dot: true)
    |> Enum.reject(&(".git" in Path.split(Path.relative_to(&1, scratch))))
    |> Enum.reduce_while(:ok, fn path, :ok ->
      rel = Path.relative_to(path, scratch)

      case File.read(path) do
        {:ok, content} ->
          case Fleet.ReceptionFilter.scan(content) do
            :clean -> {:cont, :ok}
            {:match, label, _excerpt} -> {:halt, {:error, {:hostile_material, label, rel}}}
          end

        {:error, reason} ->
          # Unreadable instruction material in a fresh clone: refused, never waved through.
          {:halt, {:error, {:unreadable_material, rel, reason}}}
      end
    end)
  end

  # Three cases (plan F6): a half-migrated repo (default=master AND a remote main) is REFUSED —
  # we never guess which branch is the real one; the operator settles it at the source.
  defp normalize_default_branch(scratch) do
    with {:ok, {head_out, 0}} <-
           Fleet.Credentials.Shell.git(["-C", scratch, "symbolic-ref", "--short", "HEAD"],
             env: []
           ),
         {:ok, {remotes_out, 0}} <-
           Fleet.Credentials.Shell.git(
             ["-C", scratch, "branch", "-r", "--format=%(refname:short)"],
             env: []
           ) do
      head = String.trim(head_out)
      remote_main? = "origin/main" in String.split(remotes_out, "\n", trim: true)

      cond do
        head == "main" ->
          :ok

        remote_main? ->
          {:error, {:branch_collision, {head, "main"}}}

        true ->
          case Fleet.Credentials.Shell.git(["-C", scratch, "branch", "-m", head, "main"],
                 env: []
               ) do
            {:ok, {_, 0}} ->
              :ok

            {:ok, {out, code}} ->
              {:error, {:branch_rename_failed, {code, String.slice(out, 0, 300)}}}

            {:error, reason} ->
              {:error, {:branch_rename_failed, reason}}
          end
      end
    else
      other -> {:error, {:default_branch_unreadable, other}}
    end
  end

  # Same direct-primitive posture as compensate_adopt (the 6-32 lesson), plus both local dirs —
  # unlike adopt, EVERYTHING local here was created by this call.
  defp compensate_external(full_name, dirs, reason, opts) do
    forge =
      case repo_mod(opts).delete_repo(full_name, fc_opts(opts)) do
        :ok -> :deleted
        {:error, e} -> {:delete_failed, e}
      end

    Logger.warning(
      "ProjectOnboard: import_external #{full_name} FAILED (#{inspect(reason)}) — compensated: " <>
        "forge #{inspect(forge)}, project_dir #{inspect(compensate_dir(dirs.code))}, " <>
        "work_dir #{inspect(compensate_dir(dirs.ops))}, " <>
        "doc_dir #{inspect(compensate_dir(dirs.workshop))} (a clean retry is possible)"
    )
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
    dirs = face_dirs(name, opts)

    with :ok <- validate_name(name),
         :ok <- require_force(full_name, opts),
         {:ok, forge} <- delete_forge(full_name, opts) do
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

  @doc """
  Revises the validation card of an existing project. `BL-6-29`

  The new declaration must be loadable and justified. It is committed from a disposable clone,
  pushed through a system-only protection lift, followed by restoration of the canonical rule and
  best-effort showcase synchronization. Push failure restores protection and reports an error;
  restore failure after a landed push is returned in the successful result. An identical declaration
  is an `:unchanged` no-op. Existing issues retain their engraved route.
  """
  @spec revise_card(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def revise_card(full_name, opts \\ []) when is_binary(full_name) do
    name = Fleet.Layout.project_name(full_name)
    proj_dir = Path.join(Keyword.get(opts, :code_root, @code_root), name)
    card = Keyword.get(opts, :workflow_map)

    with :ok <- require_on_machine(full_name, proj_dir),
         :ok <- require_justification(opts),
         :ok <- require_loadable_card(card, full_name, opts),
         {:ok, url} <- repo_url(full_name, opts) do
      previous = declared_card(proj_dir)
      scratch = scratch_dir(name)

      try do
        with :ok <- clone_main(url, scratch),
             :ok <-
               write_declaration(
                 scratch,
                 full_name,
                 revision_write_opts(opts, current_declaration(proj_dir))
               ),
             {:ok, :changed} <- revision_changed(scratch) do
          publish_revision(full_name, scratch, card, previous, opts)
        else
          {:ok, :unchanged} ->
            {:ok, %{repo: full_name, card: card, previous_card: previous, outcome: :unchanged}}

          {:error, _} = err ->
            err
        end
      after
        _ = File.rm_rf(scratch)
      end
    end
  end

  defp require_on_machine(full_name, proj_dir) do
    if File.dir?(proj_dir), do: :ok, else: {:error, {:not_on_machine, full_name}}
  end

  defp require_justification(opts) do
    case Keyword.get(opts, :justification) do
      j when is_binary(j) and j != "" -> :ok
      _ -> {:error, :justification_required}
    end
  end

  # LA REGLE A DEMENAGE CHEZ `Fleet.Project.Declaration` — l'ecrivain de la declaration — et elle ne
  # gardait ici que la REVISION. Le verbe qui CHANGE la carte d'un projet refusait donc une faute
  # de frappe pendant que les verbes qui la DECLARENT en acceptaient une, et rien ne disait que les
  # deux portes repondaient differemment a la meme question (6-125).
  #
  # Ce qui reste ici est ce qui appartient a CE verbe : pour une revision la carte est REQUISE,
  # alors qu'a la creation son absence vaut « le defaut du catalogue ».
  defp require_loadable_card(card, repo, opts) when is_binary(card) and card != "",
    do: Fleet.Project.Declaration.declarable_card(card, repo, opts)

  defp require_loadable_card(_absent, _repo, _opts), do: {:error, :workflow_map_required}

  defp declared_card(proj_dir) do
    with {:ok, raw} <- File.read(Path.join(proj_dir, Fleet.Layout.project_declaration_file())),
         {:ok, %{"pipeline_default" => card}} when is_binary(card) <- Jason.decode(raw) do
      card
    else
      _ -> nil
    end
  end

  defp scratch_dir(name) do
    Path.join(
      System.tmp_dir!(),
      "lcars-card-revision-#{name}-#{System.unique_integer([:positive])}"
    )
  end

  # A REVISION REWRITES THE WHOLE DECLARATION, SO IT MUST NOT REWRITE IT FROM THE OPTS ALONE.
  # `ProjectDeclaration.compose/1` is a pure function of its opts — correct for an ONBOARD, where
  # "absent" means "the human declared nothing". At a REVISION "absent" means "the reviser did not
  # mention it", and composing from the opts alone makes the two indistinguishable: a revision
  # naming only the card DELETES `max_fan` — the throughput the human chose — while `declared_by`
  # moves to the reviser.
  #
  # So the carry-forward lives HERE, at the revision's edge, and `compose/1` stays a pure function
  # of what it is handed. What the revision states wins; what it does not state survives.
  # (`level`/`nature` were retired with the criticality level — crit_quarantine — so `max_fan` is
  # the only framing field left to carry forward.)
  #
  # ⚠ RESIDUE, NAMED: `declared_by` ends up as the reviser for the WHOLE record, including a
  # `max_fan` a human chose and this revision merely carried. It names the last writer, not the
  # origin of every field, and the schema (`lcars/declaration-v1`) has no per-field provenance. It is
  # the smaller lie: the alternative is deleting the human's declaration outright.
  defp revision_write_opts(opts, previous) do
    [
      workflow_map: Keyword.get(opts, :workflow_map),
      justification: Keyword.get(opts, :justification),
      max_fan: Keyword.get(opts, :max_fan) || Map.get(previous, "max_fan"),
      onboarded_by: Keyword.get(opts, :revised_by) || "unknown"
    ]
  end

  # The declaration currently on the machine, or `%{}` when there is none/unreadable — the caller
  # then carries nothing forward, which is exactly the old behaviour for a project that never had a
  # declaration to lose.
  defp current_declaration(proj_dir) do
    with {:ok, raw} <- File.read(Path.join(proj_dir, Fleet.Layout.project_declaration_file())),
         {:ok, %{} = decl} <- Jason.decode(raw) do
      decl
    else
      _ -> %{}
    end
  end

  defp revision_changed(scratch) do
    case GitOps.read(["-C", scratch, "status", "--porcelain"], auth: false) do
      {:ok, ""} -> {:ok, :unchanged}
      {:ok, _dirty} -> {:ok, :changed}
      {:error, _} = err -> err
    end
  end

  defp publish_revision(full_name, scratch, card, previous, opts) do
    jury_delta = jury_delta(previous, card, opts)
    msg = "card revision: #{previous || "(undeclared)"} -> #{card}#{jury_suffix(jury_delta)}"

    with :ok <- commit(scratch, msg),
         :ok <- lift_protection(full_name, opts) do
      case push(scratch, "main", false) do
        :ok ->
          sync_showcase(full_name, opts)
          protection = restore_protection(full_name, opts)
          announce_jury_delta(full_name, previous, card, jury_delta)

          {:ok,
           %{
             repo: full_name,
             card: card,
             previous_card: previous,
             outcome: :revised,
             jury_delta: jury_delta,
             protection: protection
           }}

        {:error, reason} ->
          _ = restore_protection(full_name, opts)
          {:error, {:card_push_failed, reason}}
      end
    end
  end

  # A CARD REVISION MOVES A WALL, and the record said which card, never what the card DOES. Measured:
  # `standard-qa` carries two judges, `c0-poc` carries none — so `card revision: standard-qa ->
  # c0-poc` is a line that removes the jury AND drops `required_approvals` to zero, written in the
  # vocabulary of a rename. Everything about it is auditable and nothing about it is legible.
  #
  # NOT REFUSED, and that is deliberate. The criticality level is the HUMAN's declaration (the
  # framing interview; an agent never self-assesses it), so a project that genuinely became less
  # critical must be able to say so. What a downgrade may not be is QUIET: the justification is
  # already required and recorded, this adds the consequence beside it — in the commit message that
  # lands on `main`, in the operator log, and in the payload the arch relays back.
  #
  # `nil` when either card refuses to load: a delta nobody could compute must not be reported as
  # zero, which would read as "the jury did not change".
  defp jury_delta(previous, card, opts) do
    with {:ok, before} <- jury_size(previous, opts),
         {:ok, after_} <- jury_size(card, opts) do
      after_ - before
    else
      _ -> nil
    end
  end

  defp jury_size(nil, _opts), do: :error

  defp jury_size(name, opts) do
    loader_opts = Keyword.take(opts, [:workflow_maps_root])
    {:ok, length(Roles.jury(Fleet.Workflow.Loader.load!(name, loader_opts), []))}
  rescue
    _ -> :error
  end

  defp jury_suffix(delta) when is_integer(delta) and delta < 0,
    do: " (JURY REDUIT DE #{abs(delta)} — moins de juges sur chaque livrable a venir)"

  defp jury_suffix(_not_a_reduction), do: ""

  defp announce_jury_delta(repo, previous, card, delta) when is_integer(delta) and delta < 0 do
    Logger.warning(
      "ProjectOnboard: #{repo} card revision #{previous} -> #{card} REDUCES the jury by " <>
        "#{abs(delta)} — future deliverables carry fewer judges and main-protection re-projects " <>
        "with fewer required approvals. Justified and recorded; named here because the card name " <>
        "alone does not say it."
    )

    :ok
  end

  defp announce_jury_delta(_repo, _previous, _card, _delta), do: :ok

  defp lift_protection(repo, opts) do
    rule = %{
      rule_name: "main",
      enable_push: true,
      enable_push_whitelist: true,
      push_whitelist_usernames: [Fleet.Credentials.ForgeIdentity.system_identity().name]
    }

    case repo_mod(opts).protect_branch(repo, rule, fc_opts(opts)) do
      {:ok, _outcome} -> :ok
      {:error, reason} -> {:error, {:protection_lift_failed, reason}}
    end
  end

  defp restore_protection(repo, opts) do
    case protect_main(repo, opts) do
      :ok ->
        :restored

      {:error, reason} ->
        Logger.error(
          "ProjectOnboard: card revision of #{repo} — protection restore FAILED " <>
            "(#{inspect(reason)}) — the periodic protection pass will converge the rule"
        )

        :restore_failed
    end
  end

  defp sync_showcase(repo, opts) do
    sync =
      Keyword.get(opts, :sync_showcase, fn r -> Fleet.Project.WorktreeSync.sync_now(r, "main") end)

    case sync.(repo) do
      :ok ->
        :ok

      other ->
        Logger.warning(
          "ProjectOnboard: card revision of #{repo} landed but the showcase sync degraded " <>
            "(#{inspect(other)}) — burns read the OLD card until the next worktree sync"
        )

        :ok
    end
  catch
    kind, why ->
      Logger.warning(
        "ProjectOnboard: card revision of #{repo} landed but the showcase sync degraded " <>
          "(#{inspect(kind)}: #{inspect(why)}) — burns read the OLD card until the next worktree sync"
      )

      :ok
  end

  defp nuke_if_is(full_name, dir, opts) do
    if File.exists?(dir),
      do: nuke_proven(full_name, dir, origin_full_name(dir, opts)),
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
    case nuke_dir(dir) do
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

  defp origin_full_name(dir, _opts) do
    case GitOps.read(["-C", dir, "config", "--get", "remote.origin.url"]) do
      {:ok, url} -> {:ok, origin_to_full_name(url)}
      {:error, _} = err -> err
    end
  end

  defp origin_to_full_name(url) do
    url
    |> String.trim()
    |> String.trim_trailing("/")
    |> String.replace_suffix(".git", "")
    |> String.split("/")
    |> Enum.take(-2)
    |> Enum.join("/")
  end

  defp require_force(full_name, opts) do
    if Keyword.get(opts, :force, false), do: :ok, else: {:error, {:force_required, full_name}}
  end

  defp delete_forge(full_name, opts) do
    repo_mod = repo_mod(opts)
    fc = fc_opts(opts)

    case repo_mod.default_branch(full_name, fc) do
      {:error, {:http, 404, _}} ->
        {:ok, :absent}

      {:error, reason} ->
        {:error, {:forge_check_failed, reason}}

      {:ok, _branch} ->
        with :ok <- repo_mod.delete_repo(full_name, fc), do: {:ok, :deleted}
    end
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

  defp nuke_dir(dir) do
    case File.rm_rf(dir) do
      {:ok, _} ->
        :ok

      {:error, reason, path} ->
        Logger.warning("ProjectOnboard: reset could not fully remove #{path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ALL THREE faces, and the doc one is not optional here: `open` is what hands a project to the
  # architect, whose producer path is on `doc`. Opening a project whose doc face never landed would
  # succeed and then fail at the first documentary ticket, far from the cause.
  defp require_all_faces_on_machine(full_name, dirs) do
    if Enum.all?([dirs.code, dirs.ops, dirs.workshop], &File.dir?/1),
      do: :ok,
      else: {:error, {:not_on_machine, full_name}}
  end

  # ⚠ PAS DE `require_org_membership` ICI. Comparer le depot a UNE org — celle des opts ou le
  # premier catalogue installe — n'a qu'un comportement atteignable, et c'est un refus faux : un
  # proprietaire qui n'est pas un catalogue installe est deja arrete par
  # `require_catalogue_installed`, et un proprietaire qui l'est n'a aucune raison d'etre compare au
  # PREMIER de la liste. Un tel garde ne peut mordre que le second catalogue, a tort. La question
  # « ce depot est-il enrollable ici ? » a une seule autorite, et c'est le catalogue du proprietaire.

  defp require_default_branch_main(full_name, opts) do
    case repo_mod(opts).default_branch(full_name, fc_opts(opts)) do
      {:ok, "main"} -> :ok
      {:ok, other} -> {:error, {:unexpected_default_branch, other}}
      {:error, _} = err -> err
    end
  end

  # L'INVENTAIRE SE CONSTRUIT EN AVANCANT, il ne se prend pas d'avance : une branche n'entre dans la
  # liste que quand son push a REUSSI, donc chaque entree est une mutation prouvee de cette
  # tentative. Un etat releve avant la boucle serait deja perime au premier push, et c'est
  # exactement sur cet ecart qu'une compensation supprime ce qu'elle n'a pas cree.
  #
  # L'echec porte l'inventaire avec lui (`{:error, reason, published}`) parce que les faces sont
  # posees EN SEQUENCE : `ops` peut etre publiee avant que `workshop` echoue, et c'est le cas exact
  # que la fiche 6-124 decrit.
  #
  # ⚠ LE MODE EST UN FAIT DE LAYOUT, ET IL SE DECLARE PLUTOT QUE DE SE LAISSER A L'UMASK. Les faces
  # vivent sous des racines PARTAGEES, donc un projet ouvert par un humain est vu par les autres.
  # `workshop` est la seule montee en **rw** : heritant son mode de l'umask, le second humain a le
  # groupe mais PAS le bit d'ecriture, et ses pods meurent a la premiere ecriture avec une erreur
  # qui accuse bwrap. `ops` est montee `ro` et garde le mode plus etroit — le declarer ici est ce
  # qui rend la difference LISIBLE.
  defp ensure_writer_faces(full_name, url, dirs, name, opts) do
    faces = [
      %{dir: dirs.ops, branch: Fleet.Layout.ops_branch(), template: "ops", mode: 0o2755},
      %{
        dir: dirs.workshop,
        branch: Fleet.Layout.workshop_branch(),
        template: "workshop",
        mode: 0o2775
      }
    ]

    Enum.reduce_while(faces, {:ok, []}, fn %{branch: branch} = face, {:ok, published} ->
      case ensure_face(full_name, url, face, name, opts) do
        {:ok, :published} -> {:cont, {:ok, published ++ [branch]}}
        {:ok, :cloned} -> {:cont, {:ok, published}}
        {:error, reason} -> {:halt, {:error, reason, published}}
      end
    end)
  end

  defp lock_main(full_name, opts), do: protect_main(full_name, opts)

  @doc """
  Reprojects the canonical `main` protection for a fully seeded project.

  The rule is sized from the current card jury, rejects direct pushes, dismisses stale approvals
  and blocks rejected reviews. Unseeded repositories and the configured project template are left
  untouched.
  """
  @spec reconcile_main_protection(String.t(), keyword()) :: :ok | {:error, term()}
  def reconcile_main_protection(repo, forge_opts) when is_binary(repo) do
    opts = Keyword.put(forge_opts, :forge_opts, forge_opts)

    case seeded_project?(repo, opts) do
      {:ok, true} -> protect_main(repo, opts)
      {:ok, false} -> :ok
      {:error, reason} -> {:error, {:seeded_unreadable, reason}}
    end
  end

  # ⚠ SITE 1 SUR 3 — ET C'EST CELUI OU LA CONFUSION NE PASSAIT MEME PAS PAR UN CHEMIN D'ERREUR.
  # `branch_exists?` rendait `false` sur une forge illisible, donc `reconcile_main_protection/2`
  # partait dans son `else` et rendait **`:ok`** : « rien a faire ici », mot pour mot ce que rend un
  # depot legitimement non seede. Aucune trace, et le Poller horodatait le depot comme reconcilie.
  # La protection de `main` n'etait jamais posee, et rien au monde ne le disait.
  #
  # Trois etats, trois reponses : seede (protege), prouve non seede (rien a faire, vrai `:ok`),
  # illisible (on ne sait pas — on le DIT et l'appelant retentera).
  # ⚠ PAS DE CAS PARTICULIER POUR UN DEPOT TEMPLATE : rien ne cree plus
  # `<catalogue>/project-template`, donc rien n'a besoin d'etre exclu pour que la reconciliation ne
  # lui pose pas une protection de `main` dimensionnee sur un jury qui ne le concerne pas.
  #
  # Ce qui reste est un garde par PROPRIETE, et il est meilleur que le nom qu'il remplace : un depot
  # qui ne porte pas de branche `ops` n'est pas un projet, quel que soit son nom. Le magasin d'un
  # catalogue n'en porte pas — il est donc deja hors de portee, sans que rien n'ait a le nommer.
  defp seeded_project?(repo, opts) do
    repo_mod(opts).branch_exists?(repo, "ops", fc_opts(opts))
  end

  @doc """
  Les contextes de statut EXIGÉS sur `main` d'un projet — l'autorité, et la seule.

  Extrait de la règle ci-dessous parce qu'un SECOND lecteur la lit : le template
  livre désormais des workflows de SONDE (`probe-*`), dont toute la protection tient à ce que leur
  contexte ne matche PAS ce glob. Une sonde renommée `CI-…` deviendrait un statut requis et son
  rouge bloquerait le merge — on aurait retiré le CI de la boucle en croyant l'augmenter.

  Le test qui garde ça (`project_template_workflows_test`) lit CETTE fonction. Recopier `"CI / *"`
  chez lui aurait fait deux vérités d'un même fait, et c'est celle du test qui aurait survécu au
  jour où celle-ci change.
  """
  @spec main_status_check_contexts() :: [String.t()]
  def main_status_check_contexts, do: ["CI / *"]

  defp protect_main(repo, opts) do
    rule = %{
      rule_name: "main",
      required_approvals: length(Roles.project_jury(repo, opts)),
      dismiss_stale_approvals: true,
      block_on_rejected_reviews: true,
      enable_push: false,
      # THE CI GATE IS THE FORGE'S, NOT THE RUNTIME'S. Measured on a live bench: a PR
      # whose head carried `CI / ci (push)` = failure was promoted, and the PR showed no check at
      # all. Two doors were open at once — nothing in `lib/` reads a commit status (the seal merges
      # on jury verdicts alone), and the forge rule had `enable_status_check: false`. The rail ran,
      # produced a verdict, and nobody was listening.
      #
      # It belongs HERE rather than in the seal: the forge IS the state machine, so a gate the
      # runtime enforces is a gate that a human pressing "merge" walks straight through. Projected
      # as protection, it binds every actor.
      #
      # `CI / *` and not the exact contexts: Gitea's Actions contexts are
      # `<workflow name> / <job> (<trigger>)`, so a commit carries BOTH `(push)` and
      # `(pull_request)`. The glob covers both and survives a project renaming its JOB — which the
      # shipped workflow explicitly invites ("chaque projet le RÉÉCRIT quand il sait ce qu'il est").
      # What it does NOT survive is a project renaming the WORKFLOW away from `CI`; that is the
      # coupling this leaves, deliberately, because the alternative (`*`) would require every
      # status any tool ever posts on the commit.
      enable_status_check: true,
      status_check_contexts: main_status_check_contexts()
    }

    case repo_mod(opts).protect_branch(repo, rule, fc_opts(opts)) do
      {:ok, outcome} -> announce_protection(repo, rule, outcome)
      {:error, reason} -> {:error, {:protect_main, reason}}
    end
  end

  defp announce_protection(_repo, _rule, :unchanged), do: :ok

  defp announce_protection(repo, rule, outcome) when outcome in [:created, :updated] do
    Logger.info(
      "ProjectOnboard: #{repo} main-protection #{outcome} " <>
        "(approvals=#{rule.required_approvals}, direct push refused)"
    )

    :ok
  end

  defp fc_opts(opts), do: Keyword.get(opts, :forge_opts, [])

  defp repo_mod(opts), do: Keyword.get(opts, :forge_repo, ForgeClient.Repo)

  defp files_mod(opts), do: Keyword.get(opts, :forge_files, ForgeClient.Files)

  # L'ORG DU CATALOGUE EXISTE-T-ELLE SUR CETTE FORGE ? C'est la SEULE question que cette porte pose,
  # et elle la pose DIRECTEMENT.
  #
  # ⚠ ELLE NE VERIFIE PAS L'HUMAIN, et ce n'est pas un trou : l'admission est tenue UNE FOIS au
  # lancement — le BEAM refuse de demarrer sous un uid systeme et herite de cet uid pour ses pods.
  # Le verifier ici exigerait de l'humain un droit qu'il a deja et n'utilise pas : l'org est
  # publique donc il LIT, et ce n'est pas lui qui ecrit mais le JETON SYSTEME.
  #
  # ⚠ ET LE 404 NE SE DEDUIT PAS D'UNE AUTRE QUESTION : porte par la branche d'erreur d'un test
  # voisin, il ne tombe que si CE test-la rend 404 — donc jamais quand la reponse arrive autrement.
  # La question se pose EN DIRECT.
  #
  # ⚠ `org_exists?/2` ET PAS UNE SONDE SUR LES COMPTES : dans Gitea une org est une ligne de la MEME
  # table `user`, donc un compte PERSONNEL nomme comme le catalogue fait repondre 200 a
  # `/users/<nom>` sans qu'aucune org ne porte ses projets. Demande sur les comptes, le test rendait
  # `true` et le seul message qui nomme le geste manquant retombait en erreur brute.
  defp ensure_catalogue_org_on_forge(org, opts) do
    users = Keyword.get(opts, :forge_users, ForgeClient.Repo)

    case users.org_exists?(org, fc_opts(opts)) do
      {:ok, true} ->
        :ok

      # LE MEME FAIT QUE `catalogue_not_installed`, MESURE A SA SOURCE. Le refus local lit le
      # materiel present sur la boite ; celui-ci demande a la forge si l'org existe. Les deux ne
      # peuvent diverger qu'entre les deux moities d'un install interrompu, et c'est precisement ce
      # cas-la qu'il faut nommer : sans lui l'appelant recevrait, deux gestes plus tard, un « user
      # redirect does not exist [name: web] / GetOrgByName » dont personne ne remonte jusqu'a « le
      # materiel est ici et la forge ne porte pas son org ».
      {:ok, false} ->
        {:error, {:catalogue_not_installed, org, half_install_gesture(org)}}

      # ON N'HABILLE PAS UNE LECTURE RATEE D'UN DIAGNOSTIC INVENTE : forge injoignable, jeton mort,
      # 500 — l'erreur remonte brute, et l'appelant sait qu'il n'a pas mesure.
      {:error, reason} ->
        {:error, {:forge_preflight_failed, reason}}
    end
  end

  # UNE SEULE FORME RESTE, donc plus d'atome de tag ni d'argument ignore : elles etaient la
  # forme d'une famille (`:account`, `:team`, `:team_read`) morte avec le preflight humain.
  defp half_install_gesture(org) do
    "the catalogue '#{org}' has its material on this box but its org does NOT exist on the forge — " <>
      "half an install. Nothing can be onboarded into it until the forge carries the org and its " <>
      "role accounts, and ONE gesture lays both: `lcars catalogue install #{org}`, played by an " <>
      "admin inside the box. Replaying it is the fix — it is convergent, and it is also how the " <>
      "material got here. `lcars catalogue list` shows what the forge actually carries."
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

  defp validate_name(name) do
    if Regex.match?(@name_re, name),
      do: :ok,
      else: {:error, {:invalid_name, name}}
  end

  # EVERY face, not two: a project whose doc face is missing is not realized, and answering `:ok`
  # here would let a half-built project through the door that exists to refuse exactly that.
  defp refute_existing(dirs) do
    case Enum.find([dirs.code, dirs.ops, dirs.workshop], &File.exists?/1) do
      nil -> :ok
      dir -> {:error, {:already_exists, dir}}
    end
  end

  defp refute_existing_or_converge(full_name, dirs, opts) do
    case refute_existing(dirs) do
      :ok ->
        :ok

      {:error, _} = refusal ->
        if satisfied_end_state?(full_name, dirs, opts) do
          Logger.info(
            "ProjectOnboard: #{full_name} already realized (repo + three faces proven ours + " <>
              "writer branches published) — idempotent re-emit, nothing created"
          )

          {:already_satisfied, Map.put(onboard_result(full_name, dirs, opts), :idempotent, true)}
        else
          refusal
        end
    end
  end

  defp satisfied_end_state?(full_name, dirs, opts) do
    ours? =
      Enum.all?([dirs.code, dirs.ops, dirs.workshop], fn dir ->
        origin_full_name(dir, opts) == {:ok, full_name}
      end)

    # ⚠ SITE 2 SUR 3 — LA DIRECTION SURE EST L'INVERSE DE CELLE DES DEUX AUTRES, et c'est pour ca
    # que la garde ne pouvait pas etre reparee « au seul site cite ». Ici un `{:error, _}` laisse
    # tel quel serait TRUTHY : un import jamais fait passerait pour SATISFAIT et on sauterait le
    # travail. Une forge illisible n'est pas une preuve de publication — elle vaut « pas satisfait »,
    # ce qui coute au pire un re-import idempotent.
    published? =
      Enum.all?([Fleet.Layout.ops_branch(), Fleet.Layout.workshop_branch()], fn branch ->
        repo_mod(opts).branch_exists?(full_name, branch, fc_opts(opts)) == {:ok, true}
      end)

    ours? and forge_repo_present?(full_name, opts) and published?
  end

  defp forge_repo_present?(full_name, opts) do
    match?({:ok, _branch}, repo_mod(opts).default_branch(full_name, fc_opts(opts)))
  end

  # ─── UNE SEULE SOURCE : LE CATALOGUE SUR DISQUE ─────────────────────────────────────────────────
  #
  # ⚖ user. Ce chemin passait par `generate_repo` — la fonction « template » de Gitea,
  # qui recopie un depot `<catalogue>/project-template` que la boite avait pousse. Ce depot etait une
  # COPIE du catalogue, et une copie derive : mesure, un banc portait un workflow sur les deux, sans
  # que rien ne le dise, parce que le `sync` n'est joue qu'a la naissance de la boite.
  #
  # POURQUOI PAS « GARDER GITEA ET NE COPIER QU'UNE PARTIE » : `GenerateRepoOption` (swagger de la
  # forge, mesure) n'a AUCUN champ de chemin — `git_content` est un booleen, tout ou rien. Gitea ne
  # sait pas peupler depuis un sous-repertoire, donc le depot template devait porter exactement le
  # squelette, donc il faisait doublon avec le catalogue qui le porte deja.
  #
  # Ce qui reste est le chemin qui existait deja comme REPLI, et qui tournait : creation nue, puis
  # `Scaffold.main` depuis le catalogue installe. Une source, pas deux, donc plus rien a synchroniser
  # ni a comparer.
  defp create_repo(name, org, opts) do
    desc = Keyword.get(opts, :description, "")
    result = repo_mod(opts).create_repo(name, Keyword.merge(opts, org: org, description: desc))
    classify_create_repo(result, org, name)
  end

  # BL-6-33
  #
  # ⚠ LES LABELS CHANGENT DE SOURCE AVEC LE RETRAIT DU TEMPLATE, et c'est voulu. La branche
  # `:generated` ne faisait RIEN parce que Gitea recopiait les labels avec le depot (`labels: true`).
  # Ils viennent desormais du CODE, par le seul chemin qui existe — ce qui est le point de tout le
  # lot : une source, pas une copie.
  defp seed_protocol_labels(full_name, opts) do
    seeder =
      Keyword.get(opts, :ensure_labels, &Fleet.Forge.Client.ensure_protocol_labels/2)

    case seeder.(full_name, fc_opts(opts)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:protocol_labels, reason}}
    end
  end

  @doc false
  # F-C084
  @spec classify_create_repo(
          {:ok, String.t() | :already_exists} | {:error, term()},
          String.t(),
          String.t()
        ) :: {:ok, String.t()} | {:error, term()}
  def classify_create_repo({:ok, full_name}, _org, _name) when is_binary(full_name),
    do: {:ok, full_name}

  def classify_create_repo({:ok, :already_exists}, org, name),
    do: {:error, {:repo_already_exists, "#{org}/#{name}"}}

  def classify_create_repo({:error, _} = err, _org, _name), do: err

  defp repo_url(full_name, opts) do
    base =
      Keyword.get(opts, :base_url) ||
        Application.get_env(:lcars_fleet, :pilot_forge, [])[:base_url]

    case base do
      b when is_binary(b) and b != "" ->
        {:ok, String.trim_trailing(b, "/") <> "/" <> full_name <> ".git"}

      _ ->
        {:error, {:config, {:missing, :base_url}}}
    end
  end

  defp clone_main(url, proj_dir) do
    File.mkdir_p!(Path.dirname(proj_dir))
    GitOps.run(["clone", "--branch", "main", url, proj_dir], auth: true)
  end

  defp publish_face(dir, branch), do: push(dir, branch, true)

  # STANDALONE, not a linked worktree, and this is the reason both non-code faces are built this
  # way: `git worktree add` keeps the gitdir under the PARENT repository, so a face checked out
  # that way is uncommittable from any context that has the parent read-only — which is every pod
  # mounting `/home/projects` RO, and the architect itself. A standalone clone owns its `.git`.
  defp init_face(dir, url, branch) do
    File.mkdir_p!(Path.dirname(dir))

    with :ok <- GitOps.run(["init", "-q", "-b", branch, dir], auth: false) do
      GitOps.run(["-C", dir, "remote", "add", "origin", url], auth: false)
    end
  end

  # Clone the face if the forge already carries the branch, otherwise build and publish it. Same
  # shape for both writer faces: every per-face input travels in ONE map (branch, template subtree,
  # host mode), so a third face costs a call site and no new logic.
  #
  # ⚠ SITE 3 SUR 3 — ET C'EST LUI QUI ECRIT. Sur une forge illisible, l'ancien `false` envoyait dans
  # le `else` : init + scaffold + **publication** d'une branche qui existe peut-etre deja, donc une
  # face distante ECRASEE sur un simple timeout. L'inverse (traiter l'erreur comme « existe ») ferait
  # cloner une branche peut-etre absente : moins destructeur, mais toujours une decision prise sans
  # savoir. On ne devine pas : on REFUSE, et l'import s'arrete avec la raison — l'appelant garde son
  # « repo untouched, a clean retry is possible ».
  #
  # Il rend `:cloned` ou `:published` et non `:ok`, parce que c'est la SEULE difference qui compte
  # pour defaire : `:published` est une branche que CETTE tentative a mise sur la forge, `:cloned`
  # une branche qui appartenait deja au depot. Confondre les deux, c'est soit laisser un residu,
  # soit supprimer le travail de quelqu'un d'autre.
  defp ensure_face(full_name, url, face, name, opts) do
    %{dir: dir, branch: branch, template: template, mode: mode} = face

    case repo_mod(opts).branch_exists?(full_name, branch, fc_opts(opts)) do
      {:error, reason} ->
        {:error, {:branch_unreadable, branch, reason}}

      {:ok, true} ->
        File.mkdir_p!(Path.dirname(dir))

        with :ok <- GitOps.run(["clone", "--branch", branch, url, dir], auth: true),
             :ok <- chmod_face(dir, mode) do
          {:ok, :cloned}
        end

      {:ok, false} ->
        with :ok <- init_face(dir, url, branch),
             :ok <- chmod_face(dir, mode),
             :ok <- Scaffold.face(dir, template, name, opts),
             :ok <- commit(dir, "chore(import): init #{branch}"),
             :ok <- publish_face(dir, branch) do
          {:ok, :published}
        end
    end
  end

  # NOMME L'ECHEC. Un `{:error, :eperm}` nu remonterait jusqu'a l'appelant sans dire de quel
  # repertoire il parle, dans un `with` qui en enchaine cinq.
  defp chmod_face(dir, mode) do
    case File.chmod(dir, mode) do
      :ok -> :ok
      {:error, reason} -> {:error, {:face_mode_failed, dir, mode, reason}}
    end
  end

  # The three host roots of a project, resolved once per entry point. Named rather than threaded as
  # three positional paths: a face is added by extending this map and its template, not by widening
  # every signature between here and the git calls.
  defp face_dirs(name, opts) do
    %{
      code: Path.join(Keyword.get(opts, :code_root, @code_root), name),
      workshop: Path.join(Keyword.get(opts, :workshop_root, @workshop_root), name),
      ops: Path.join(Keyword.get(opts, :ops_root, @ops_root), name)
    }
  end

  defp commit(dir, message) do
    with :ok <- GitOps.run(["-C", dir, "add", "-A"], auth: false) do
      GitOps.run(["-C", dir, "commit", "-m", message], auth: false, author: onboard_author())
    end
  end

  defp push(dir, branch, set_upstream?) do
    args =
      ["-C", dir, "push"] ++
        if(set_upstream?, do: ["-u"], else: []) ++ ["origin", branch]

    GitOps.run(args, auth: true)
  end
end
