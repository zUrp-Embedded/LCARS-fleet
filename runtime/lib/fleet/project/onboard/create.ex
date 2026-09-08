defmodule Fleet.Project.Onboard.Create do
  @moduledoc """
  Les deux portes qui font EXISTER un projet : `onboard/2` cree le depot, `import/2` prend un depot
  qui existe deja sur la forge.

  La difference tient en une phrase et elle est fail-loud : `onboard` REFUSE un depot present — il
  scaffolderait par-dessus un `main` qui n'est pas le sien — la ou `import` en fait sa condition
  d'entree. Les deux posent ensuite la meme sequence : les trois faces, la declaration, la
  protection de `main`.
  """

  alias Fleet.Forge.WriteSpacing
  alias Fleet.Layout
  alias Fleet.Project.Onboard
  alias Fleet.Project.Onboard.Faces
  alias Fleet.Project.Onboard.Refute
  alias Fleet.Project.Onboard.Repo
  alias Fleet.Project.Onboard.Scaffold

  require Logger

  @doc """
  Onboard the project `name` (kebab-case slug). `opts`:

    * `:org`           — forge org = the catalogue's name (REQUIRED, cf. `Onboard.required_org/1`)
    * `:description`   — repo description (default `""`)
    * `:pitch`         — pitch phrase (README/spec scaffold; default = description)
    * `:code_root` / `:ops_root` / `:workshop_root` — FS roots, one per face (defaults:
      `/home/projects`, `/home/projects.ops`, `/home/projects.workshop`)
    * `:base_url` / `:token` — forge override (otherwise config `:lcars_fleet, :pilot_forge`)

  Returns `{:ok, %{repo, project_dir, work_dir, doc_dir}}` or `{:error, term()}` (fail-fast) —
  one key per face. On an error return AND on an exception the sequence compensates automatically:
  the forge repo and all three local dirs are removed so a clean retry is possible (see
  `compensate_onboard/5` and `guarded_finish/5` — both exits, the error return AND the raise).

  What still skips the unwind is a BEAM crash — the process dies with the `catch`, not through it.
  Its residue is recoverable agent-side via `delete_project(force: true)`: the dirs it can leave are
  either origin-carrying (identity provable) or empty (provable as debris), which are exactly the
  two proofs that teardown accepts — no host-side `rm` in the loop.
  """
  @spec onboard(String.t(), keyword()) :: {:ok, Onboard.result()} | {:error, term()}
  def onboard(name, opts \\ []) when is_binary(name) do
    dirs = Faces.face_dirs(name, opts)

    # `admit/3` porte le preambule commun aux cinq verbes d'entree — dont le refus de carte, qui
    # doit tomber AVANT que le depot existe : la regle vit chez le seul ecrivain
    # (`Declaration.write/2`) pour qu'aucune porte ne la contourne, et ici on lui evite de refuser
    # apres une creation, donc une compensation.
    with {:ok, org} <- Onboard.required_org(opts),
         :ok <- Onboard.admit(org, name, opts),
         :ok <- Repo.ensure_catalogue_org_on_forge(org, opts),
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

  # `finish_onboard` has TWO ways out and compensation must cover BOTH. An exception — a face root
  # that cannot be created, a git binary gone, a full disk — walks straight past the `case` above,
  # and what it leaves is a repo on the forge plus however many face trees were already built.
  #
  # Measured on a fresh bench, the shape of that failure: `/home/projects.workshop` does not exist,
  # `mkdir_p!` raises, and the forge repo, the cloned-and-committed code face and the initialised
  # ops face ALL survive. The caller gets `tool_crashed` and no way to know a cleanup is owed; the
  # next attempt then meets the 409/refute_existing walls this compensation exists to prevent.
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
    with :ok <- WriteSpacing.gap(opts),
         {:ok, url} <- Repo.repo_url(full_name, opts),
         :ok <- Repo.seed_protocol_labels(full_name, opts),
         :ok <- Faces.clone_main(url, dirs.code),
         :ok <- Scaffold.main(dirs.code, name, Onboard.with_ci_stance(full_name, opts)),
         :ok <- Onboard.write_declaration(dirs.code, full_name, opts),
         :ok <- Faces.commit(dirs.code, "chore(onboard): scaffold initial du projet"),
         :ok <- Faces.push(dirs.code, "main", false),
         :ok <- WriteSpacing.gap(opts),
         :ok <-
           build_writer_face(
             full_name,
             url,
             dirs.ops,
             Layout.ops_branch(),
             "ops",
             name,
             opts
           ),
         :ok <- WriteSpacing.gap(opts),
         :ok <-
           build_writer_face(
             full_name,
             url,
             dirs.workshop,
             Layout.workshop_branch(),
             "workshop",
             name,
             opts
           ),
         :ok <- Faces.lock_main(full_name, opts) do
      Logger.info(
        "ProjectOnboard: #{full_name} ready — main=#{dirs.code}, " <>
          "#{Layout.ops_branch()}=#{dirs.ops}, #{Layout.workshop_branch()}=#{dirs.workshop}"
      )

      {:ok, Onboard.onboard_result(full_name, dirs, opts)}
    end
  end

  # Build-and-publish, for a repo we just created: the branch cannot pre-exist, so unlike
  # `ensure_face/7` there is nothing to clone.
  defp build_writer_face(_full_name, url, dir, branch, template, name, opts) do
    with :ok <- Faces.init_face(dir, url, branch),
         :ok <- Scaffold.face(dir, template, name, opts),
         :ok <- Faces.commit(dir, "chore(onboard): init #{branch}") do
      Faces.publish_face(dir, branch)
    end
  end

  defp compensate_onboard(full_name, dirs, reason, opts) do
    forge =
      case Repo.delete_forge(full_name, opts) do
        {:ok, verdict} -> verdict
        {:error, e} -> {:delete_failed, e}
      end

    Logger.warning(
      "ProjectOnboard: onboard #{full_name} FAILED (#{inspect(reason)}) — compensated: " <>
        "forge #{inspect(forge)}, project_dir #{inspect(Faces.compensate_dir(dirs.code))}, " <>
        "work_dir #{inspect(Faces.compensate_dir(dirs.ops))}, " <>
        "doc_dir #{inspect(Faces.compensate_dir(dirs.workshop))} " <>
        "(a clean retry is possible; incomplete legs above must be cleared first)"
    )
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
  @spec import(String.t(), keyword()) :: {:ok, Onboard.result()} | {:error, term()}
  def import(full_name, opts \\ []) when is_binary(full_name) do
    # L'ORG VIENT DU DEPOT, pas d'une option ni d'un defaut. L'argument de ce verbe EST
    # `owner/nom`, et un projet vit dans l'org de son catalogue : le proprietaire NOMME l'org, il
    # n'y a rien a choisir. Un `opts[:org] || default_org()` rendrait le PREMIER catalogue actif, et
    # l'humain serait alors verifie contre l'org d'un autre catalogue que celui du depot.
    org = full_name |> String.split("/") |> List.first()
    name = Layout.project_name(full_name)
    dirs = Faces.face_dirs(name, opts)

    # ⚠ CE VERBE VERIFIE QUE LA CARTE EST DECLARABLE, COMME LES QUATRE AUTRES. Sans ce controle, un
    # depot importe avec une carte d'atelier (`scope: ticket`) ou une faute de frappe passe ici, la
    # ou les quatre autres refusent.
    # `admit` (local) avant `refute_store` (un aller-retour forge) : la loi d'ordre en trois temps.
    with :ok <- Onboard.admit(org, name, opts),
         :ok <- Refute.refute_store(full_name, opts),
         :ok <- Repo.ensure_catalogue_org_on_forge(org, opts),
         :ok <- refute_existing_or_converge(full_name, dirs, opts),
         :ok <- require_default_branch_main(full_name, opts) do
      case Onboard.finish_import(full_name, dirs, name, opts) do
        {:ok, result} ->
          {:ok, result}

        {:error, reason} = err ->
          Logger.warning(
            "ProjectOnboard: import #{full_name} FAILED (#{inspect(reason)}) — compensated: " <>
              "project_dir #{inspect(Faces.compensate_dir(dirs.code))}, " <>
              "work_dir #{inspect(Faces.compensate_dir(dirs.ops))}, " <>
              "doc_dir #{inspect(Faces.compensate_dir(dirs.workshop))} #{remote_state(reason)}"
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

  # ⚠ PAS DE `require_org_membership` ICI. Comparer le depot a UNE org — celle des opts ou le
  # premier catalogue installe — n'a qu'un comportement atteignable, et c'est un refus faux : un
  # proprietaire qui n'est pas un catalogue installe est deja arrete par
  # `require_catalogue_installed`, et un proprietaire qui l'est n'a aucune raison d'etre compare au
  # PREMIER de la liste. Un tel garde ne peut mordre que le second catalogue, a tort. La question
  # « ce depot est-il enrollable ici ? » a une seule autorite, et c'est le catalogue du proprietaire.

  defp require_default_branch_main(full_name, opts) do
    case Repo.repo_mod(opts).default_branch(full_name, Repo.fc_opts(opts)) do
      {:ok, "main"} -> :ok
      {:ok, other} -> {:error, {:unexpected_default_branch, other}}
      {:error, _} = err -> err
    end
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

          {:already_satisfied,
           Map.put(Onboard.onboard_result(full_name, dirs, opts), :idempotent, true)}
        else
          refusal
        end
    end
  end

  defp satisfied_end_state?(full_name, dirs, opts) do
    ours? =
      Enum.all?([dirs.code, dirs.ops, dirs.workshop], fn dir ->
        Repo.origin_full_name(dir, opts) == {:ok, full_name}
      end)

    # ⚠ SITE 2 SUR 3 — LA DIRECTION SURE EST L'INVERSE DE CELLE DES DEUX AUTRES, et c'est pour ca
    # que la garde ne pouvait pas etre reparee « au seul site cite ». Ici un `{:error, _}` laisse
    # tel quel serait TRUTHY : un import jamais fait passerait pour SATISFAIT et on sauterait le
    # travail. Une forge illisible n'est pas une preuve de publication — elle vaut « pas satisfait »,
    # ce qui coute au pire un re-import idempotent.
    published? =
      Enum.all?([Layout.ops_branch(), Layout.workshop_branch()], fn branch ->
        Repo.repo_mod(opts).branch_exists?(full_name, branch, Repo.fc_opts(opts)) == {:ok, true}
      end)

    ours? and forge_repo_present?(full_name, opts) and published?
  end

  defp forge_repo_present?(full_name, opts) do
    match?({:ok, _branch}, Repo.repo_mod(opts).default_branch(full_name, Repo.fc_opts(opts)))
  end

  # ─── UNE SEULE SOURCE : LE CATALOGUE SUR DISQUE ─────────────────────────────────────────────────
  #
  # ⚖ user. PAS de `generate_repo` — la fonction « template » de Gitea, qui recopie un depot
  # `<catalogue>/project-template` pousse par le conteneur. Un tel depot est une COPIE du catalogue, et
  # une copie derive : mesure, un banc portait un workflow sur les deux, sans que rien ne le dise,
  # parce qu'un `sync` ne se joue qu'a la naissance du conteneur.
  #
  # POURQUOI PAS « GARDER GITEA ET NE COPIER QU'UNE PARTIE » : `GenerateRepoOption` (swagger de la
  # forge, mesure) n'a AUCUN champ de chemin — `git_content` est un booleen, tout ou rien. Gitea ne
  # sait pas peupler depuis un sous-repertoire, donc le depot template devrait porter exactement le
  # squelette, donc faire doublon avec le catalogue qui le porte deja.
  #
  # Le chemin est donc : creation nue, puis `Scaffold.main` depuis le catalogue installe. Une
  # source, pas deux, donc rien a synchroniser ni a comparer.
  defp create_repo(name, org, opts) do
    desc = Keyword.get(opts, :description, "")

    result =
      Repo.repo_mod(opts).create_repo(name, Keyword.merge(opts, org: org, description: desc))

    Repo.classify_create_repo(result, org, name)
  end
end
