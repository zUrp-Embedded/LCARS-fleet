defmodule Fleet.Application.CatalogueStores do
  @moduledoc """
  Reads which catalogues the forge carries INSTALLED: the branches of the store repository
  (`Fleet.Catalogue.store_repo/0`), one branch per catalogue.

  ONE listing of ONE repository names them all, where a search across every visible repository used
  to; proving each one's identity still costs a manifest read per branch. A branch is only a store
  once the manifest read AT THAT BRANCH declares the branch's
  own name: a branch `x` whose `catalogue.yaml` says something else is not the store of `x`, and
  says so on its own line. The repository's own default branch carries a README, no manifest, and
  is skipped like any branch without one.

  An absent store repository is `{:ok, %{}}`: a forge that carries no installed catalogue is not
  a forge in error. Anything else propagates — a listing that cannot be read is not an empty one.

  ⚠ WHAT ERASES IS NOT THIS MODULE. `forge.d/catalogues.sh` is the converger that removes local
  material, and it reads the forge itself. This module answers `lcars catalogue list`, and its
  prudence buys an honest listing, not a safe convergence.

  **Last revised**: 2026-09-17
  """

  alias Fleet.Catalogue

  require Logger

  @manifest Catalogue.manifest_file()

  @typedoc """
  An installed catalogue: its name, the branch that holds it, that branch's head and the head's
  commit message — the message carries the `Source-Commit:` trailer freshness is read from.
  """
  @type store :: %{
          name: String.t(),
          branch: String.t(),
          sha: String.t(),
          message: String.t(),
          proven?: boolean()
        }

  @doc """
  Lists installed catalogues keyed by name.

  Reads the branches of the store repository, then one manifest per branch — one listing call plus
  one call per branch. The reads are sequential, so they do not constitute a forge snapshot.

  A branch whose manifest is UNREADABLE is kept, named `:unproven`: the source is there, what is
  lost is the proof of its identity. Dropping it would retrograde an installed catalogue to
  "available" on a hiccup, and `lcars catalogue list` would tell an operator to install what is
  already installed.
  """
  @spec list(keyword()) :: {:ok, %{String.t() => store()}} | {:error, term()}
  def list(opts \\ []) do
    repo_mod = Keyword.get(opts, :forge_repo, Fleet.Forge.Client.Repo)
    files_mod = Keyword.get(opts, :forge_files, Fleet.Forge.Client.Files)
    repo = Keyword.get(opts, :store_repo, Catalogue.store_repo())

    case repo_mod.list_branches(repo, opts) do
      {:ok, branches} ->
        {:ok, Map.new(Enum.flat_map(branches, &identify(&1, repo, files_mod, opts)))}

      {:error, :not_found} ->
        Logger.info(
          "CatalogueStores: #{repo} does not exist — no catalogue is installed on this forge. " <>
            "The forge recipe lays this repository; `lcars catalogue install <name>` fills it."
        )

        {:ok, %{}}

      {:error, _} = err ->
        err
    end
  end

  defp identify(%{name: branch, sha: sha} = head, repo, files_mod, opts) do
    case files_mod.get_file(repo, @manifest, Keyword.put(opts, :ref, branch)) do
      {:ok, %{content: yaml}} ->
        named(branch, sha, Map.get(head, :message, ""), yaml, repo)

      # No manifest: the store repository's own default branch carries a README, and that is fine.
      {:error, :not_found} ->
        []

      {:error, reason} ->
        unreadable(branch, sha, Map.get(head, :message, ""), repo, reason)
    end
  end

  defp identify(_entry, _repo, _files_mod, _opts), do: []

  defp named(branch, sha, message, yaml, repo) do
    case Catalogue.manifest_name(yaml) do
      {:ok, ^branch} ->
        [{branch, %{name: branch, branch: branch, sha: sha, message: message, proven?: true}}]

      {:ok, other} ->
        Logger.warning(
          "CatalogueStores: #{repo}:#{branch} declares '#{other}', not '#{branch}' — it is NOT the " <>
            "store of '#{branch}', and nothing is installed under that name. `catalogue install` " <>
            "pushes a catalogue onto the branch its manifest names."
        )

        []

      {:error, :no_name_in_manifest} ->
        Logger.warning(
          "CatalogueStores: #{repo}:#{branch} carries a #{@manifest} with no `name:` at COLUMN " <>
            "ZERO — NOT listed. In YAML an indented `name:` belongs to the key above it, so a " <>
            "`name:` under `roles:` declares a role, not the catalogue."
        )

        []
    end
  end

  # Kept, not dropped: an unreadable manifest loses the PROOF of identity, not the source. The
  # entry carries `:unproven` so a reader can say "installed, identity unverified" instead of
  # silently demoting an installed catalogue to available.
  defp unreadable(branch, sha, message, repo, reason) do
    Logger.warning(
      "CatalogueStores: #{repo}:#{branch} carries a #{@manifest} that could not be read " <>
        "(#{inspect(reason)}) — kept as INSTALLED with its identity UNPROVEN, and its local " <>
        "material is left alone. A dropped entry would read as 'not installed'."
    )

    [{branch, %{name: branch, branch: branch, sha: sha, message: message, proven?: false}}]
  end
end
