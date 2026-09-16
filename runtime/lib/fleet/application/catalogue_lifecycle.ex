defmodule Fleet.Application.CatalogueLifecycle do
  @moduledoc """
  Reports available/installed catalogue states from what the forge carries: the DEPOSITS a search
  finds (what an author pushed) and the STORES the store repository's branches name (what is
  installed). updatable is an installed qualifier, never an automatic update: installation is an
  explicit admin action. No per-human activation state is represented.

  A branch of the store repository, proven by its own manifest, is what determines installed. This
  does not prove local material is installed or usable. The bundled catalogue is always reported
  installed after a successful listing.

  Missing deposit, missing source trailer, or a store whose identity could not be proven, all
  yield nil freshness — never false.
  """

  alias Fleet.Application.CatalogueDeposits
  alias Fleet.Application.CatalogueStores

  @bundled Fleet.Catalogue.bundled_name()

  @type state :: :installed | :available
  @type entry :: %{
          name: String.t(),
          state: state(),
          updatable?: boolean() | nil,
          deposit: CatalogueDeposits.deposit() | nil,
          store: String.t() | nil
        }

  @doc """
  Combines the deposits (a repository search) with the stores (the store repository's branches).
  Search/duplicate/listing errors propagate; sequential reads can straddle changes.
  """
  @spec states(keyword()) :: {:ok, %{String.t() => entry()}} | {:error, term()}
  def states(opts \\ []) do
    repo_mod = Keyword.get(opts, :forge_repo, Fleet.Forge.Client.Repo)
    # The address the STORES WERE READ FROM, not the global default: one source per answer.
    store_repo = Keyword.get(opts, :store_repo, Fleet.Catalogue.store_repo())

    with {:ok, repos} <- repo_mod.search_repos(opts),
         {:ok, deposits} <- CatalogueDeposits.from_repos(repos, opts),
         {:ok, stores} <- CatalogueStores.list(opts) do
      names =
        [@bundled | Map.keys(deposits) ++ Map.keys(stores)] |> Enum.uniq() |> Enum.sort()

      {:ok, Map.new(names, &{&1, entry(&1, deposits[&1], stores[&1], store_repo)})}
    end
  end

  @doc """
  Prints <STATE> <name> <deposit> lines for the CLI. Available/updatable lines name
  the deposit (material a future install would pull); installed lines print -.
  Redirects Logger away from stdout before transport/listing. Exits 0 on success,
  3 for duplicate deposits and 2 for other returned errors.
  """
  @spec eval_main() :: no_return()
  def eval_main do
    Fleet.ReleaseDoor.claim_stdout!()

    case with_transport(fn -> states([]) end) do
      {:ok, entries} ->
        Enum.each(lines(entries), &IO.puts/1)
        System.halt(0)

      {:error, reason} ->
        IO.puts(:stderr, "UNREACHABLE #{inspect(reason)}")
        System.halt(2)
    end
  end

  # Store projection commits can differ from source commits with the same content.
  # Compare the Source-Commit trailer, accepting a 7..40 lowercase-hex prefix;
  # no matching trailer means unknown. This is not a tree or ancestry comparison.
  @source_rx ~r/^Source-Commit:\s*([0-9a-f]{7,40})\s*$/m

  defp updatable?(nil, _head), do: nil

  defp updatable?(deposit, %{message: message}) do
    case Regex.run(@source_rx, message || "") do
      [_, source] -> not String.starts_with?(deposit.sha, source)
      _ -> nil
    end
  end

  @doc """
  Resolves a visible deposit to <repo> <branch> <sha> on stdout for shell cloning.
  Claim stdout before calls that may log, or a log can be parsed as the clone URL.
  Exits 0 for a source, 2 if absent (including store-only names), 3 for duplicate
  deposits and 1 for other returned errors. The bundled #{"fleet"} clause exits 4.
  Refusal of a store-only name does not have a separate exit code.
  """
  @spec eval_source(String.t()) :: no_return()
  def eval_source(@bundled) do
    IO.puts(
      :stderr,
      "BUNDLED #{@bundled} — carried by the release, there is nothing to install from"
    )

    System.halt(4)
  end

  def eval_source(name) when is_binary(name) do
    Fleet.ReleaseDoor.claim_stdout!()

    case with_transport(fn -> CatalogueDeposits.list([]) end) do
      {:ok, deposits} ->
        case Map.fetch(deposits, name) do
          {:ok, d} ->
            IO.puts("#{d.repo} #{d.branch} #{d.sha}")
            System.halt(0)

          :error ->
            IO.puts(:stderr, "ABSENT #{name} — no visible deposit declares this catalogue")
            System.halt(2)
        end

      {:error, reason} ->
        IO.puts(:stderr, "UNREACHABLE #{inspect(reason)}")
        System.halt(1)
    end
  end

  # Tool eval does not start the fleet, so initialize req and Forge's Finch pool here.
  # Stub-based listing tests cannot prove this transport path works in a fresh release.
  defp with_transport(fun) do
    with {:ok, _} <- Application.ensure_all_started(:req),
         {:ok, _} <- Supervisor.start_link([Fleet.Forge.finch_spec()], strategy: :one_for_one) do
      fun.()
    else
      {:error, reason} -> {:error, {:transport, reason}}
    end
  end

  @doc """
  Renders state lines without halting the VM. Installed entries hide the deposit
  unless updatable is true; nil freshness is not distinguished in the text output.
  """
  @spec lines(%{String.t() => entry()}) :: [String.t()]
  def lines(entries), do: Enum.map(entries, fn {name, e} -> line(name, e) end)

  defp line(name, %{state: :installed, updatable?: true, deposit: d}),
    do: "UPDATABLE #{name} #{d.repo}"

  defp line(name, %{state: :installed}), do: "INSTALLED #{name} -"

  defp line(name, %{state: :available, deposit: d}),
    do: "AVAILABLE #{name} #{d.repo}"

  defp entry(@bundled, _deposit, _store, _store_repo),
    do: %{name: @bundled, state: :installed, updatable?: nil, deposit: nil, store: nil}

  defp entry(name, deposit, nil, _store_repo) when is_map(deposit),
    do: %{name: name, state: :available, updatable?: nil, deposit: deposit, store: nil}

  # A store carries its branch head AND that head's message from the listing: one read answered it
  # for every catalogue, where one read per store used to. Freshness still compares the trailer.
  defp entry(name, deposit, %{branch: branch} = store, store_repo) do
    %{
      name: name,
      state: :installed,
      # An unproven store cannot be compared: its manifest could not be read, so freshness is
      # unknown rather than false.
      updatable?: if(Map.get(store, :proven?, true), do: updatable?(deposit, store), else: nil),
      deposit: deposit,
      store: "#{store_repo}:#{branch}"
    }
  end

  # Fallback for no usable deposit/store; a store without a deposit matches the prior clause.
  defp entry(name, _deposit, _store, _store_repo),
    do: %{name: name, state: :available, updatable?: nil, deposit: nil, store: nil}
end
