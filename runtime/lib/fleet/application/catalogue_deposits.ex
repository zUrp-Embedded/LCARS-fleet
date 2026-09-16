defmodule Fleet.Application.CatalogueDeposits do
  @moduledoc """
  Classifies token-visible forge repositories by catalogue.yaml's declared name: these are the
  DEPOSITS, what an author pushed and what `catalogue install` reads from.

  Installation is a separate operation, and what is INSTALLED is read elsewhere
  (`Fleet.Application.CatalogueStores`: one branch per catalogue in the store repository). This
  module no longer classifies any repository as a store — a deposit is a deposit wherever it
  sits, including in an org bearing its name.

  This reader neither installs nor enforces caller permissions. Invisible repositories are
  outside its listing, whether private or otherwise inaccessible. Bundled-name deposits are
  excluded.

  ⚠ A DUPLICATE NAME REFUSES THAT NAME, NOT THE LIST. Two repositories declaring the same catalogue
  is a question nobody here can answer — but answering "nothing is readable" would be worse: on a
  forge carrying a leftover store from an older installation, one ambiguous name used to make
  `catalogue list` and `catalogue source` refuse everything, for every catalogue. The ambiguous
  name is dropped, loudly, and the rest of the list stands.
  """

  alias Fleet.Forge.Payload

  require Logger

  @manifest Fleet.Catalogue.manifest_file()
  @bundled Fleet.Catalogue.bundled_name()

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
  Classifies an already fetched repository list and returns its deposits.
  """
  # No error clause: an ambiguous name drops itself, an unreadable manifest drops its repository,
  # and a listing that reached this point is always an answer.
  @spec from_repos([map()], keyword()) :: {:ok, %{String.t() => deposit()}}
  def from_repos(repos, opts \\ []) when is_list(repos) do
    repo_mod = Keyword.get(opts, :forge_repo, Fleet.Forge.Client.Repo)
    files_mod = Keyword.get(opts, :forge_files, Fleet.Forge.Client.Files)

    # Gitea's `empty` flag lags the first push by a second or more, so it is not read: a truly
    # empty repo answers 404 on its manifest and is dropped by classify/4 like any repo without one.
    repos
    |> Enum.flat_map(&classify(&1, repo_mod, files_mod, opts))
    |> group()
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
      identify(name, full, branch, repo_mod, opts)
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

  # Bundled-name forks cannot be installed as deposits; excluding them also prevents their duplicate
  # names from refusing everyone else's listing.
  defp identify(name, full, _branch, _repo_mod, _opts) when name == @bundled do
    Logger.info(
      "CatalogueDeposits: #{full} declares '#{name}', the catalogue carried by the release. It " <>
        "is installed by construction, so no deposit can be installed under that name — this " <>
        "repo is here to be READ and FORKED. A fork meant to be installed changes `name:` in " <>
        "its #{@manifest}."
    )

    []
  end

  defp identify(name, full, branch, repo_mod, opts) do
    case repo_mod.branch_head(full, branch, opts) do
      {:ok, sha} -> [%{name: name, repo: full, owner: owner_of(full), branch: branch, sha: sha}]
      {:error, reason} -> unreadable(full, reason)
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
    {seuls, doubles} =
      deposits
      |> Enum.group_by(& &1.name)
      |> Map.split_with(fn {_name, list} -> length(list) == 1 end)

    Enum.each(doubles, fn {name, list} ->
      Logger.warning(
        "CatalogueDeposits: #{length(list)} repos declare the catalogue '#{name}' " <>
          "(#{Enum.map_join(list, ", ", & &1.repo)}) — the name is AMBIGUOUS and is dropped from " <>
          "the listing. Nothing here can choose between them: delete or rename all but one, then " <>
          "`lcars catalogue list` sees it again. The other catalogues are unaffected."
      )
    end)

    {:ok, Map.new(seuls, fn {name, [one]} -> {name, one} end)}
  end
end
