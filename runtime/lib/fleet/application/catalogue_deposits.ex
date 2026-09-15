defmodule Fleet.Application.CatalogueDeposits do
  @moduledoc """
  Classifies token-visible forge repositories by catalogue.yaml's declared name.
  Depositing is an author's push; admin installation is a separate operation.
  This reader neither installs nor enforces caller permissions. Invisible repositories
  are outside its listing, whether private or otherwise inaccessible.

  Stores require owner == declared name plus org status; repository names such as
  catalogue or _catalogue are not identities. A personal owner matching the name
  stays a deposit, even though installation can later fail on the shared org/user
  namespace. Org-read errors conservatively count as store, so that classification
  does not prove an installation. Bundled-name deposits are excluded.

  Duplicate deposits refuse the whole list and name all claimants; duplicate stores
  warn and select the first full repository name lexically, preserving an installed entry.
  """

  alias Fleet.Forge.Payload

  require Logger

  @manifest Fleet.Catalogue.manifest_file()

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
  Lists visible deposits keyed by name. Search errors and duplicate deposit names
  propagate. Per-repository manifest/head errors warn and omit that repository;
  absent manifests and malformed listing entries are silently skipped.
  """
  @spec list(keyword()) :: {:ok, %{String.t() => deposit()}} | {:error, term()}
  def list(opts \\ []) do
    repo_mod = Keyword.get(opts, :forge_repo, Fleet.Forge.Client.Repo)

    with {:ok, repos} <- repo_mod.search_repos(opts), do: from_repos(repos, opts)
  end

  @doc """
  Classifies an already fetched repository list and returns only deposits.
  """
  @spec from_repos([map()], keyword()) :: {:ok, %{String.t() => deposit()}} | {:error, term()}
  def from_repos(repos, opts \\ []) when is_list(repos) do
    with {:ok, deposits, _stores} <- split(repos, opts), do: {:ok, deposits}
  end

  @doc """
  Returns {:ok, deposits, stores} from one repository list and one classification.
  Stores contain raw repository maps; deposits include separately read branch heads.
  Sharing the classification avoids divergent filters, but sequential manifest,
  owner and head reads do not constitute a forge snapshot.
  """
  @spec split([map()], keyword()) ::
          {:ok, %{String.t() => deposit()}, %{String.t() => map()}} | {:error, term()}
  def split(repos, opts \\ []) when is_list(repos) do
    repo_mod = Keyword.get(opts, :forge_repo, Fleet.Forge.Client.Repo)
    files_mod = Keyword.get(opts, :forge_files, Fleet.Forge.Client.Files)

    # Gitea's `empty` flag lags the first push by a second or more, so it is not read: a truly
    # empty repo answers 404 on its manifest and is dropped by classify/4 like any repo without one.
    classified = Enum.flat_map(repos, &classify(&1, repo_mod, files_mod, opts))

    stores = pick_stores(for {:store, name, repo} <- classified, do: {name, repo})

    with {:ok, deposits} <- group(for {:deposit, d} <- classified, do: d) do
      {:ok, deposits, stores}
    end
  end

  defp pick_stores(pairs) do
    pairs
    |> Enum.group_by(fn {name, _repo} -> name end, fn {_name, repo} -> repo end)
    |> Map.new(fn
      {name, [one]} ->
        {name, one}

      {name, many} ->
        [chosen | _] = sorted = Enum.sort_by(many, &Payload.full_name/1)

        Logger.warning(
          "CatalogueDeposits: #{length(many)} repos claim to be the store of '#{name}' " <>
            "(#{Enum.map_join(sorted, ", ", &Payload.full_name/1)}). Following " <>
            "#{Payload.full_name(chosen)} — first by name, so every container reading this forge follows the " <>
            "same one. Delete the others: only one of them is what `catalogue install` pushes to."
        )

        {name, chosen}
    end)
  end

  defp classify(repo, repo_mod, files_mod, opts) when is_map(repo) do
    case Payload.full_name(repo) do
      full when is_binary(full) -> do_classify(repo, full, repo_mod, files_mod, opts)
      _ -> []
    end
  end

  defp classify(_repo, _repo_mod, _files_mod, _opts), do: []

  defp do_classify(repo, full, repo_mod, files_mod, opts) do
    branch = Payload.default_branch(repo) || "main"

    with {:ok, %{content: yaml}} <-
           files_mod.get_file(full, @manifest, Keyword.put(opts, :ref, branch)),
         {:ok, name} <- manifest_name(yaml) do
      identify(name, repo, full, branch, repo_mod, opts)
    else
      {:error, :not_found} ->
        []

      # A missing top-level name is a manifest problem, not a transport failure.
      {:error, :no_name_in_manifest} ->
        Logger.warning(
          "CatalogueDeposits: #{full} carries a #{@manifest} with no `name:` at COLUMN ZERO — NOT " <>
            "listed. In YAML an indented `name:` belongs to the key above it, so a `name:` under " <>
            "`roles:` declares a role, not the catalogue. Its owner sees nothing; this line is the " <>
            "only trace."
        )

        []

      {:error, reason} ->
        unreadable(full, reason)
    end
  end

  # Classify stores before head reads; only lifecycle freshness needs their heads.
  defp identify(name, repo, full, branch, repo_mod, opts) do
    cond do
      owner_of(full) == name and org_owner?(name, repo_mod, opts) ->
        [{:store, name, repo}]

      # Bundled-name forks cannot be installed as deposits; excluding them also prevents
      # their duplicate names from refusing everyone else's listing.
      name == Fleet.Catalogue.bundled_name() ->
        Logger.info(
          "CatalogueDeposits: #{full} declares '#{name}', the catalogue carried by the release. It " <>
            "is installed by construction, so no deposit can be installed under that name — this " <>
            "repo is here to be READ and FORKED. A fork meant to be installed changes `name:` in " <>
            "its #{@manifest}."
        )

        []

      true ->
        case repo_mod.branch_head(full, branch, opts) do
          {:ok, sha} ->
            [
              {:deposit,
               %{name: name, repo: full, owner: owner_of(full), branch: branch, sha: sha}}
            ]

          {:error, reason} ->
            unreadable(full, reason)
        end
    end
  end

  # Check owner type here so personal same-name repositories remain deposits.
  # Org lookup failure favors store classification to avoid transient downgrades,
  # at the cost of possibly reporting a personal deposit as installed.
  defp org_owner?(owner, repo_mod, opts) do
    case repo_mod.org_exists?(owner, opts) do
      {:ok, is_org} ->
        is_org

      {:error, reason} ->
        Logger.warning(
          "CatalogueDeposits: cannot read the owner type of #{owner} (#{inspect(reason)}) — " <>
            "counted as a store. An unreadable forge is not an answer, and the other reading would " <>
            "retrograde an installed catalogue on a hiccup."
        )

        true
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

  # Catalogue owns manifest parsing shared with Onboard's store refusal.
  defp manifest_name(yaml), do: Fleet.Catalogue.manifest_name(yaml)

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
