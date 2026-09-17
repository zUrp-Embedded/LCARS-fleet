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
        if File.dir?(Path.join(dirs.code, ".git")), do: {:ok, :absent}, else: {:ok, :no_source}

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

    case state() do
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

    case adopt() do
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
