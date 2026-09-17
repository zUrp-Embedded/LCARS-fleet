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
  @type outcome :: {:ok, :adopted | :already} | {:error, term()}

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

    cond do
      is_nil(from) ->
        :ok

      File.dir?(Path.join(code, ".git")) ->
        :ok

      not File.dir?(Path.join(from, ".git")) ->
        {:error, {:not_adoptable, {:no_source_tree, from}}}

      true ->
        clone_code_face(from, code)
    end
  end

  defp clone_code_face(from, code) do
    # `--no-hardlinks` : la face doit survivre a la suppression de l'arbre de l'operateur. Et pas
    # d'`origin` local derriere : le remote de cette face est la forge, que l'adoption pose.
    with :ok <- GitOps.run(["clone", "--no-hardlinks", from, code], auth: false),
         :ok <- ensure_main(code),
         :ok <- GitOps.run(["-C", code, "remote", "remove", "origin"], auth: false) do
      Logger.info("SystemProject: code face seeded at #{code} from #{from}.")
      :ok
    else
      {:error, reason} -> {:error, {:not_adoptable, {:seed_failed, code, reason}}}
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
  @spec state(keyword()) :: {:ok, :present | :absent | :no_source} | {:error, term()}
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
        from = Keyword.get(opts, :from)

        cond do
          File.dir?(Path.join(dirs.code, ".git")) -> {:ok, :absent}
          is_binary(from) and File.dir?(Path.join(from, ".git")) -> {:ok, :absent}
          true -> {:ok, :no_source}
        end

      {:error, _} = err ->
        err
    end
  end

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

      {:error, reason} ->
        IO.puts(:stderr, "REFUSED #{org}/#{name} #{inspect(reason)}")
        System.halt(1)
    end
  end
end
