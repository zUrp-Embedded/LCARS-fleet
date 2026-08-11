defmodule Fleet.Project.Onboard do
  @moduledoc """
  Onboarding of a project: "idea → the project exists".

  Replicates the multi-face architecture of LCARS itself (one forge repo, **three local repos**):

    * `/home/projects/<name>`       → clone, branch `main`       (the deliverable, push origin)
    * `/home/projects.ops/<name>`  → STANDALONE repo, branch `ops` (orphan) — the RECORD:
      briefs, gate-briefs, verdicts, provenance. Written by the RUNTIME; no pod writes here, and
      since the mount that read it moved, no pod reads it either.
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
  git. Reorg 2026-07-19: onboarding also spawns the project's per-project architect (`maybe_open_architect`).

  Sequence (FAIL-LOUD if the repo already exists on the forge — onboard CREATES, it must NOT
  scaffold over a pre-existing `main`; `import/2` is the safe adopt-an-existing-repo path — and fails
  clearly if the local folder already exists):

    1. `ForgeClient.create_repo` (org `fleet`, `auto_init` → `main` cloneable) — 409 ⇒ `{:error, {:repo_already_exists, _}}`
    2. `git clone --branch main` → `/home/projects/<name>`
    3. scaffold `main` (README, CLAUDE.md, .gitignore, .editorconfig, docs/spec.md, CI)
    4. commit (author=`lcars-system`, committer=git config runtime = the human) + push `main`
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
  `author=lcars-system` (the SYSTEM generates the scaffold from templates; the arch writes no file,
  it **relays** `name`+`pitch` — it is transparent in the git attribution, its trace lives in the request),
  `committer`=the human (git config runtime = **the user who initiated the project → traced**),
  `pusher`=`lcars-system` (`ForgeAuth.git_env`, fleet-wide owner). All avatared (emails → Gitea accounts).
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
          repo: String.t(),
          project_dir: Path.t(),
          work_dir: Path.t(),
          doc_dir: Path.t(),
          # Per-project architect ensure outcome (reorg 2026-07-19) — reported, never dropped:
          # %{status: "up", pod_id: _} | %{status: "failed", reason: _}.
          architect: map()
        }

  @doc """
  Onboard the project `name` (kebab-case slug). `opts`:

    * `:org`           — forge org (default `"fleet"`)
    * `:description`   — repo description (default `""`)
    * `:pitch`         — pitch phrase (README/spec scaffold; default = description)
    * `:code_root` / `:ops_root` / `:workshop_root` — FS roots, one per face (defaults:
      `/home/projects`, `/home/projects.ops`, `/home/projects.workshop`)
    * `:base_url` / `:token` — forge override (otherwise config `:fleet_pilot, :forge`)

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
    org = Keyword.get(opts, :org) || default_org()
    dirs = face_dirs(name, opts)

    with :ok <- validate_name(name),
         :ok <- ensure_human_provisioned(org, opts),
         :ok <- refute_existing_or_converge("#{org}/#{name}", dirs, opts),
         {:ok, full_name, provision} <- create_repo(name, org, opts) do
      case guarded_finish(full_name, provision, dirs, name, opts) do
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
  # Measured 2026-08-09 on a fresh bench, and it is the shape of the whole failure: `/home/
  # projects.doc` did not exist, `mkdir_p!` raised, and the forge repo, the cloned-and-committed
  # code face and the initialised ops face ALL survived. The caller got `tool_crashed` and no way
  # to know a cleanup was owed; the next attempt then met the 409/refute_existing walls this
  # compensation exists to prevent.
  #
  # RE-RAISED, NOT SWALLOWED. The crash stays a crash, with its kind and its stacktrace — only the
  # machine is left clean. Converting it to `{:error, _}` here would dress an unforeseen failure as
  # a handled one, and a caller cannot tell those apart afterwards.
  defp guarded_finish(full_name, provision, dirs, name, opts) do
    finish_onboard(full_name, provision, dirs, name, opts)
  catch
    kind, payload ->
      compensate_onboard(full_name, dirs, {kind, payload}, opts)
      :erlang.raise(kind, payload, __STACKTRACE__)
  end

  defp finish_onboard(full_name, provision, dirs, name, opts) do
    with :ok <- Fleet.Forge.WriteSpacing.gap(opts),
         {:ok, url} <- repo_url(full_name, opts),
         :ok <- maybe_seed_protocol_labels(provision, full_name, opts),
         :ok <- clone_main(url, dirs.code),
         :ok <- maybe_scaffold_main(provision, dirs.code, name, opts),
         :ok <- Fleet.Project.Intensity.write(dirs.code, opts),
         :ok <- commit(dirs.code, onboard_commit_msg(provision)),
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

  defp ensure_architect(repo, opts) do
    ensure = Keyword.get(opts, :ensure_architect, &Fleet.Project.Architect.ensure/2)

    case ensure.(repo, opts) do
      {:ok, pod_id} -> %{status: "up", pod_id: pod_id}
      {:error, reason} -> %{status: "failed", reason: inspect(reason)}
    end
  end

  @doc """
  The forge orgs a project can be onboarded into — one per ACTIVE catalogue, and the org IS the
  catalogue's name.

  Lives here rather than being read from `Fleet.Catalogue` by every caller: "where can a project
  live" is an onboarding question, and the MCP surface reaches this domain but not the catalogue —
  the graph says so, and widening it to answer a project question would be widening it for the
  wrong reason.
  """
  @spec active_orgs() :: [String.t()]
  def active_orgs, do: Fleet.Catalogue.active_names()

  # Le defaut des quatre portes, quand l'appelant ne nomme pas d'org. C'etait le litteral `"fleet"`
  # a cinq endroits — le nom d'UN catalogue, ecrit cinq fois. Il vaut desormais le premier catalogue
  # actif, donc `fleet` sur un deploiement qui n'apporte rien, et le sien sur un deploiement qui
  # apporte le sien. `project_create` passe `:org` explicitement depuis le guichet ; ce defaut sert
  # les appels directs et les tests.
  defp default_org do
    case active_orgs() do
      [org | _] -> org
      [] -> "fleet"
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

    with :ok <- refute_same_catalogue(full_name, target_catalogue),
         :ok <- require_target_installed(target_catalogue),
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

  # Meme refus que l'import, et pour la meme raison : migrer vers un catalogue que cette boite n'a
  # pas produirait un projet dont personne ne sait lire le metier — et le poller ne decouvre que sur
  # les orgs des catalogues ACTIFS, donc le projet deviendrait invisible, pas casse.
  defp require_target_installed(target) do
    actives = active_orgs()
    if target in actives, do: :ok, else: {:error, {:catalogue_not_installed, target, actives}}
  end

  # Rend les faces REELLEMENT repointees, pas celles qu'on visait. La difference n'est pas
  # cosmetique : sur un banc, ce geste a annonce « trois faces repointees » sur une boite ou les
  # trois etaient absentes — la moitie forge etait juste, et le rapport mentait. Un appelant qui
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

    case migrate(full_name, target) do
      {:ok, %{repo: new_name, faces: faces, absent: absent}} ->
        IO.puts("migre : #{full_name} -> #{new_name}")
        for d <- faces, do: IO.puts("  origin repointe : #{d}")

        # Une face jamais ouverte ICI est normale, et le taire ferait lire « rien a repointer »
        # comme « tout est repointe ». On dit ce qu'on n'a pas fait.
        for d <- absent, do: IO.puts("  face absente (jamais ouverte ici) : #{d}")

        System.halt(0)

      {:error, {:catalogue_not_installed, cat, actives}} ->
        IO.puts(:stderr, "REFUSE : le catalogue #{inspect(cat)} n'est pas actif sur cette boite.")
        IO.puts(:stderr, "  actifs : #{Enum.join(actives, ", ")}")

        IO.puts(
          :stderr,
          "  un projet migre vers un catalogue absent devient INVISIBLE : le poller"
        )

        IO.puts(:stderr, "  ne decouvre que sur les orgs des catalogues actifs.")
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
  Imports an existing `owner/name` forge repository without changing its `main` content.

  The repository must belong to the configured org and use `main` as its default branch. The call
  creates the three local faces, creates or clones each writer branch, reapplies branch protection
  and compensates only its local artifacts on failure. Existing writer branches are preserved.
  """
  @spec import(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def import(full_name, opts \\ []) when is_binary(full_name) do
    # L'ORG VIENT DU DEPOT, pas d'une option ni d'un defaut. L'argument de ce verbe EST
    # `owner/nom`, et un projet vit dans l'org de son catalogue : le proprietaire NOMME l'org, il
    # n'y a rien a choisir. Avant, `opts[:org] || default_org()` rendait le PREMIER catalogue actif,
    # et l'humain etait alors verifie contre l'org d'un autre catalogue que celui du depot.
    org = full_name |> String.split("/") |> List.first()
    name = Fleet.Layout.project_name(full_name)
    dirs = face_dirs(name, opts)

    with :ok <- validate_name(name),
         :ok <- require_catalogue_installed(full_name),
         :ok <- ensure_human_provisioned(org, opts),
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
              "doc_dir #{inspect(compensate_dir(dirs.workshop))} (repo untouched — " <>
              "pre-existing; a clean retry is possible)"
          )

          err
      end
    else
      {:already_satisfied, result} -> {:ok, result}
      {:error, _} = err -> err
    end
  end

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

      with :ok <- validate_name(name),
           :ok <- ensure_human_provisioned(catalogue, opts),
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

  # The names already carried by an ACTIVE catalogue org. Fail-loud: an unreachable org would make
  # the candidate list too WIDE, i.e. offer to import what is already in.
  defp enrolled_names(repo, fc) do
    Enum.reduce_while(active_orgs(), {:ok, MapSet.new()}, fn org, {:ok, acc} ->
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
    if owner in active_orgs(),
      do: {:error, {:source_already_enrolled, source, owner}},
      else: :ok
  end

  defp require_destination_catalogue(catalogue) do
    actives = active_orgs()

    if catalogue in actives,
      do: :ok,
      else: {:error, {:catalogue_not_installed, catalogue, actives}}
  end

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

  defp require_catalogue_installed(full_name) do
    cat = full_name |> String.split("/") |> List.first()
    actives = active_orgs()

    if cat in actives do
      :ok
    else
      {:error, {:catalogue_not_installed, cat, actives}}
    end
  end

  defp finish_import(full_name, dirs, name, opts) do
    with {:ok, url} <- repo_url(full_name, opts),
         :ok <- clone_main(url, dirs.code),
         :ok <- ensure_writer_faces(full_name, url, dirs, name, opts),
         :ok <- lock_main(full_name, opts) do
      Logger.info(
        "ProjectOnboard: #{full_name} imported — main=#{dirs.code}, " <>
          "#{Fleet.Layout.ops_branch()}=#{dirs.ops}, #{Fleet.Layout.workshop_branch()}=#{dirs.workshop}"
      )

      {:ok, onboard_result(full_name, dirs, opts)}
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

  The onboarder could `create`, `open`, `import`, `adopt`, `close`, `revise` and `delete` a
  project, and could not LIST them: it was able to destroy a project it had no way to name. This
  is that missing half, and it is a pure read — the only listing in the delegation surface that
  writes nothing.

  Enumerated from DISK (`code_root`), which is what "this fleet's projects" means: a repo on
  the forge that was never cloned here is not something this box can act on, and a disk project not
  yet published is precisely what `project_publish` exists for.

  Per project, three facts and no derivation:

    * the DECLARED card and level (`intensity.json`), reported as declared or NOT. An undeclared
      project falls back to the fleet default at burn time, and that fallback is deliberately NOT
      applied here: reporting the effective card would make an undeclared project indistinguishable
      from one that declared the default on purpose, and `ProjectIntensity.pipeline_default/2`
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
    full_name = "#{Keyword.get(opts, :org) || default_org()}/#{name}"

    %{"name" => name, "repo" => full_name}
    |> Map.merge(declared_intensity(Path.join(root, name)))
    |> Map.merge(parked_state(full_name, opts))
  end

  # What the project DECLARES, never what it would fall back to.
  defp declared_intensity(proj_dir) do
    case File.read(Path.join(proj_dir, "intensity.json")) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, %{"pipeline_default" => card} = decl} when is_binary(card) ->
            %{
              "card" => card,
              "card_source" => "declared",
              # `"level"`, et PAS `"intensity_level"` : c'est la cle que
              # `ProjectIntensity.compose/1` ecrit. Le lecteur en cherchait une autre, donc ce
              # champ etait nil sur TOUT projet declare — et le test qui le couvrait fabriquait sa
              # fixture a la main, dans la forme du lecteur, jamais dans celle de l'ecrivain.
              "level" => Map.get(decl, "level"),
              "declared_by" => Map.get(decl, "declared_by")
            }

          _ ->
            %{"card" => nil, "card_source" => "invalid", "level" => nil}
        end

      {:error, :enoent} ->
        %{"card" => nil, "card_source" => "undeclared", "level" => nil}

      {:error, reason} ->
        %{
          "card" => nil,
          "card_source" => "unreadable",
          "level" => nil,
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
    org = Keyword.get(opts, :org) || default_org()
    full_name = "#{org}/#{name}"
    dirs = face_dirs(name, opts)

    with :ok <- validate_name(name),
         :ok <- ensure_human_provisioned(org, opts),
         :ok <- require_local_main(dirs.code),
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
         :ok <- maybe_seed_protocol_labels(:bare, full_name, opts),
         :ok <- set_origin(dirs.code, url),
         :ok <- ensure_intensity(dirs.code, opts),
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

  # A present declaration is LEFT AS-IS (the burn validates loudly; adopt does not overwrite the
  # user's engraving) — an absent one is written from the relayed declaration (or the honest C0
  # default) and committed, BEFORE the single main push (v2-1 of the 6-16/6-31 plan: pushed
  # AFTER, it would never reach the forge and both lock_main reads would fall back to the
  # default-card jury in silence).
  defp ensure_intensity(
         proj_dir,
         opts,
         msg \\ "chore(adopt): déclaration de criticité (intensity.json)"
       ) do
    if File.exists?(Path.join(proj_dir, "intensity.json")) do
      :ok
    else
      with :ok <- Fleet.Project.Intensity.write(proj_dir, opts) do
        commit(proj_dir, msg)
      end
    end
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
       is never repatriated silently), cleaned on EVERY exit. The forge auth extraheader is
       PREFIX-scoped (ForgeAuth) so it never leaks to the external host; the optional external
       credential rides `LCARS_EXTERNAL_GIT_TOKEN` (operator input at gesture time, never a
       recipe product — public tokenless is the nominal path).
    3. ADOPTION GATE (the parking-lot USB, BL-6-16): a non-empty `.claude/` tree is refused EN
       BLOC (`{:foreign_claude_dir, _}` — we do not adopt someone else's hooks; org repos
       re-enter via `import/2`, never through this verb), and every `CLAUDE.md` must pass
       `Fleet.ReceptionFilter` (`{:hostile_material, label, path}` otherwise). Nothing reaches
       the org on a refusal — the operator expurges at the SOURCE and retries.
    4. Default branch → `main`, THREE cases: already main → no-op; main absent → rename;
       default ≠ main while a remote `main` EXISTS → `{:branch_collision, _}` (half-migrated
       repos are common; we never guess which is the real one).
    5. Empty org repo + protocol labels + intensity committed IN the scratch BEFORE the push
       (the push must CARRY intensity.json or every later jury read falls back in silence) →
       push main (full history) → the local `finish_import` leg (clone from OUR forge,
       ops, protection — its `lock_main` reads the now-present local intensity).

  Refusals before any effect: dirs already on machine (`{:already_on_machine, _}` — that
  project wants `open`/`import`), forge repo existing (`{:repo_already_exists, _}`).
  Compensation: forge repo deleted DIRECT (the 6-32 lesson — an empty just-created repo probes
  absent through delete_forge and would leak) + both local dirs; the scratch dies in `after`.
  """
  @spec import_external(String.t(), String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def import_external(url, name, opts \\ []) when is_binary(url) and is_binary(name) do
    org = Keyword.get(opts, :org) || default_org()
    full_name = "#{org}/#{name}"
    dirs = face_dirs(name, opts)
    # Injection seam over the pure gate (tests drive file:// fixtures) — prod default enforces.
    url_gate = Keyword.get(opts, :url_gate, &default_external_url_gate/1)

    with :ok <- validate_name(name),
         :ok <- url_gate.(url),
         :ok <- ensure_human_provisioned(org, opts),
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

  # The compensable window — finish_adopt's proven order (intensity BEFORE push), then the
  # existing local import leg for what it does (clone from OUR forge brings intensity.json
  # back down, so ITS lock_main reads the right jury).
  defp intensity_commit_message(opts) do
    door =
      case Keyword.get(opts, :source_host, "") do
        "depot:" <> _ -> "import-depot"
        _ -> "import-externe"
      end

    "chore(#{door}): déclaration de criticité (intensity.json)"
  end

  defp finish_external(full_name, forge_url, scratch, dirs, name, opts) do
    with :ok <- Fleet.Forge.WriteSpacing.gap(opts),
         :ok <- maybe_seed_protocol_labels(:bare, full_name, opts),
         # The commit message names the ACTUAL door: this leg is shared by the external import and
         # the deposit, and a deposit whose history says "import-externe" tells the project's own
         # log something that did not happen.
         :ok <- ensure_intensity(scratch, opts, intensity_commit_message(opts)),
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

    case Fleet.Credentials.Shell.git(
           ["clone", "--no-recurse-submodules", with_external_token(url), scratch],
           timeout_ms: timeout
         ) do
      {:ok, {_, 0}} -> :ok
      {:ok, {out, code}} -> {:error, {:external_clone_failed, {code, String.slice(out, 0, 500)}}}
      {:error, reason} -> {:error, {:external_clone_failed, reason}}
    end
  end

  # Operator credential for a PRIVATE external repo — env at gesture time, never a recipe
  # product (first-admin doctrine). Injected as URL userinfo (both GH and GitLab accept an
  # oauth2 basic pair); the effective URL is never logged.
  defp with_external_token(url) do
    case System.get_env("LCARS_EXTERNAL_GIT_TOKEN") do
      nil -> url
      "" -> url
      token -> url |> URI.parse() |> struct!(userinfo: "oauth2:#{token}") |> URI.to_string()
    end
  end

  # The parking-lot USB check (BL-6-16/6-31): instruction-tier material only — scanning the
  # whole code would drown in false positives (a README legitimately says "force-push").
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
      # THE WORKERS DIE BEFORE THEIR WORLD DOES. Until now only the architect was stopped, so an
      # engineer in flight outlived the removal of its own project: its workspace still existed, so
      # it did not even crash — it kept reading a reference that was no longer there and carried on.
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
         :ok <- require_loadable_card(card),
         {:ok, url} <- repo_url(full_name, opts) do
      previous = declared_card(proj_dir)
      scratch = scratch_dir(name)

      try do
        with :ok <- clone_main(url, scratch),
             :ok <-
               Fleet.Project.Intensity.write(
                 scratch,
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

  defp require_loadable_card(card) when is_binary(card) and card != "" do
    _ = Fleet.Workflow.Loader.load!(card)
    :ok
  rescue
    _ -> {:error, {:unknown_card, card}}
  end

  defp require_loadable_card(_absent), do: {:error, :workflow_map_required}

  defp declared_card(proj_dir) do
    with {:ok, raw} <- File.read(Path.join(proj_dir, "intensity.json")),
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

  # A REVISION REWRITES THE WHOLE DECLARATION, AND IT USED TO REWRITE IT FROM THE OPTS ALONE.
  # `ProjectIntensity.compose/1` is a pure function of its opts — correct for an ONBOARD, where
  # "absent" means "the human declared nothing". At a REVISION "absent" means "the reviser did not
  # mention it", and the two were indistinguishable: a revision naming only the card DELETED
  # `level`, `nature` and `max_fan` — the entire record of the framing interview — while
  # `declared_by` moved to the reviser. Measured on the E2E fixture: C3 / "outil interne" /
  # max_fan 4 went in, only the card came out.
  #
  # So the carry-forward lives HERE, at the revision's edge, and `compose/1` stays a pure function
  # of what it is handed. What the revision states wins; what it does not state survives.
  #
  # ⚠ RESIDUE, NAMED: `declared_by` ends up as the reviser for the WHOLE record, including a level
  # a human declared and this revision merely carried. It names the last writer, not the origin of
  # every field, and the schema (`lcars/intensity-v1`) has no per-field provenance. It is the
  # smaller lie: the alternative was deleting the human's declaration outright.
  defp revision_write_opts(opts, previous) do
    [
      workflow_map: Keyword.get(opts, :workflow_map),
      intensity_justification: Keyword.get(opts, :justification),
      intensity_level: Keyword.get(opts, :intensity_level) || Map.get(previous, "level"),
      intensity_nature: Keyword.get(opts, :nature) || Map.get(previous, "nature"),
      max_fan: Keyword.get(opts, :max_fan) || Map.get(previous, "max_fan"),
      onboarded_by: Keyword.get(opts, :revised_by) || "unknown"
    ]
  end

  # The declaration currently on the machine, or `%{}` when there is none/unreadable — the caller
  # then carries nothing forward, which is exactly the old behaviour for a project that never had a
  # declaration to lose.
  defp current_declaration(proj_dir) do
    with {:ok, raw} <- File.read(Path.join(proj_dir, "intensity.json")),
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

  # `require_org_membership/2` a ete RETIRE ici (2026-08-11). Il comparait le depot a UNE org —
  # celle des opts ou le premier catalogue actif — et son seul comportement atteignable etait un
  # refus faux : un proprietaire qui n'est pas un catalogue actif est deja arrete par
  # `require_catalogue_installed`, et un proprietaire qui l'est n'a aucune raison d'etre compare au
  # PREMIER de la liste. Il ne pouvait donc mordre que le second catalogue, a tort. La question
  # « ce depot est-il enrollable ici ? » a une seule autorite, et c'est le catalogue du proprietaire.

  defp require_default_branch_main(full_name, opts) do
    case repo_mod(opts).default_branch(full_name, fc_opts(opts)) do
      {:ok, "main"} -> :ok
      {:ok, other} -> {:error, {:unexpected_default_branch, other}}
      {:error, _} = err -> err
    end
  end

  defp ensure_writer_faces(full_name, url, dirs, name, opts) do
    with :ok <-
           ensure_face(
             full_name,
             url,
             dirs.ops,
             Fleet.Layout.ops_branch(),
             "ops",
             name,
             opts
           ) do
      ensure_face(
        full_name,
        url,
        dirs.workshop,
        Fleet.Layout.workshop_branch(),
        "workshop",
        name,
        opts
      )
    end
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

    if seeded_project?(repo, opts), do: protect_main(repo, opts), else: :ok
  end

  defp seeded_project?(repo, opts) do
    repo != project_template(opts) and
      repo_mod(opts).branch_exists?(repo, "ops", fc_opts(opts))
  end

  defp protect_main(repo, opts) do
    rule = %{
      rule_name: "main",
      required_approvals: length(Roles.project_jury(repo, opts)),
      dismiss_stale_approvals: true,
      block_on_rejected_reviews: true,
      enable_push: false,
      # THE CI GATE IS THE FORGE'S, NOT THE RUNTIME'S. Measured 2026-08-03 on a live bench: a PR
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
      status_check_contexts: ["CI / *"]
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

  defp ensure_human_provisioned(org, opts) do
    users = Keyword.get(opts, :forge_users, ForgeClient.Repo)
    human = Keyword.get(opts, :human) || Fleet.Credentials.Human.current!()
    fc = fc_opts(opts)

    case users.user_exists?(human, fc) do
      {:ok, false} ->
        {:error, {:human_not_provisioned, human, provisioning_gestures(:account, human, org)}}

      {:error, reason} ->
        {:error, {:forge_preflight_failed, reason}}

      {:ok, true} ->
        case users.team_member?(org, "humans", human, fc) do
          {:ok, true} ->
            :ok

          {:ok, false} ->
            {:error, {:human_not_provisioned, human, provisioning_gestures(:team, human, org)}}

          # DR-018
          {:error, {:http, 403, _}} ->
            if Keyword.get(opts, :allow_unverifiable_human_team?, false) do
              Logger.warning(
                "ProjectOnboard: preflight team-check `humans` NOT VERIFIABLE for #{human} (403 — the " <>
                  "runtime token cannot read team membership) → onboarding in EXPLICIT DEGRADED MODE " <>
                  "(allow_unverifiable_human_team?: true). Human admission is NOT proven; downstream " <>
                  "create_issue remains the net."
              )

              :ok
            else
              {:error,
               {:human_team_unverifiable, human, provisioning_gestures(:team_read, human, org)}}
            end

          {:error, reason} ->
            {:error, {:forge_preflight_failed, reason}}
        end
    end
  end

  defp provisioning_gestures(:account, human, org) do
    "forge account '#{human}' does not exist — admin gestures (admin token required): " <>
      "1) POST /api/v1/admin/users {\"username\":\"#{human}\",\"email\":\"#{human}@lcars.local\"," <>
      "\"password\":\"<initial>\",\"must_change_password\":true}; " <>
      "2) add it to the 'humans' team of org '#{org}' (cf. the :team gesture). " <>
      "Then re-run the onboarding."
  end

  defp provisioning_gestures(:team, human, org) do
    "account '#{human}' exists but is NOT a member of the 'humans' team of org '#{org}' — " <>
      "admin gesture: GET /api/v1/orgs/#{org}/teams → id of 'humans', then " <>
      "PUT /api/v1/teams/<id>/members/#{human}. Then re-run the onboarding."
  end

  defp provisioning_gestures(:team_read, human, org) do
    "membership of '#{human}' in the 'humans' team of org '#{org}' is NOT VERIFIABLE " <>
      "(403 — the runtime token has no right to read GET /api/v1/teams/<id>/members/<u>). " <>
      "Options: 1) grant the runtime token team-read (org owner, or member of 'humans'); " <>
      "2) prove the membership by adding '#{human}' to 'humans' (cf. the :team gesture); " <>
      "3) onboard in EXPLICIT DEGRADED MODE with `allow_unverifiable_human_team?: true` (human " <>
      "admission will NOT be proven — downstream create_issue remains the net)."
  end

  defp validate_name(name) do
    if Regex.match?(~r/^[a-z0-9][a-z0-9-]*[a-z0-9]$/, name),
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

    published? =
      Enum.all?([Fleet.Layout.ops_branch(), Fleet.Layout.workshop_branch()], fn branch ->
        repo_mod(opts).branch_exists?(full_name, branch, fc_opts(opts))
      end)

    ours? and forge_repo_present?(full_name, opts) and published?
  end

  defp forge_repo_present?(full_name, opts) do
    match?({:ok, _branch}, repo_mod(opts).default_branch(full_name, fc_opts(opts)))
  end

  defp create_repo(name, org, opts) do
    desc = Keyword.get(opts, :description, "")
    template = project_template(opts)

    case repo_mod(opts).generate_repo(
           template,
           name,
           Keyword.merge(opts, org: org, description: desc)
         ) do
      {:ok, :already_exists} ->
        {:error, {:repo_already_exists, "#{org}/#{name}"}}

      {:ok, full_name} when is_binary(full_name) ->
        {:ok, full_name, :generated}

      {:error, :template_missing} ->
        Logger.warning(
          "ProjectOnboard: forge template #{template} missing — bare create + local scaffold " <>
            "(run `mix lcars.project_template.sync` to restore the native path)"
        )

        result =
          repo_mod(opts).create_repo(name, Keyword.merge(opts, org: org, description: desc))

        with {:ok, full_name} <- classify_create_repo(result, org, name) do
          {:ok, full_name, :bare}
        end

      {:error, _} = err ->
        err
    end
  end

  defp maybe_scaffold_main(:generated, _proj_dir, _name, _opts), do: :ok
  defp maybe_scaffold_main(:bare, proj_dir, name, opts), do: Scaffold.main(proj_dir, name, opts)

  defp maybe_seed_protocol_labels(:generated, _full_name, _opts), do: :ok

  # BL-6-33
  defp maybe_seed_protocol_labels(:bare, full_name, opts) do
    seeder =
      Keyword.get(opts, :ensure_labels, &Fleet.Forge.Client.ensure_protocol_labels/2)

    case seeder.(full_name, fc_opts(opts)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:protocol_labels, reason}}
    end
  end

  defp onboard_commit_msg(:generated),
    do: "chore(onboard): déclaration de criticité (intensity.json)"

  defp onboard_commit_msg(:bare), do: "chore(onboard): scaffold initial du projet"

  @doc """
  Returns the configured forge template repository, defaulting to `"fleet/project-template"`.
  """
  @spec project_template(keyword()) :: String.t()
  def project_template(opts \\ []) do
    Keyword.get(opts, :project_template) ||
      Application.get_env(:fleet_pilot, :project_template, "fleet/project-template")
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
      Keyword.get(opts, :base_url) || Application.get_env(:fleet_pilot, :forge, [])[:base_url]

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
  # shape for both writer faces: the ONLY per-face inputs are the branch and the template subtree,
  # so a third one costs a call site and no new logic.
  defp ensure_face(full_name, url, dir, branch, template, name, opts) do
    if repo_mod(opts).branch_exists?(full_name, branch, fc_opts(opts)) do
      File.mkdir_p!(Path.dirname(dir))
      GitOps.run(["clone", "--branch", branch, url, dir], auth: true)
    else
      with :ok <- init_face(dir, url, branch),
           :ok <- Scaffold.face(dir, template, name, opts),
           :ok <- commit(dir, "chore(import): init #{branch}") do
        publish_face(dir, branch)
      end
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
