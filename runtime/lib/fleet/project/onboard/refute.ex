defmodule Fleet.Project.Onboard.Refute do
  @moduledoc """
  Le refus du DEPOT-MAGASIN : un projet ne peut pas s'appeler comme le magasin de son catalogue.

  Le magasin est un depot comme un autre du point de vue de la forge, et rien dans son nom ne le
  distingue — c'est la declaration du catalogue qui dit lequel il est. Un projet onboarde a cette
  adresse ecraserait le magasin sans qu'aucune erreur ne soit levee : la forge repondrait 200 a
  chaque geste.
  """

  alias Fleet.Project.Onboard.Repo

  @doc """
  Refuses to treat a catalogue's STORE as a project — `:ok` when the repo is not one.

  ## Why the explicit doors need this and `reconcile` does not

  `reconcile/2` is already guarded, and better than by a name: it asks every repo *"do you carry a
  project declaration (`.lcars.json` on `main`)?"* — a guard by PROPERTY, which holds without ever
  knowing the word `catalogue`.

  The doors where an ADMIN TYPES THE NAME have no such shield. An admin imports `web/_catalogue` to
  see what happens, the fleet lays three faces and writes `.lcars.json` at its root — and the store
  becomes a declared project. The property guard then turns around: from the next pass on, it
  DEFENDS the property that was laid by mistake. That is why this is a refusal at the door and not
  a repair afterwards.

  ## The discriminant is the identity, and an unknown is a REFUSAL

  `owner == manifest.name`, read from the repo's own `catalogue.yaml` — the same question
  `Fleet.Application.CatalogueDeposits.split/2` asks, so the two cannot disagree about what a
  store is.

  A `:not_found` is an ANSWER (not a catalogue — the overwhelmingly common case, and silent). Any
  OTHER read failure is an ABSENCE of an answer, and it refuses: importing a store is expensive and
  self-defending, retrying an import is free. ⚖ user: an explicit failure beats an ambiguous
  success. The refusal for that case says what it could not read, never that this IS a store — a
  refusal that named the wrong cause would send the admin to delete a repo that is fine.
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
  Refuses to CREATE a repo at the address the fleet pushes a store to — `:ok` otherwise.

  ## Why this door asks a different question, and why the answer is a name

  `refute_store/2` asks an EXISTING repo what it declares. `adopt_project/2` publishes a disk-only
  project to a repo that does not exist yet, so there is nothing to ask. What it can collide with is
  the ADDRESS: `push_store` force-pushes there, so a project adopted at that name is a project the
  next `catalogue install` silently overwrites.

  `require_forge_absent/2` already covers the case where the store is there — but the dangerous
  window is precisely the one it does not see: the org exists, its catalogue is NOT installed yet,
  nothing occupies the name, and the collision arrives later.

  Checking a name here is not the defect this rule closed. That one answered "what IS this repo"
  with a name; this one answers "may I WRITE here", which is what an address is for. Cf.
  `Fleet.Catalogue.store_repo/0`, which says it and says why in the same breath.
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

  # LA REGLE DU MANIFESTE N'EST PAS RECOPIEE ICI. `Fleet.Catalogue` la porte — colonne zero,
  # guillemets, commentaire de fin de ligne — et une seconde ecriture de la meme regle serait
  # exactement le defaut que ce garde ferme, un cran plus bas : deux lecteurs d'un discriminant est
  # un discriminant qui derive le jour ou un seul est corrige. Elle vit dans la FONDATION parce que
  # l'autre lecteur (`Fleet.Application.CatalogueDeposits`) est derriere une frontiere que
  # `Fleet.Project` ne peut pas referencer — et on n'elargit pas une frontiere pour avoir raison.
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
