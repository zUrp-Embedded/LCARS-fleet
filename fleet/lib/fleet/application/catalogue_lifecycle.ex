defmodule Fleet.Application.CatalogueLifecycle do
  @moduledoc """
  The state of every catalogue this forge knows about — `available`, `installed`, `updatable`.

  ## Two states, and a qualifier on one of them

  ⚖ user, 2026-08-16. A catalogue is INSTALLED (the forge carries its source, everyone is served
  by it) or AVAILABLE (somebody deposited it, nobody installed it). There is no third state and no
  per-human declaration: activation was a display filter that decided what the fleet worked on, and
  it is gone.

  `updatable` is not a third state — it is `installed` plus a FACT: the deposit has moved since the
  install. It never acts on its own. ⚖ user, in capitals: **never an automatic update**; the fact
  is displayed, and `lcars catalogue install` is the only thing that changes anything.

  ## What signs an installation

  `<org>/#{"catalogue"}` — the source WE pushed into the catalogue's own org. Not "the org exists":
  an org without its source is an interrupted install, and no box can serve a catalogue whose
  material is nowhere. Signing on the org alone would report such a catalogue as ready and let a
  boot discover the hole. The store is the narrower signature and it is the one that matters.

  ## The reference catalogue is installed by construction

  `#{"fleet"}` ships inside the release. The box can serve it without asking anybody, so its state
  is not a forge question — and answering "available" for it, on a forge that carries no
  `fleet/catalogue`, would be a lie about the only catalogue that always works.

  ## An installed catalogue whose deposit vanished

  It stays INSTALLED. Its source is in its org and the fleet serves it; what is lost is the ability
  to say whether it is up to date, because the thing to compare against is gone — deleted, renamed,
  or turned private. `updatable?` is `nil` there, and `nil` is not `false`: one means "we cannot
  know", the other means "it is current", and collapsing them would announce a stale catalogue as
  fresh.
  """

  alias Fleet.Application.CatalogueDeposits

  @bundled "fleet"

  @type state :: :installed | :available
  @type entry :: %{
          name: String.t(),
          state: state(),
          updatable?: boolean() | nil,
          deposit: CatalogueDeposits.deposit() | nil,
          store: String.t() | nil
        }

  @doc """
  Every catalogue the forge knows, by name, with its state.

  ONE `/repos/search` feeds both halves: reading twice could straddle a push and describe a state
  nobody ever had. A duplicate deposit propagates its refusal — a listing that silently dropped one
  of two claimants would be exactly the guess we refuse to make.
  """
  @spec states(keyword()) :: {:ok, %{String.t() => entry()}} | {:error, term()}
  def states(opts \\ []) do
    repo_mod = Keyword.get(opts, :forge_repo, Fleet.Forge.Client.Repo)

    with {:ok, repos} <- repo_mod.search_repos(opts),
         {:ok, deposits} <- CatalogueDeposits.from_repos(repos, opts) do
      stores = stores(repos)

      names =
        [@bundled | Map.keys(deposits) ++ Map.keys(stores)] |> Enum.uniq() |> Enum.sort()

      # ⚠ `entry/5` NE PEUT PAS ECHOUER, et le compilateur l'a dit avant moi : j'avais ecrit une
      # branche d'erreur qu'aucune clause ne produit. C'est deliberé et ca merite d'etre lu comme
      # tel — une lecture de tete de store qui echoue rend « installe, fraicheur inconnue », parce
      # qu'un store illisible n'est pas un catalogue non installe. Ce qui peut echouer est en amont
      # (la forge, le doublon), et ces deux-la remontent.
      {:ok, Map.new(names, &{&1, entry(&1, deposits[&1], stores[&1], repo_mod, opts)})}
    end
  end

  @doc """
  `eval` door for `lcars catalogue list` — one `<STATE> <name> <detail>` line per catalogue.

  The CLI has NO forge access by design, and every one of these states is a forge fact. It asks the
  release through the same door `catalogue verify` already uses. The door speaks WORDS, not a
  formatted table: a column added later must not have to agree across two languages.
  """
  @spec eval_main() :: no_return()
  def eval_main do
    case states([]) do
      {:ok, entries} ->
        Enum.each(entries, fn {name, e} -> IO.puts(line(name, e)) end)
        System.halt(0)

      {:error, {:duplicate_catalogues, dups}} ->
        Enum.each(dups, fn {name, repos} ->
          IO.puts(:stderr, "DUPLICATE #{name} #{Enum.join(Enum.sort(repos), " ")}")
        end)

        System.halt(3)

      {:error, reason} ->
        IO.puts(:stderr, "UNREACHABLE #{inspect(reason)}")
        System.halt(2)
    end
  end

  defp line(name, %{state: :installed, updatable?: true, deposit: d}),
    do: "UPDATABLE #{name} #{d.repo}"

  defp line(name, %{state: :installed, updatable?: nil}),
    do: "INSTALLED #{name} -"

  defp line(name, %{state: :installed, deposit: d}),
    do: "INSTALLED #{name} #{(d && d.repo) || "-"}"

  defp line(name, %{state: :available, deposit: d}),
    do: "AVAILABLE #{name} #{d.repo}"

  # The bundled reference: installed by construction, and never comparable to a deposit — the
  # release carries its material, so nothing on the forge decides its state.
  defp entry(@bundled, _deposit, _store, _repo_mod, _opts),
    do: %{name: @bundled, state: :installed, updatable?: nil, deposit: nil, store: nil}

  defp entry(name, deposit, nil, _repo_mod, _opts) when is_map(deposit),
    do: %{name: name, state: :available, updatable?: nil, deposit: deposit, store: nil}

  defp entry(name, deposit, store, repo_mod, opts) when is_map(store) do
    full = store["full_name"]
    branch = store["default_branch"] || "main"

    case repo_mod.branch_sha(full, branch, opts) do
      {:ok, sha} ->
        %{
          name: name,
          state: :installed,
          # `nil` when there is nothing to compare against — cf. the moduledoc: not knowing is not
          # the same answer as being current.
          updatable?: deposit && deposit.sha != sha,
          deposit: deposit,
          store: full
        }

      {:error, reason} ->
        # An unreadable store is NOT "not installed": the source is right there and the fleet serves
        # it. What we lose is the comparison, so we say installed and unknown rather than invent one.
        require Logger

        Logger.warning(
          "CatalogueLifecycle: #{full} exists but its head could not be read (#{inspect(reason)}) " <>
            "— reported INSTALLED, up-to-dateness unknown."
        )

        %{name: name, state: :installed, updatable?: nil, deposit: deposit, store: full}
    end
  end

  # A store with no deposit is still an installed catalogue — this clause only exists because the
  # one above requires `is_map(store)` and the compiler cannot see they are exhaustive together.
  defp entry(name, _deposit, _store, _repo_mod, _opts),
    do: %{name: name, state: :available, updatable?: nil, deposit: nil, store: nil}

  defp stores(repos) do
    store = CatalogueDeposits.store_repo()

    for %{"name" => ^store, "full_name" => full} = r <- repos,
        into: %{},
        do: {full |> String.split("/", parts: 2) |> hd(), r}
  end
end
