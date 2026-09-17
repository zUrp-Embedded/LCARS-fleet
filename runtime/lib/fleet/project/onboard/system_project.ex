defmodule Fleet.Project.Onboard.SystemProject do
  @moduledoc """
  Adopts LCARS itself as a project of the fleet it installs (⚖ user 2026-09-16).

  The tree a machine was installed from is its own source; carrying it as a project puts it where
  every other project lives — a forge repository, three faces, the same labels and the same
  protection — so the fleet can work on it with the tools it gives everyone else.

  ## What this door adds to `Adopt.adopt_project/2`

  Nothing about publishing: it delegates. What it owns is the DECISION of which project that is
  (`Fleet.Layout.system_project/0`, in the bundled catalogue's org) and the fact that a machine
  that already carries it is a machine with nothing to do — not a machine in error. An installer
  replays; a boot replays; neither may fail because the work was done last time.

  ## What it refuses, and why it says so rather than guessing

  A code face that is not a git repository, or has no `main`, is not something to publish under
  the system's name: `adopt_project/2` refuses it, and the refusal names the directory. A forge
  that cannot be read is not a forge that carries nothing.

  **Last revised**: 2026-09-17
  """

  alias Fleet.Catalogue
  alias Fleet.Layout
  alias Fleet.Project.GitOps
  alias Fleet.Project.Onboard

  require Logger

  @typedoc "What a pass did: the project was published, it was already there, or nothing was found."
  @type outcome :: {:ok, :adopted | :already | :seeded} | {:error, term()}

  @doc """
  Adopts the system project if the machine carries its source and the forge does not have it yet.

  Returns `{:ok, :adopted}` when this pass published it, `{:ok, :already}` when the forge already
  carries it (idempotent replay), and an error otherwise. The org is the bundled catalogue's:
  LCARS is a project of the catalogue that installs it, not of the system org — the system org
  carries no project.
  """
  @spec adopt(keyword()) :: outcome()
  def adopt(opts \\ []) do
    name = Keyword.get(opts, :name, Layout.system_project())
    org = Keyword.get(opts, :org, Catalogue.bundled_name())
    onboard = Keyword.get(opts, :onboard, Onboard)

    case seed_code_face(name, opts) do
      :ok ->
        publish(name, org, onboard, opts)

      {:error, reason} = err ->
        Logger.warning(
          "SystemProject: #{org}/#{name} NOT adopted (#{inspect(reason)}) — the code face could " <>
            "not be seeded, and nothing was published."
        )

        err
    end
  end

  # ⚠ LA FACE DE CODE EST UN FAIT DU LAYOUT, PAS DE L'INSTALLEUR. `/home/projects/<projet>` est fixé
  # par `Fleet.Layout`, et le rail conteneur y clone la source à l'init. Le rail POSTE, lui, n'y
  # mettait rien : la machine était installée depuis l'arbre de l'opérateur, et l'adoption refusait
  # en `no_local_main` — mesuré le 2026-09-17 sur le banc 2003, où le module 67 restait en dérive à
  # chaque passe. L'installeur sait D'OÙ vient sa source et le passe en `:from` ; où elle va reste
  # une décision d'ici.
  #
  # UN ARBRE DÉJÀ LÀ N'EST JAMAIS TOUCHÉ : semer par-dessus le travail de quelqu'un est la seule
  # faute irréparable de cette porte.
  @spec seed_code_face(String.t(), keyword()) :: :ok | {:error, term()}
  defp seed_code_face(name, opts) do
    from = Keyword.get(opts, :from)
    code = Onboard.Faces.face_dirs(name, opts).code

    org = Keyword.get(opts, :org, Catalogue.bundled_name())

    cond do
      is_nil(from) -> :ok
      File.dir?(Path.join(code, ".git")) -> :ok
      File.dir?(Path.join(from, ".git")) -> clone_code_face(from, code, org, name)
      arbre_non_vide?(from) -> commit_code_face(from, code, org, name)
      true -> {:error, {:not_adoptable, {:no_source_tree, from}}}
    end
  end

  # Un repertoire VIDE n'est pas une source : sans ce garde, le commit du kit echouerait plus bas,
  # et le refus parlerait de git au lieu de parler de l'arbre qu'on lui a donne.
  defp arbre_non_vide?(from) do
    match?({:ok, [_ | _]}, File.ls(from))
  end

  # ⚠ UN KIT N'A PAS D'HISTOIRE, ET CE N'EST PAS UNE PANNE (⚖ user 2026-09-16, lot 7). Une machine
  # posee par kit (un tar, sans `.git`) porte quand meme sa propre source : un SEUL commit, « l'arbre
  # qui a installe cette machine », a la revision que le kit estampille. Mesure du 2026-09-17 sur
  # LCARS-beta, installee par kit : sans ce chemin, le module 67 derivait a chaque passe sur un
  # `no_source_tree` qui accusait un arbre parfaitement present.
  defp commit_code_face(from, code, org, name) do
    with :ok <- copy_tree(from, code),
         :ok <- GitOps.run(["-C", code, "init", "-q", "-b", "main"], auth: false),
         :ok <- GitOps.run(["-C", code, "add", "-A"], auth: false),
         # ⚠ L'IDENTITE DU COMMIT EST CELLE DE L'ONBOARDING, comme pour les trois faces. Sans elle,
         # git prend celle du compte qui joue — et un siege qui n'a pas configure la sienne fait
         # mourir le commit en « Author identity unknown » (mesure du 2026-09-18 sur LCARS-beta).
         :ok <-
           GitOps.run(["-C", code, "commit", "-q", "-m", kit_message(from)],
             auth: false,
             author: Onboard.Faces.onboard_author()
           ),
         :ok <- point_origin(code, org, name) do
      Logger.info(
        "SystemProject: code face built at #{code} from the kit tree #{from} (one commit)."
      )

      :ok
    else
      {:error, reason} -> {:error, {:not_adoptable, {:seed_failed, code, reason}}}
    end
  end

  defp copy_tree(from, code) do
    File.mkdir_p!(Path.dirname(code))

    case File.cp_r(from, code) do
      {:ok, _} -> :ok
      {:error, reason, path} -> {:error, {:copy_failed, path, reason}}
    end
  end

  # La revision que le kit estampille, quand il en porte une : elle fait la difference entre « la
  # source de cette machine » et « un arbre ».
  defp kit_message(from) do
    rev =
      case File.read(Path.join(from, ".source-revision")) do
        {:ok, raw} -> String.trim(raw)
        _ -> ""
      end

    "chore(system): the tree this machine was installed from" <>
      if(rev == "", do: "", else: " (#{rev})")
  end

  defp clone_code_face(from, code, org, name) do
    # `--no-hardlinks` : la face doit survivre a la suppression de l'arbre de l'operateur. Et
    # l'`origin` local qu'un clone laisse derriere ne reste pas : le remote de cette face est le
    # depot de la forge, celui que le geste d'installation a pose.
    with :ok <- GitOps.run(["clone", "--no-hardlinks", from, code], auth: false),
         :ok <- ensure_main(code),
         :ok <- point_origin(code, org, name) do
      Logger.info("SystemProject: code face seeded at #{code} from #{from}.")
      :ok
    else
      {:error, reason} -> {:error, {:not_adoptable, {:seed_failed, code, reason}}}
    end
  end

  # L'origin de la face : le depot de la forge quand on sait l'adresser, sinon AUCUN. Un origin qui
  # pointe vers l'arbre d'un operateur survivrait a sa suppression et ferait croire a un amont.
  defp point_origin(code, org, name) do
    case Application.get_env(:lcars_fleet, :credentials_forge_auth) do
      %{url_prefix: base} when is_binary(base) and base != "" ->
        url = "#{String.trim_trailing(base, "/")}/#{org}/#{name}.git"
        GitOps.run(["-C", code, "remote", "set-url", "origin", url], auth: false)

      _ ->
        # RETIRER CE QUI N'EXISTE PAS EST UNE ERREUR POUR GIT, pas pour nous : un arbre fraichement
        # initialise (le cas du kit) n'a aucun origin, et le refus parlerait alors de `remote`.
        case GitOps.read(["-C", code, "remote", "get-url", "origin"], auth: false) do
          {:ok, _} -> GitOps.run(["-C", code, "remote", "remove", "origin"], auth: false)
          {:error, _} -> :ok
        end
    end
  end

  # `main` de la face est la revision dont CETTE machine a ete installee : l'arbre de l'operateur
  # est sur sa branche a lui, et un clone en herite. On nomme, on ne deplace rien.
  defp ensure_main(code) do
    case GitOps.read(["-C", code, "rev-parse", "--verify", "--quiet", "refs/heads/main"]) do
      {:ok, _sha} -> :ok
      {:error, _} -> GitOps.run(["-C", code, "switch", "-c", "main"], auth: false)
    end
  end

  defp publish(name, org, onboard, opts) do
    case onboard.adopt_project(name, Keyword.merge(opts, org: org)) do
      {:ok, _result} ->
        Logger.info(
          "SystemProject: #{org}/#{name} adopted — the source this machine was installed from is " <>
            "now a project of its own fleet, with its three faces."
        )

        {:ok, :adopted}

      # The forge already carries it: a replayed installation, or a second boot. Nothing to do,
      # and nothing wrong — this door exists to be replayed.
      {:error, {:repo_already_exists, _full}} ->
        Logger.info("SystemProject: #{org}/#{name} already on the forge — nothing to adopt.")
        {:ok, :already}

      # ⚠ LE DEPOT A SON POSEUR, ET CE N'EST PAS CETTE PORTE. `forge-gestures.sh apply` le cree et y
      # pousse la source pendant l'installation, avec le jeton master ; ici, le jeton viendrait du
      # rail d'autorite, qui ne sert QUE les humains de la flotte — sur un poste neuf il n'y en a
      # pas encore (`not_a_worker`, mesure du 2026-09-17, banc 2003). Une forge qu'on ne peut ni
      # joindre ni prouver n'est donc PAS une panne de cette porte : la face est en place, et le
      # depot est l'affaire du geste. Tout autre refus remonte.
      {:error, {cause, _}} when cause in [:forge_preflight_failed, :forge_unverifiable] ->
        Logger.info(
          "SystemProject: #{org}/#{name} — code face in place; the repository is posed by the " <>
            "install gesture (forge-gestures apply), which holds the master token."
        )

        {:ok, :seeded}

      {:error, reason} = err ->
        Logger.warning(
          "SystemProject: #{org}/#{name} NOT adopted (#{inspect(reason)}) — the machine keeps its " <>
            "source either way; what is missing is the project on the forge."
        )

        err
    end
  end

  # L'arbre dont la machine a ete installee : seul l'installeur (ou l'init du conteneur) le sait, et
  # il le passe par l'environnement parce que ces portes sont des `eval` sans argument.
  defp source_opts do
    case System.get_env("LCARS_SYSTEM_SOURCE") do
      dir when is_binary(dir) and dir != "" -> [from: dir]
      _ -> []
    end
  end

  @doc """
  Measures without writing: does the forge already carry the system project, and does this machine
  carry its source?

  This is what a `check` verb needs — a module that recomposed the address in shell would hold a
  second writing of it. `:present` the forge has it, `:absent` it does not (and the source is
  here to publish), `:no_source` there is nothing to publish, and an error when the forge cannot
  be read: an unreadable forge carries no answer.
  """
  @spec state(keyword()) :: {:ok, :present | :absent | :no_source | :seeded} | {:error, term()}
  def state(opts \\ []) do
    name = Keyword.get(opts, :name, Layout.system_project())
    org = Keyword.get(opts, :org, Catalogue.bundled_name())
    repo = Keyword.get(opts, :onboard_repo, Fleet.Project.Onboard.Repo)
    dirs = Fleet.Project.Onboard.Faces.face_dirs(name, opts)

    case repo.require_forge_absent("#{org}/#{name}", opts) do
      {:error, {:repo_already_exists, _}} ->
        {:ok, :present}

      :ok ->
        # une face absente que l'apply SEMERA n'est pas une machine sans source : ce qui manque est
        # le depot sur la forge, et `check` doit le dire comme tel — sinon le module 67 reste en
        # « rien a publier » sur une machine qui a tout ce qu'il faut.
        if publiable?(dirs, opts), do: {:ok, :absent}, else: {:ok, :no_source}

      # meme regle que pour l'adoption : une forge illisible ne dit rien de la FACE, qui est ce que
      # cette porte tient. Le depot, lui, est mesure par le geste de structure.
      {:error, {cause, _}} when cause in [:forge_preflight_failed, :forge_unverifiable] ->
        if git_tree?(dirs.code), do: {:ok, :seeded}, else: {:ok, :no_source}

      {:error, _} = err ->
        err
    end
  end

  # Y a-t-il de quoi publier : la face est deja un arbre git, ou l'appelant en nomme un a semer.
  defp publiable?(dirs, opts) do
    from = Keyword.get(opts, :from)
    git_tree?(dirs.code) or (is_binary(from) and git_tree?(from))
  end

  defp git_tree?(dir), do: File.dir?(Path.join(dir, ".git"))

  @doc """
  Release door that MEASURES: prints one line and exits 0, whatever the state — a measure is not
  a verdict. `check` of the installer module reads this.
  """
  @spec eval_state() :: no_return()
  def eval_state do
    Fleet.ReleaseDoor.claim_stdout!()
    name = Layout.system_project()
    org = Catalogue.bundled_name()

    case state(source_opts()) do
      {:ok, :present} -> IO.puts("ALREADY #{org}/#{name}")
      {:ok, :seeded} -> IO.puts("SEEDED #{org}/#{name}")
      {:ok, :absent} -> IO.puts("ABSENT #{org}/#{name}")
      {:ok, :no_source} -> IO.puts("NOSOURCE #{org}/#{name}")
      {:error, reason} -> IO.puts("UNREADABLE #{org}/#{name} #{inspect(reason)}")
    end

    System.halt(0)
  end

  @doc """
  Release door for the installer and the container boot: prints one line and exits.

  Exit 0 adopted or already there, 1 refused. The line is what a module relays as its verdict, so
  it names the object and what happened to it, never a bare status.
  """
  @spec eval_adopt() :: no_return()
  def eval_adopt do
    Fleet.ReleaseDoor.claim_stdout!()
    name = Layout.system_project()
    org = Catalogue.bundled_name()

    case adopt(source_opts()) do
      {:ok, :adopted} ->
        IO.puts("ADOPTED #{org}/#{name}")
        System.halt(0)

      {:ok, :already} ->
        IO.puts("ALREADY #{org}/#{name}")
        System.halt(0)

      {:ok, :seeded} ->
        IO.puts("SEEDED #{org}/#{name}")
        System.halt(0)

      {:error, reason} ->
        IO.puts(:stderr, "REFUSED #{org}/#{name} #{inspect(reason)}")
        System.halt(1)
    end
  end
end
