defmodule Fleet.Project.Onboard.Refute do
  @moduledoc """
  Guards against treating a catalogue store as a project, and against names the system keeps.

  Existing repositories are classified by manifest identity: a repository whose `catalogue.yaml`
  declares its own owner is a catalogue's source, not a project. New destinations are judged by
  name: `_`-prefixed names and the system org's name belong to the system.
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
          "'#{full_name}' declares itself the catalogue '#{owner}' — it is a catalogue's SOURCE, " <>
            "not a project. Laying project faces on it would write a project declaration into a " <>
            "catalogue's source, and every later pass would then read it as a project. The fleet " <>
            "keeps what it installed in `#{Fleet.Catalogue.store_repo()}`, one branch per " <>
            "catalogue; to (re)install this one, inside the container: " <>
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
  Refuses a name the system keeps for itself: the system org's name (read from the system
  repository address — a project there would live in the org that carries no project), and any
  `_`-prefixed name (what the fleet posts under its own hand: the catalogue store, the system
  repository). The charset gate already refuses `_`; it is named here so the refusal says WHY,
  not just "invalid". Every onboarding door passes through `Onboard.admit/3`, which asks this.
  """
  @spec refute_system_name(String.t(), String.t()) ::
          :ok | {:error, {:system_name, String.t(), String.t()}}
  def refute_system_name(full_name, name) do
    system_org = Fleet.Toolchain.ops_repo() |> String.split("/", parts: 2) |> hd()

    cond do
      String.starts_with?(name, "_") ->
        {:error,
         {:system_name, full_name,
          "'#{name}' begins with `_`: a name the system keeps for what it posts itself — the " <>
            "catalogue store `#{Fleet.Catalogue.store_repo()}`, the system repository `_ops`. A " <>
            "project there is a project the next install overwrites without a word. Rename it and " <>
            "try again."}}

      name == system_org ->
        {:error,
         {:system_name, full_name,
          "'#{name}' is the SYSTEM org's name (it carries the fleet's identity and its own " <>
            "repositories, never a project). A project cannot carry it. Rename it and try again."}}

      true ->
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
