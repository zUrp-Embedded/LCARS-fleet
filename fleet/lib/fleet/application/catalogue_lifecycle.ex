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

  A repo that DECLARES the name of the org it sits in — the source WE pushed into the catalogue's own
  org. Not "the org exists": an org without its source is an interrupted install, and no box can
  serve a catalogue whose material is nowhere. Signing on the org alone would report such a catalogue
  as ready and let a boot discover the hole. The store is the narrower signature and it is the one
  that matters.

  It sits at `<org>/_catalogue`, and that is an ADDRESS, not the signature. What signs is
  `owner == manifest.name` (`CatalogueDeposits.split/2`) TOGETHER WITH the owner being an ORG —
  complementary conditions, neither covering the other. Signing on the repo NAME, as this did until
  2026-08-21, reserved the most natural repo name in every user's namespace, and did it in silence.

  ## The reference catalogue is installed by construction

  `fleet` ships inside the release. The box can serve it without asking anybody, so its state
  is not a forge question — and answering "available" for it, on a forge that carries no
  `fleet/_catalogue`, would be a lie about the only catalogue that always works.

  ## An installed catalogue whose deposit vanished

  It stays INSTALLED. Its source is in its org and the fleet serves it; what is lost is the ability
  to say whether it is up to date, because the thing to compare against is gone — deleted, renamed,
  or turned private. `updatable?` is `nil` there, and `nil` is not `false`: one means "we cannot
  know", the other means "it is current", and collapsing them would announce a stale catalogue as
  fresh.
  """

  alias Fleet.Application.CatalogueDeposits

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
  Every catalogue the forge knows, by name, with its state.

  ONE `/repos/search` feeds both halves: reading twice could straddle a push and describe a state
  nobody ever had. A duplicate deposit propagates its refusal — a listing that silently dropped one
  of two claimants would be exactly the guess we refuse to make.
  """
  @spec states(keyword()) :: {:ok, %{String.t() => entry()}} | {:error, term()}
  def states(opts \\ []) do
    repo_mod = Keyword.get(opts, :forge_repo, Fleet.Forge.Client.Repo)

    with {:ok, repos} <- repo_mod.search_repos(opts),
         {:ok, deposits, candidates} <- CatalogueDeposits.split(repos, opts) do
      # `candidates` EST la liste des magasins : `split/2` tranche l'identite ET le type du
      # proprietaire, donc il n'y a plus de second jugement a rendre ici. Il y en avait un
      # (`stores/3`), et le candidat qu'il recalait tombait dans un trou — cf. `split/2`.
      stores = candidates

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
  `eval` door for `lcars catalogue list` — one `<STATE> <name> <deposit>` line per catalogue.

  The CLI has NO forge access by design, and every one of these states is a forge fact. It asks the
  release through the same door `catalogue verify` already uses. The door speaks WORDS, not a
  formatted table: a column added later must not have to agree across two languages.

  ## The third field is the DEPOSIT, and it is deliberately empty for an installed catalogue

  ⚖ user, 2026-08-16: *"can `catalogue list` show which user an available catalogue comes from?
  Once installed, its origin does not matter — at install time it is useful."*

  It is the `<owner>/<repo>` of the deposit, so the owner is its first segment — the forge's own
  convention, not a second rendering of the same fact. That is exactly the question an admin has
  before installing: WHOSE material am I about to serve to everyone.

  Once installed it is dropped, and not only because nobody reads it. What the box follows from
  then on is `<name>/_catalogue`, the store — printing the deposit there names something that is no
  longer the source, in the column an operator reads AS the source.

  `UPDATABLE` keeps it, and that is the same rule rather than an exception: the deposit is once
  again what the next `install` would pull from.
  """
  @spec eval_main() :: no_return()
  def eval_main do
    # ⚠ `cat_states` (bin/lcars) PARSE cette sortie mot par mot, et son `case` ne connait que
    # INSTALLED / UPDATABLE / AVAILABLE : une ligne de log sur stdout n'y produit AUCUNE ligne de
    # tableau — un catalogue qui disparait de la liste sans un mot. Ce chemin loggue (deux
    # `Logger.warning` sous `states/1`). Le pourquoi et la mesure vivent dans `Fleet.ReleaseDoor`.
    Fleet.ReleaseDoor.claim_stdout!()

    case with_transport(fn -> states([]) end) do
      {:ok, entries} ->
        Enum.each(lines(entries), &IO.puts/1)
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

  # ON NE COMPARE PAS DEUX SHA DE COMMIT DE PART ET D'AUTRE D'UNE PROJECTION, ET C'EST CE QUE FAISAIT
  # LA PREMIERE VERSION. Le store est un commit FRAIS qui reflete l'arbre du depot : deux commits de
  # contenu identique ne partagent jamais de sha, donc la comparaison repondait « commit different »,
  # ce qui est toujours vrai. Mesure sur banc du 2026-08-16 : `web-demo`, installe trente secondes
  # plus tot, sortait UPDATABLE — et le seul geste offert etait de le reinstaller pour rien.
  #
  # La projection porte donc SA SOURCE (`Source-Commit:`, ecrit par `push_store`), et c'est elle
  # qu'on compare. Pas de trailer = `nil`, « on ne peut pas savoir » : un store pousse par une
  # version anterieure du geste ne doit pas etre annonce a jour, ni updatable, sur une comparaison
  # qu'on n'a pas pu faire.
  @source_rx ~r/^Source-Commit:\s*([0-9a-f]{7,40})\s*$/m

  defp updatable?(nil, _head), do: nil

  defp updatable?(deposit, %{message: message}) do
    case Regex.run(@source_rx, message || "") do
      [_, source] -> not String.starts_with?(deposit.sha, source)
      _ -> nil
    end
  end

  @doc """
  `eval` door for `catalogue install` — resolves ONE name to the deposit that carries it.

  Prints `<repo> <branch> <sha>` on stdout, and nothing else: the caller feeds it to `git clone`,
  so a line of politeness would become part of a URL.

  The three refusals it owes the caller, each with its own exit code, because they call for three
  different gestures:

    * `2` — nobody deposited that name. Push it to your own space on the forge first.
    * `3` — TWO deposits claim it. ⚖ user: we do not guess. Both owners are named; they settle it.
    * `4` — it is already the STORE of an installed catalogue, not a deposit. Nothing to install
      from itself.

  `#{"fleet"}` is refused too, and not because it is precious: it ships INSIDE the release, so
  there is no deposit to install from and no version to move to. Installing it would be a gesture
  with no object.
  """
  @spec eval_source(String.t()) :: no_return()
  def eval_source(@bundled) do
    IO.puts(
      :stderr,
      "BUNDLED #{@bundled} — carried by the release, there is nothing to install from"
    )

    System.halt(4)
  end

  # ⚠ DEUX CLAUSES, PAS UN `cond` AVEC UN HELPER PRIVE. Dialyzer refusait le second : toutes ses
  # branches appellent `System.halt`, donc il n'a pas de retour local, et un `@spec no_return()` sur
  # un prive aurait ete une annotation pour taire un outil. La forme a deux clauses dit la meme
  # chose sans rien annoter.
  def eval_source(name) when is_binary(name) do
    case with_transport(fn -> Fleet.Application.CatalogueDeposits.list([]) end) do
      {:ok, deposits} ->
        case Map.fetch(deposits, name) do
          {:ok, d} ->
            IO.puts("#{d.repo} #{d.branch} #{d.sha}")
            System.halt(0)

          :error ->
            IO.puts(:stderr, "ABSENT #{name} — no visible deposit declares this catalogue")
            System.halt(2)
        end

      {:error, {:duplicate_catalogues, dups}} ->
        Enum.each(dups, fn {n, repos} ->
          IO.puts(:stderr, "DUPLICATE #{n} #{Enum.join(Enum.sort(repos), " ")}")
        end)

        System.halt(3)

      {:error, reason} ->
        IO.puts(:stderr, "UNREACHABLE #{inspect(reason)}")
        System.halt(1)
    end
  end

  # LE TRANSPORT N'EST PAS DEMARRE SOUS `LCARS_TOOL_EVAL=1`, ET AUCUN TEMOIN NE POUVAIT LE VOIR.
  # Une porte `eval` saute tout le corps de config de deploiement — c'est le but du drapeau — donc
  # l'app n'est pas demarree et le pool Finch de `Fleet.Forge` n'existe pas. Les deux portes d'ici
  # appellent la forge : mesure du 2026-08-16 sur banc, `lcars catalogue list` rendait
  # `** (ArgumentError) unknown registry: Fleet.Forge.Finch` sous la ligne « la forge n'a pas
  # repondu », c'est-a-dire un diagnostic de reseau pour une panne de demarrage.
  #
  # Les temoins ne pouvaient pas l'attraper parce qu'ils injectent des doublures de `forge_repo` et
  # `forge_files` : le chemin qui a besoin du pool n'etait pris par personne.
  # `Fleet.Project.Onboard.eval_migrate/2` porte deja ce demarrage et dit pourquoi — c'est la meme
  # raison, a la meme frontiere.
  #
  # `Application.ensure_all_started(:req)` puis le superviseur local : le pool est DECLARE par
  # `Fleet.Forge.finch_spec/0`, sa propre autorite, jamais recompose ici.
  defp with_transport(fun) do
    with {:ok, _} <- Application.ensure_all_started(:req),
         {:ok, _} <- Supervisor.start_link([Fleet.Forge.finch_spec()], strategy: :one_for_one) do
      fun.()
    else
      {:error, reason} -> {:error, {:transport, reason}}
    end
  end

  @doc """
  The `eval_main/0` output, as a list of lines — the same rendering, without the exit.

  It exists to be witnessed. `eval_main/0` ends in `System.halt/1`, so nothing can assert on what it
  printed from inside the VM that runs the assertion; a private formatter would then be covered only
  by a bench run, which is where the deposit-of-an-installed-catalogue defect lived until an
  operator read the column.
  """
  @spec lines(%{String.t() => entry()}) :: [String.t()]
  def lines(entries), do: Enum.map(entries, fn {name, e} -> line(name, e) end)

  defp line(name, %{state: :installed, updatable?: true, deposit: d}),
    do: "UPDATABLE #{name} #{d.repo}"

  defp line(name, %{state: :installed}), do: "INSTALLED #{name} -"

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

    case repo_mod.branch_commit(full, branch, opts) do
      {:ok, head} ->
        %{
          name: name,
          state: :installed,
          # `nil` when there is nothing to compare against — cf. the moduledoc: not knowing is not
          # the same answer as being current.
          updatable?: updatable?(deposit, head),
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
end
