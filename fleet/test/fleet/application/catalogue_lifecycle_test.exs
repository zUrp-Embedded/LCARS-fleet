defmodule Fleet.Application.CatalogueLifecycleTest do
  use ExUnit.Case, async: true

  alias Fleet.Application.CatalogueLifecycle

  defmodule FakeRepo do
    def search_repos(opts) do
      case Keyword.fetch!(opts, :repos) do
        {:error, _} = err -> err
        repos -> {:ok, repos}
      end
    end

    def branch_sha(full, branch, opts) do
      case Keyword.get(opts, :shas, %{}) |> Map.fetch({full, branch}) do
        {:ok, :unreadable} -> {:error, {:http, 500, "boom"}}
        {:ok, sha} -> {:ok, sha}
        :error -> {:error, :not_found}
      end
    end
  end

  defmodule FakeFiles do
    def get_file(full, "catalogue.yaml", opts) do
      case Keyword.get(opts, :manifests, %{}) |> Map.fetch(full) do
        {:ok, yaml} -> {:ok, %{content: yaml, sha: "f00"}}
        :error -> {:error, :not_found}
      end
    end
  end

  defp repo(full) do
    [owner, name] = String.split(full, "/", parts: 2)

    %{
      "full_name" => full,
      "name" => name,
      "owner" => %{"login" => owner},
      "default_branch" => "main",
      "empty" => false,
      "private" => false
    }
  end

  defp states(repos, manifests \\ %{}, shas \\ %{}) do
    CatalogueLifecycle.states(
      forge_repo: FakeRepo,
      forge_files: FakeFiles,
      repos: repos,
      manifests: manifests,
      shas: shas
    )
  end

  test "un depot SANS store est AVAILABLE — deposer n'installe pas" do
    assert {:ok, s} =
             states([repo("alice/web")], %{"alice/web" => "name: web\n"}, %{
               {"alice/web", "main"} => "d1"
             })

    assert %{state: :available, updatable?: nil, store: nil} = s["web"]
  end

  test "store + depot au MEME sha : installe, et PAS updatable" do
    assert {:ok, s} =
             states(
               [repo("alice/web"), repo("web/catalogue")],
               %{"alice/web" => "name: web\n"},
               %{{"alice/web", "main"} => "meme", {"web/catalogue", "main"} => "meme"}
             )

    assert %{state: :installed, updatable?: false} = s["web"]
  end

  test "store + depot au sha DIFFERENT : installe ET updatable" do
    assert {:ok, s} =
             states(
               [repo("alice/web"), repo("web/catalogue")],
               %{"alice/web" => "name: web\n"},
               %{{"alice/web", "main"} => "neuf", {"web/catalogue", "main"} => "vieux"}
             )

    assert %{state: :installed, updatable?: true} = s["web"]
  end

  test "store SANS depot : installe, et la fraicheur est INCONNUE — jamais `false`" do
    # `nil` et `false` sont deux reponses differentes : « on ne peut pas savoir » et « c'est a
    # jour ». Les confondre annoncerait comme frais un catalogue dont la source a disparu.
    assert {:ok, s} = states([repo("web/catalogue")], %{}, %{{"web/catalogue", "main"} => "s"})

    assert %{state: :installed, updatable?: nil, deposit: nil} = s["web"]
    refute s["web"].updatable? == false
  end

  test "un store ILLISIBLE reste INSTALLE — la source est la, c'est la comparaison qu'on perd" do
    assert {:ok, s} =
             states([repo("web/catalogue")], %{}, %{{"web/catalogue", "main"} => :unreadable})

    assert %{state: :installed, updatable?: nil, store: "web/catalogue"} = s["web"]
  end

  test "`fleet` est INSTALLE par construction, meme sur une forge qui n'en sait rien" do
    # Il vit dans le release. Repondre « available » pour lui serait mentir sur le SEUL catalogue
    # qui marche toujours, y compris quand la forge ne porte rien.
    assert {:ok, s} = states([])
    assert %{state: :installed, store: nil} = s["fleet"]
  end

  test "un DOUBLON fait remonter le refus — la liste ne choisit pas a notre place" do
    assert {:error, {:duplicate_catalogues, _}} =
             states(
               [repo("alice/web"), repo("bob/web")],
               %{"alice/web" => "name: web\n", "bob/web" => "name: web\n"},
               %{{"alice/web", "main"} => "a", {"bob/web", "main"} => "b"}
             )
  end

  test "une forge ILLISIBLE remonte, elle ne devient pas « rien d'installe »" do
    assert {:error, {:http, 500, _}} = states({:error, {:http, 500, "boom"}})
  end

  test "le store d'un catalogue n'est jamais compte comme un depot de lui-meme" do
    # Sinon un catalogue installe serait AUSSI disponible depuis son propre store, donc toujours
    # « a jour » par construction — une comparaison d'un objet avec lui-meme.
    assert {:ok, s} =
             states([repo("web/catalogue")], %{"web/catalogue" => "name: web\n"}, %{
               {"web/catalogue", "main"} => "s"
             })

    assert %{state: :installed, deposit: nil} = s["web"]
  end

  describe "lines/1 — ce que `lcars catalogue list` imprime" do
    test "AVAILABLE porte le DEPOT, donc son proprietaire en premier segment" do
      # ⚖ user, 2026-08-16 : « il peut afficher de quel user vient les catalogues available ? ».
      # C'est LA question d'un admin avant d'installer : le materiel de QUI est-ce que je m'apprete
      # a servir a tout le monde. L'owner est le premier segment du `full_name` — la convention de
      # la forge elle-meme, pas un second rendu du meme fait.
      assert {:ok, s} =
               states([repo("bob/mob")], %{"bob/mob" => "name: mobile\n"}, %{
                 {"bob/mob", "main"} => "d1"
               })

      assert "AVAILABLE mobile bob/mob" in CatalogueLifecycle.lines(s)
    end

    test "INSTALLED ne porte PAS le depot — ce n'est plus la source que la boite suit" do
      # ⚖ user : « une fois installe, osef de l'origine ». Et ce n'est pas qu'une question de bruit :
      # ce que la boite suit desormais est `<nom>/catalogue`, le store. Imprimer le depot la nomme
      # quelque chose qui n'est plus la source, dans la colonne qu'un operateur lit COMME la source.
      assert {:ok, s} =
               states(
                 [repo("alice/web"), repo("web/catalogue")],
                 %{"alice/web" => "name: web\n"},
                 %{{"alice/web", "main"} => "meme", {"web/catalogue", "main"} => "meme"}
               )

      assert "INSTALLED web -" in CatalogueLifecycle.lines(s)
    end

    test "UPDATABLE le REPREND — c'est de la que la mise a jour viendrait" do
      # Meme regle, pas une exception : le depot redevient ce que le prochain `install` tirerait.
      assert {:ok, s} =
               states(
                 [repo("alice/web"), repo("web/catalogue")],
                 %{"alice/web" => "name: web\n"},
                 %{{"alice/web", "main"} => "neuf", {"web/catalogue", "main"} => "vieux"}
               )

      assert "UPDATABLE web alice/web" in CatalogueLifecycle.lines(s)
    end
  end
end
