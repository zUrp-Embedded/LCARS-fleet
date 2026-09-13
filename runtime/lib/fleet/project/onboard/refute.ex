defmodule Fleet.Project.Onboard.Refute do
  @moduledoc """
  Guards against treating a catalogue store as a project.
  Existing repositories are classified by manifest identity; new destinations by the
  reserved store address, where a later catalogue installation can force-push.
  """

  alias Fleet.Project.Onboard.Repo

  @doc """
  Reads catalogue.yaml at HEAD and refuses when its declared name equals the repo owner.
  Shares Catalogue.manifest_name with CatalogueDeposits to avoid divergent parsers.

  Missing files or manifests without a parsed name are admitted; other read errors return
  store_check_unreadable, distinct from a positively identified store. This checks identity,
  not full manifest validity. Explicit import/migration need this guard even though general
  reconciliation filters by the presence of a project declaration on main.
  """
  @spec refute_store(String.t(), keyword()) ::
          :ok
          | {:error, {:repo_is_catalogue_store | :store_check_unreadable, String.t(), String.t()}}
  def refute_store(full_name, opts \\ []) when is_binary(full_name) do
    owner = full_name |> String.split("/", parts: 2) |> hd()

    case declared_catalogue_name(full_name, opts) do
      {:ok, ^owner} ->
        {:error,
         {:repo_is_catalogue_store, full_name,
          "'#{full_name}' is the STORE of the catalogue '#{owner}' — the source the fleet pushed " <>
            "into its own org, not a project. Laying project faces on it would write a project " <>
            "declaration into a catalogue's source, and every later pass would then read it as a " <>
            "project. To (re)install that catalogue, inside the container: " <>
            "`lcars catalogue install #{owner}`."}}

      {:ok, _other} ->
        :ok

      :not_a_catalogue ->
        :ok

      {:error, reason} ->
        {:error,
         {:store_check_unreadable, full_name,
          "could not read '#{full_name}''s #{Fleet.Catalogue.manifest_file()} " <>
            "(#{inspect(reason)}), so it is unknown whether this repo is a catalogue's store. NOT " <>
            "refused as one — refused as UNREADABLE. Retry; if it persists, the forge is the thing " <>
            "to look at."}}
    end
  end

  @doc """
  Refuses the reserved store destination before creation.

  An absent repository has no manifest to inspect. Its address must still be reserved:
  a later catalogue install can force-push there, so checking current forge absence is insufficient.
  """
  @spec refute_store_address(String.t(), String.t()) ::
          :ok | {:error, {:store_address, String.t(), String.t()}}
  def refute_store_address(full_name, name) do
    store = Fleet.Catalogue.store_repo()

    if name == store do
      {:error,
       {:store_address, full_name,
        "'#{name}' is the repo name the fleet pushes a catalogue's source under, so " <>
          "'#{full_name}' is where `catalogue install` force-pushes. A project adopted there is a " <>
          "project the next install overwrites without a word. Rename the local project and adopt " <>
          "it again."}}
    else
      :ok
    end
  end

  # Keep parsing in Catalogue: Project cannot depend on the other consumer, Application.
  defp declared_catalogue_name(full_name, opts) do
    fc = Keyword.put(Repo.fc_opts(opts), :ref, "HEAD")

    case Repo.files_mod(opts).get_file(full_name, Fleet.Catalogue.manifest_file(), fc) do
      {:ok, %{content: yaml}} ->
        case Fleet.Catalogue.manifest_name(yaml) do
          {:ok, name} -> {:ok, name}
          {:error, :no_name_in_manifest} -> :not_a_catalogue
        end

      {:error, :not_found} ->
        :not_a_catalogue

      {:error, _} = err ->
        err
    end
  end
end
