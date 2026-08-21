defmodule Fleet.Application.CatalogueDeposits do
  @moduledoc """
  Which catalogues this forge carries as DEPOSITS — the `available` half of the lifecycle.

  ## The model

  A catalogue arrives the way a project does: its author pushes it from their own disk into their
  own space on the forge (`<user>/<repo>`). That push is an EXTERNAL user action — LCARS is not its
  author and has nothing to offer it. What LCARS does is read the forge and say what it sees.

  Any user may deposit. Only an admin may install. That asymmetry is the whole access model, and it
  needs no flag anywhere: depositing is a git push, installing is a command.

  ## What makes a repo a candidate

  It carries `catalogue.yaml` at its root. The manifest's `name:` is the catalogue's identity — not
  the repo name, not the owner. A user may call their repo anything; the manifest says what it IS.

  ## What makes a repo a STORE, and why it is not a name

  The store is the copy WE pushed into an installed catalogue's own org. Listing it as a deposit
  would report every installed catalogue as also available from itself.

  It used to be recognised by NAME — any repo called `catalogue`, whoever owned it. That reserved
  the most natural repo name in every user's namespace, and did it in SILENCE: a user who called
  their deposit `catalogue` was dropped with no log, no line, no refusal.

  The discriminant is `owner == manifest.name`, and it is true BY CONSTRUCTION: the org is created
  from the manifest (`/orgs/${name}/repos`), and *"the NAME comes from the repo's manifest, never
  from the repo name nor from you"*.

  What makes it not a rarity bet — the part a prefix could never buy — is that Gitea gives users and
  organisations ONE namespace. A catalogue named `X` requires the org `X`, so no user account can be
  called `X`, so a repo in a user's space can never satisfy `owner == name`. A prefix protects by
  rarity, and a rarity bet is lost exactly once. This protects by impossibility.

  Cost: the filter runs AFTER the manifest is read, so a store costs one manifest read per listing.
  That is per installed catalogue, not per repo — and it buys back the whole `catalogue` name.

  ## Two deposits of the same name: we REFUSE, and we name both

  ⚖ user, 2026-08-16. We do not guess which one is the real one — not the first, not the newest,
  not the biggest. Each of those is a choice we could not justify to whoever loses. The list refuses
  and names both owners; the humans sort it out by deleting one.

  A refusal that names one owner would be worse than useless: it would look like an answer.

  ## A private deposit costs no code

  `/repos/search` returns only what the token can SEE, so a private repo is simply not there
  (measured — cf. `Fleet.Forge.Client.Repo.search_repos/1`). ⚖ user: *"if the user left their repo
  private and we don't see it, well, we don't see it. We are not here to write a git tutorial."*
  The absence from the list IS the message; there is nothing to detect and nothing to explain.
  """

  require Logger

  @manifest "catalogue.yaml"

  @typedoc """
  A deposit the forge carries: the catalogue's declared name, where it sits, and the head sha of
  its default branch — the value that later answers "has this moved since it was installed".
  """
  @type deposit :: %{
          name: String.t(),
          repo: String.t(),
          owner: String.t(),
          branch: String.t(),
          sha: String.t()
        }

  @doc """
  Every deposit the forge carries, by declared name.

  Returns `{:ok, %{name => deposit}}`, or `{:error, {:duplicate_catalogues, [{name, [repo]}]}}`
  when two repos declare the same name. A forge read failure propagates: an unreadable forge says
  NOTHING about what exists, and inferring an empty list from it would report every installed
  catalogue as vanished.
  """
  @spec list(keyword()) :: {:ok, %{String.t() => deposit()}} | {:error, term()}
  def list(opts \\ []) do
    repo_mod = Keyword.get(opts, :forge_repo, Fleet.Forge.Client.Repo)

    with {:ok, repos} <- repo_mod.search_repos(opts), do: from_repos(repos, opts)
  end

  @doc """
  Same reading, on a repo list ALREADY fetched — deposits only.
  """
  @spec from_repos([map()], keyword()) :: {:ok, %{String.t() => deposit()}} | {:error, term()}
  def from_repos(repos, opts \\ []) when is_list(repos) do
    with {:ok, deposits, _stores} <- split(repos, opts), do: {:ok, deposits}
  end

  @doc """
  BOTH halves of the lifecycle from ONE list of repos: `{:ok, deposits, stores}`.

  `deposits` is keyed by declared name; `stores` maps a catalogue name to the raw repo map of the
  store that carries it (`owner == name`, unverified as to whether that owner is an org — that
  question belongs to whoever signs an installation, cf. `CatalogueLifecycle`).

  ## Why the two halves are read TOGETHER and not twice

  It costs ONE `/repos/search` and ONE manifest read per repo. Reading twice would not only cost
  round trips: the two reads could straddle a push and produce a state nobody ever had — and worse,
  the two halves would then answer "is this a store?" independently. A discriminant applied by two
  readers is a discriminant that drifts; here there is a single classification and the halves cannot
  disagree, because they are the two outputs of one decision.
  """
  @spec split([map()], keyword()) ::
          {:ok, %{String.t() => deposit()}, %{String.t() => map()}} | {:error, term()}
  def split(repos, opts \\ []) when is_list(repos) do
    repo_mod = Keyword.get(opts, :forge_repo, Fleet.Forge.Client.Repo)
    files_mod = Keyword.get(opts, :forge_files, Fleet.Forge.Client.Files)

    classified =
      repos
      |> Enum.reject(&empty?/1)
      |> Enum.flat_map(&classify(&1, repo_mod, files_mod, opts))

    stores = for {:store, name, repo} <- classified, into: %{}, do: {name, repo}

    with {:ok, deposits} <- group(for {:deposit, d} <- classified, do: d) do
      {:ok, deposits, stores}
    end
  end

  # An empty repo carries no manifest to read, and asking for one costs a round trip to learn what
  # the listing already said.
  defp empty?(%{"empty" => true}), do: true
  defp empty?(_), do: false

  # Returns a one-element list or none — `flat_map` so that a repo we cannot read drops out with a
  # named warning instead of failing the whole listing. A single unreadable repo among fifty must
  # not hide the other forty-nine.
  defp classify(%{"full_name" => full} = repo, repo_mod, files_mod, opts) when is_binary(full) do
    branch = Map.get(repo, "default_branch") || "main"

    with {:ok, %{content: yaml}} <-
           files_mod.get_file(full, @manifest, Keyword.put(opts, :ref, branch)),
         {:ok, name} <- manifest_name(yaml) do
      identify(name, repo, full, branch, repo_mod, opts)
    else
      # Not a catalogue. The overwhelmingly common case, and silent by design: every project repo
      # on the forge takes this branch on every listing.
      {:error, :not_found} -> []
      {:error, reason} -> unreadable(full, reason)
    end
  end

  defp classify(_repo, _repo_mod, _files_mod, _opts), do: []

  # ⚠ LE STORE SE RECONNAIT ICI, ET NULLE PART AILLEURS. C'est le seul point du code ou l'identite
  # declaree et le proprietaire sont tous les deux connus, donc le seul ou la question puisse etre
  # posee. La poser une seconde fois ailleurs — ce que faisait `CatalogueLifecycle.stores/3` sur le
  # NOM du depot — donne deux reponses qui divergent le jour ou une seule est corrigee.
  #
  # Un store ne coute PAS de `branch_head` : l'identite tranche avant. La tete d'un store est lue
  # plus tard, et seulement par l'appelant qui la compare.
  defp identify(name, repo, full, branch, repo_mod, opts) do
    # Exclure un store est le fonctionnement normal, pas une erreur : SILENCIEUX. Une ligne par
    # catalogue installe a chaque listage serait du bruit qui apprend a l'operateur a sauter le log.
    if owner_of(full) == name do
      [{:store, name, repo}]
    else
      case repo_mod.branch_head(full, branch, opts) do
        {:ok, sha} ->
          [{:deposit, %{name: name, repo: full, owner: owner_of(full), branch: branch, sha: sha}}]

        {:error, reason} ->
          unreadable(full, reason)
      end
    end
  end

  defp unreadable(full, reason) do
    Logger.warning(
      "CatalogueDeposits: #{full} carries a #{@manifest} that could not be read " <>
        "(#{inspect(reason)}) — NOT listed. Its owner sees nothing; this line is the only trace."
    )

    []
  end

  defp owner_of(full_name), do: full_name |> String.split("/", parts: 2) |> hd()

  # The manifest is read for ONE field. A full YAML parse would make this listing fail on a
  # catalogue whose unrelated section is malformed — the identity is what we need here, and
  # `catalogue verify` is what judges the rest.
  #
  # ⚠ COLUMN ZERO, and it is the whole correctness of this read. In YAML an INDENTED `name:` belongs
  # to the key above it: `roles:\n  name: dev` declares a role, not the catalogue. Accepting leading
  # whitespace would let the first nested `name:` in the file steal the catalogue's identity — and
  # it would work by accident on OUR manifests, where the root key happens to come first, then be
  # wrong on somebody else's. Both catalogues shipped today carry `name:` at column 0.
  #
  # ⚠ `[_, name | _]` and not `[_, name]`: the trailing comment group makes `Regex.run/2` return
  # THREE elements when a comment is present, and the two-element pattern silently fell through to
  # "no name" — measured by the witness on `name: web   # le metier`.
  defp manifest_name(yaml) when is_binary(yaml) do
    yaml
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case Regex.run(~r/\Aname:\s*"?([^"#\s]+)"?\s*(#.*)?\z/, line) do
        [_, name | _] -> name
        _ -> nil
      end
    end)
    |> case do
      nil -> {:error, :no_name_in_manifest}
      name -> {:ok, name}
    end
  end

  defp group(deposits) do
    by_name = Enum.group_by(deposits, & &1.name)

    case Enum.filter(by_name, fn {_name, list} -> length(list) > 1 end) do
      [] ->
        {:ok, Map.new(by_name, fn {name, [one]} -> {name, one} end)}

      dups ->
        {:error,
         {:duplicate_catalogues,
          Enum.map(dups, fn {name, l} -> {name, Enum.map(l, & &1.repo)} end)}}
    end
  end
end
