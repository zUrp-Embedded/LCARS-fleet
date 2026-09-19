defmodule Fleet.Application.CatalogueMaterialTest do
  @moduledoc """
  La mesure que lit le CONVERGEUR, branche par branche, sur des doublures injectees.

  ⚖ Phase 7. Ces cas viennent de `test/services/forge.d/catalogues.bats`, ou un `curl` double
  repondait a trois points d'entree pour que le shell decide. La decision vit ici desormais ; ce
  qui reste au shell est la convergence, et ce sont ces cas-la qui la gardent.

  CE QUE CE MODULE DOIT A SON APPELANT, c'est la difference entre « le magasin n'installe rien » et
  « le magasin n'a pas pu etre lu » : il EFFACE sur le premier et ne doit pas sur le second, et
  quatre faits differents font repondre 404 au meme depot. Chaque cas ci-dessous est ecrit contre
  ca — ce qui signe, ce qui retient, et ce qui n'est jamais confondu avec une forge vide.

  Les doublures sont SANS ETAT : leurs fixtures voyagent dans les `opts`, que le module transmet au
  client. Une doublure qui porterait un etat global obligerait ce fichier a etre serial.
  """
  use ExUnit.Case, async: true

  alias Fleet.Application.CatalogueMaterial

  @depot "lcars/_catalogues"
  @url "http://forge.test/lcars/_catalogues.git"

  defmodule FakeRepo do
    @moduledoc false
    def list_branches(_repo, opts), do: Keyword.get(opts, :listing, {:ok, []})

    def org_exists?(org, opts) do
      cond do
        org in Keyword.get(opts, :org_muette, []) -> {:error, :timeout}
        org in Keyword.get(opts, :orgs, []) -> {:ok, true}
        true -> {:ok, false}
      end
    end
  end

  defmodule FakeFiles do
    @moduledoc false
    # La clef porte le CHEMIN : une doublure qui l'ignore laisserait passer un module qui lit le
    # mauvais fichier (`README.md` au lieu du manifeste) sans que rien ne rougisse.
    def get_file(_repo, path, opts) do
      key = {Keyword.fetch!(opts, :ref), path}

      case opts |> Keyword.get(:manifestes, %{}) |> Map.fetch(key) do
        {:ok, {:error, _} = err} -> err
        {:ok, yaml} -> {:ok, %{content: yaml, sha: "blob"}}
        :error -> {:error, :not_found}
      end
    end
  end

  defp branche(nom), do: %{name: nom, sha: "deadbeef", message: ""}

  # `mesure` avec la forge doublee. `branches` est la liste des noms ; `manifestes` est donnee par
  # branche, et la clef complete (ref, chemin) est batie ici.
  defp mesure(opts) do
    listing =
      case Keyword.fetch(opts, :listing) do
        {:ok, err} -> err
        :error -> {:ok, Enum.map(Keyword.get(opts, :branches, []), &branche/1)}
      end

    manifestes =
      opts
      |> Keyword.get(:manifestes, %{})
      |> Map.new(fn {ref, v} -> {{ref, "catalogue.yaml"}, v} end)

    CatalogueMaterial.mesure(
      forge_repo: FakeRepo,
      forge_files: FakeFiles,
      store_repo: @depot,
      base_url: Keyword.get(opts, :base_url, "http://forge.test"),
      bundled: Keyword.get(opts, :bundled, "fleet"),
      listing: listing,
      manifestes: manifestes,
      orgs: Keyword.get(opts, :orgs, []),
      org_muette: Keyword.get(opts, :org_muette, [])
    )
  end

  describe "ce qui SIGNE une branche" do
    test "manifeste a son nom et org presente : la branche est signee, avec l'adresse de clone" do
      assert {:ok, [%{gravite: :ok, nom: "web", arg: @url}]} =
               mesure(
                 branches: ["main", "web"],
                 manifestes: %{"web" => "api_version: 1\nname: web\n"},
                 orgs: ["web"]
               )
    end

    test "la branche par defaut du magasin porte un README, pas un manifeste — elle ne signe RIEN" do
      assert {:ok, []} = mesure(branches: ["main"])
    end

    test "⚠ UN MANIFESTE QUI DECLARE UN AUTRE NOM ne signe pas, et la phrase le DIT" do
      assert {:ok, [%{gravite: :warn, nom: "web", arg: phrase}]} =
               mesure(
                 branches: ["web"],
                 manifestes: %{"web" => "name: autre-chose\n"},
                 orgs: ["web"]
               )

      assert phrase =~ "autre-chose"
      assert phrase =~ "n'est pas le magasin de web"
    end

    test "⚠ COLONNE ZERO : un `name:` INDENTE appartient a la clef du dessus, il ne signe pas" do
      assert {:ok, [%{gravite: :warn, nom: "web", arg: phrase}]} =
               mesure(
                 branches: ["web"],
                 manifestes: %{"web" => "api_version: 1\nroles:\n  name: web\n"},
                 orgs: ["web"]
               )

      assert phrase =~ "COLONNE ZÉRO"
    end

    test "SANS ORG, la branche ne signe pas : une source sans ses comptes de rôle est un install interrompu" do
      assert {:ok, []} =
               mesure(branches: ["web"], manifestes: %{"web" => "name: web\n"}, orgs: [])
    end

    test "le catalogue EMBARQUE n'est jamais suivi — son materiel EST la release" do
      assert {:ok, [%{nom: "web"}]} =
               mesure(
                 branches: ["fleet", "web"],
                 manifestes: %{"fleet" => "name: fleet\n", "web" => "name: web\n"},
                 orgs: ["fleet", "web"],
                 bundled: "fleet"
               )
    end
  end

  describe "ce qui RETIENT — la lecture n'a pas conclu" do
    test "manifeste ILLISIBLE : HOLD sur la moitié « manifeste », jamais sur l'autre" do
      assert {:ok, [%{gravite: :hold, nom: "web", arg: "manifeste"}]} =
               mesure(branches: ["web"], manifestes: %{"web" => {:error, {:http, 500, "boom"}}})
    end

    test "org ILLISIBLE : HOLD sur la moitié « proprietaire » — l'autre a conclu" do
      assert {:ok, [%{gravite: :hold, nom: "web", arg: "proprietaire"}]} =
               mesure(
                 branches: ["web"],
                 manifestes: %{"web" => "name: web\n"},
                 org_muette: ["web"]
               )
    end
  end

  describe "⚠ CE QUI NE DOIT JAMAIS PASSER POUR UNE FORGE VIDE" do
    test "MAGASIN ABSENT : sa propre reponse, jamais une liste vide" do
      assert {:absent, @depot} = mesure(listing: {:error, :not_found})
    end

    test "LISTING ILLISIBLE : une erreur, jamais une liste vide" do
      assert {:error, {:http, 500, "boom"}} = mesure(listing: {:error, {:http, 500, "boom"}})
    end

    test "LISTING TRONQUE : le client refuse une liste partielle, et le refus remonte tel quel" do
      # La pagination du client rend `:pagination_budget_exceeded` plutot qu'une liste courte :
      # une liste partielle lue comme entiere ferait effacer le materiel au-dela de la borne.
      assert {:error, :pagination_budget_exceeded} =
               mesure(listing: {:error, :pagination_budget_exceeded})
    end

    test "UN MAGASIN QUI N'INSTALLE RIEN est une MESURE : une liste vide, et c'est different" do
      assert {:ok, []} = mesure(branches: ["main"])
    end
  end

  describe "l'adresse de clone" do
    test "c'est celle du MAGASIN : une branche par catalogue, un seul dépôt à cloner" do
      assert {:ok, [%{arg: "http://ailleurs.test/#{@depot}.git"}]} =
               mesure(
                 branches: ["web"],
                 manifestes: %{"web" => "name: web\n"},
                 orgs: ["web"],
                 base_url: "http://ailleurs.test/"
               )
    end
  end
end
