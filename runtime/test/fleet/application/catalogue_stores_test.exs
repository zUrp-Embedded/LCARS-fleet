defmodule Fleet.Application.CatalogueStoresTest do
  @moduledoc """
  Temoins de la lecture des catalogues INSTALLES : les branches du magasin
  (`Fleet.Catalogue.store_repo/0`), une par catalogue.

  Ce que ces temoins tiennent (⚖ user 2026-09-16) :

    1. une branche n'est le magasin de `x` que si le manifeste LU A CETTE BRANCHE declare `x` — le
       nom de la branche ne fait pas l'identite, et une branche qui ment est dite, pas suivie ;
    2. la branche par defaut du magasin porte un README, pas un manifeste : elle ne figure nulle
       part, et ce silence est voulu ;
    3. un magasin ABSENT est une reponse (aucun catalogue installe), une forge ILLISIBLE n'en est
       pas une ; un manifeste illisible garde son catalogue INSTALLE, identite non prouvee ;
    4. le message de la tete voyage avec la branche : la fraicheur se lit sans second appel.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Fleet.Application.CatalogueStores

  defmodule FakeRepo do
    @moduledoc false
    def list_branches(repo, opts) do
      case Keyword.get(opts, :branches) do
        {:error, _} = err -> err
        branches when is_list(branches) -> {:ok, branches}
        map when is_map(map) -> Map.get(map, repo, {:error, :not_found})
      end
    end
  end

  defmodule FakeFiles do
    @moduledoc false
    # La clef porte le CHEMIN : une doublure qui l'ignore laisserait passer un module qui lit le
    # mauvais fichier (`README.md` au lieu du manifeste) sans que rien ne rougisse.
    def get_file(repo, path, opts) do
      key = {repo, Keyword.fetch!(opts, :ref), path}

      case opts |> Keyword.get(:manifests, %{}) |> Map.fetch(key) do
        {:ok, {:error, _} = err} -> err
        {:ok, yaml} -> {:ok, %{content: yaml, sha: "blob"}}
        :error -> {:error, :not_found}
      end
    end
  end

  defp branche(name, sha \\ "sha", message \\ ""),
    do: %{name: name, sha: sha, message: message}

  # Les manifestes sont donnes par branche ; la clef complete (depot, ref, chemin) est batie ici.
  defp list(branches, manifests) do
    manifests =
      Map.new(manifests, fn {{repo, ref}, v} -> {{repo, ref, "catalogue.yaml"}, v} end)

    CatalogueStores.list(
      forge_repo: FakeRepo,
      forge_files: FakeFiles,
      store_repo: "lcars/_catalogues",
      branches: branches,
      manifests: manifests
    )
  end

  describe "une branche par catalogue, son identite prouvee par son manifeste" do
    test "une branche dont le manifeste declare son propre nom EST le magasin de ce catalogue" do
      assert {:ok, stores} =
               list(
                 [branche("web-demo", "sha-w", "projection\n\nSource-Commit: abc1234\n")],
                 %{{"lcars/_catalogues", "web-demo"} => "api_version: 1\nname: web-demo\n"}
               )

      assert %{
               "web-demo" => %{
                 name: "web-demo",
                 branch: "web-demo",
                 sha: "sha-w",
                 message: message
               }
             } = stores

      assert message =~ "Source-Commit: abc1234"
    end

    test "une branche dont le manifeste declare AUTRE CHOSE n'est le magasin de personne, et c'est dit" do
      log =
        capture_log(fn ->
          assert {:ok, stores} =
                   list(
                     [branche("web-demo")],
                     %{{"lcars/_catalogues", "web-demo"} => "name: autre-chose\n"}
                   )

          assert stores == %{}
        end)

      assert log =~ "lcars/_catalogues:web-demo declares 'autre-chose'"
      assert log =~ "NOT the store"
    end

    test "un manifeste sans `name:` en colonne zero ne signe rien, et la raison est dite" do
      log =
        capture_log(fn ->
          assert {:ok, stores} =
                   list(
                     [branche("web-demo")],
                     %{{"lcars/_catalogues", "web-demo"} => "roles:\n  name: web-demo\n"}
                   )

          assert stores == %{}
        end)

      assert log =~ "COLUMN ZERO"
    end

    test "la branche par defaut du magasin porte un README, pas un manifeste : elle ne figure nulle part" do
      assert {:ok, stores} =
               list(
                 [branche("main"), branche("web-demo")],
                 %{{"lcars/_catalogues", "web-demo"} => "name: web-demo\n"}
               )

      assert Map.keys(stores) == ["web-demo"]
    end

    test "plusieurs catalogues : une seule LISTE les nomme tous, un magasin par branche" do
      assert {:ok, stores} =
               list(
                 [branche("main"), branche("web-demo", "s1"), branche("mobile", "s2")],
                 %{
                   {"lcars/_catalogues", "web-demo"} => "name: web-demo\n",
                   {"lcars/_catalogues", "mobile"} => "name: mobile\n"
                 }
               )

      assert Map.keys(stores) |> Enum.sort() == ["mobile", "web-demo"]
      assert %{"mobile" => %{sha: "s2"}, "web-demo" => %{sha: "s1"}} = stores
    end
  end

  describe "ce que le magasin repond quand il ne repond pas" do
    test "magasin ABSENT : aucun catalogue installe — une REPONSE, pas une panne" do
      log =
        capture_log(fn ->
          assert {:ok, %{}} =
                   CatalogueStores.list(
                     forge_repo: FakeRepo,
                     forge_files: FakeFiles,
                     store_repo: "lcars/_catalogues",
                     branches: {:error, :not_found},
                     manifests: %{}
                   )
        end)

      assert log =~ "does not exist"
      assert log =~ "recipe lays this repository"
    end

    test "listing ILLISIBLE : le refus remonte — jamais une liste vide qu'un lecteur croirait" do
      assert {:error, {:http, 500, _}} =
               CatalogueStores.list(
                 forge_repo: FakeRepo,
                 forge_files: FakeFiles,
                 store_repo: "lcars/_catalogues",
                 branches: {:error, {:http, 500, "boom"}},
                 manifests: %{}
               )
    end

    # ⚠ UN MANIFESTE ILLISIBLE NE DESINSTALLE PAS : la source est la, ce qu'on perd est la PREUVE de
    # son identite. La retirer ferait dire « disponible » a un catalogue installe, donc conseillerait
    # d'installer ce qui l'est deja (relecture hostile du 2026-09-17).
    test "manifeste ILLISIBLE sur UNE branche : elle reste INSTALLEE, identite NON PROUVEE" do
      log =
        capture_log(fn ->
          assert {:ok, stores} =
                   list(
                     [branche("web-demo"), branche("mobile", "s2")],
                     %{
                       {"lcars/_catalogues", "web-demo"} => {:error, {:http, 500, "boom"}},
                       {"lcars/_catalogues", "mobile"} => "name: mobile\n"
                     }
                   )

          assert Map.keys(stores) |> Enum.sort() == ["mobile", "web-demo"]
          assert %{"web-demo" => %{proven?: false}, "mobile" => %{proven?: true}} = stores
        end)

      assert log =~ "could not be read"
      assert log =~ "UNPROVEN"
      assert log =~ "left alone"
    end

    test "un magasin non prouve est INSTALLE, et sa fraicheur est INCONNUE — jamais `false`" do
      assert {:ok, stores} =
               list(
                 [branche("web-demo", "s", "projection\n\nSource-Commit: abc1234\n")],
                 %{{"lcars/_catalogues", "web-demo"} => {:error, {:http, 500, "boom"}}}
               )

      entree =
        Fleet.Application.CatalogueLifecycle.lines(%{
          "web-demo" => %{
            name: "web-demo",
            state: :installed,
            updatable?: nil,
            deposit: nil,
            store: "lcars/_catalogues:web-demo"
          }
        })

      assert %{"web-demo" => %{proven?: false}} = stores
      assert "INSTALLED web-demo -" in entree
    end
  end

  describe "l'adresse du magasin suit l'org systeme" do
    test "le defaut est celui de la config, et il porte le nom du depot de magasin" do
      assert Fleet.Catalogue.store_repo() == "#{Fleet.Catalogue.system_org()}/_catalogues"
      assert Fleet.Catalogue.store_name() == "_catalogues"
      assert Fleet.Catalogue.store_branch("web-demo") == "web-demo"
    end

    test "une org systeme renommee emmene son magasin" do
      prev = Application.get_env(:lcars_fleet, :catalogue_system_org)
      Application.put_env(:lcars_fleet, :catalogue_system_org, "flotte")

      on_exit(fn ->
        if prev,
          do: Application.put_env(:lcars_fleet, :catalogue_system_org, prev),
          else: Application.delete_env(:lcars_fleet, :catalogue_system_org)
      end)

      assert Fleet.Catalogue.store_repo() == "flotte/_catalogues"
    end
  end
end
