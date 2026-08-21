defmodule Fleet.Application.CatalogueDepositsTest do
  use ExUnit.Case, async: true

  alias Fleet.Application.CatalogueDeposits

  # Les doublures portent le contrat EXACT des modules reels : `search_repos/1` rend des maps a cles
  # STRING (le JSON de la forge, non atomise), `get_file/3` rend `%{content:, sha:}` ou
  # `{:error, :not_found}`, `branch_head/3` rend un sha. Une doublure qui atomiserait les cles ferait
  # passer ces temoins sur une forme que la forge ne produit jamais.
  defmodule FakeRepo do
    def search_repos(opts) do
      case Keyword.fetch!(opts, :repos) do
        {:error, _} = err -> err
        repos -> {:ok, repos}
      end
    end

    def branch_head(full, branch, opts) do
      case Keyword.get(opts, :shas, %{}) |> Map.fetch({full, branch}) do
        {:ok, sha} -> {:ok, sha}
        :error -> {:error, :not_found}
      end
    end
  end

  defmodule FakeFiles do
    def get_file(full, "catalogue.yaml", opts) do
      case Keyword.get(opts, :manifests, %{}) |> Map.fetch(full) do
        {:ok, :unreadable} -> {:error, {:http, 500, "boom"}}
        {:ok, yaml} -> {:ok, %{content: yaml, sha: "f00"}}
        :error -> {:error, :not_found}
      end
    end
  end

  defp repo(full, extra \\ %{}) do
    [owner, name] = String.split(full, "/", parts: 2)

    Map.merge(
      %{
        "full_name" => full,
        "name" => name,
        "owner" => %{"login" => owner},
        "default_branch" => "main",
        "empty" => false,
        "private" => false
      },
      extra
    )
  end

  defp list(repos, manifests \\ %{}, shas \\ %{}) do
    CatalogueDeposits.list(
      forge_repo: FakeRepo,
      forge_files: FakeFiles,
      repos: repos,
      manifests: manifests,
      shas: shas
    )
  end

  test "l'identite d'un depot est le NOM DE SON MANIFESTE, pas celui du depot" do
    # Un humain appelle son depot comme il veut. Prendre le nom du depot ferait installer une org
    # au mauvais nom, et le lien projet->catalogue (fixe pour la vie d'un projet) serait faux.
    assert {:ok, found} =
             list(
               [repo("alice/mon-truc-a-moi")],
               %{"alice/mon-truc-a-moi" => "name: mobile\n"},
               %{{"alice/mon-truc-a-moi", "main"} => "abc123"}
             )

    assert %{"mobile" => %{repo: "alice/mon-truc-a-moi", owner: "alice", sha: "abc123"}} = found
  end

  test "un depot SANS manifeste n'est pas un catalogue — et le temoin qui rend ca falsifiable" do
    # Sans le second depot, ce test passerait sur une implementation qui ne trouve JAMAIS rien.
    assert {:ok, found} =
             list(
               [repo("bob/un-projet"), repo("bob/un-catalogue")],
               %{"bob/un-catalogue" => "name: web-demo\n"},
               %{{"bob/un-catalogue", "main"} => "sha1"}
             )

    assert Map.keys(found) == ["web-demo"]
  end

  test "le STORE d'un catalogue installe n'est pas un depot" do
    # `<org>/_catalogue` est la copie que NOUS y avons poussee. La lister ferait apparaitre chaque
    # catalogue installe comme egalement disponible depuis lui-meme, donc toujours « a jour ».
    assert {:ok, found} =
             list(
               [repo("web/_catalogue"), repo("web/autre-chose")],
               %{"web/_catalogue" => "name: web\n", "web/autre-chose" => "name: web-bis\n"},
               %{{"web/autre-chose", "main"} => "sha2"}
             )

    assert Map.keys(found) == ["web-bis"]
  end

  describe "le store se reconnait a `owner == manifest.name`, jamais au nom du depot" do
    test "un depot d'utilisateur NOMME `catalogue` est un depot comme un autre" do
      # ⚠ CE QUE LE LOT 2 ACHETE. L'exclusion portait sur le NOM : tout depot appele `catalogue`
      # etait ecarte, quel que soit son proprietaire, et EN SILENCE — pas de log, pas de ligne, pas
      # de refus. `bob` qui appelle son depot du nom le plus naturel voyait son catalogue ne jamais
      # apparaitre, sans un mot nulle part. La fleet reservait un nom dans l'espace des utilisateurs
      # sans le leur dire.
      #
      # ⚠ LE DEPOT S'APPELLE `catalogue` TOUT COURT, SANS LE `_`. C'est le nom qu'un humain choisit,
      # et donc le seul qui mesure quelque chose : ecrit `_catalogue`, ce temoin epinglerait l'adresse
      # de la fleet et laisserait le nom nu a nouveau prenable par une regression.
      assert {:ok, found} =
               list(
                 [repo("bob/catalogue")],
                 %{"bob/catalogue" => "name: mobile\n"},
                 %{{"bob/catalogue", "main"} => "sha9"}
               )

      assert %{"mobile" => %{repo: "bob/catalogue", owner: "bob"}} = found
    end

    test "un depot A L'ADRESSE d'un store, mais qui declare un AUTRE nom, reste un depot" do
      # Le complement du precedent, et le plus dur a passer par accident : `web/_catalogue` est
      # exactement la ou un store se pose, sous une org de catalogue. Ce qui le sauve est son
      # identite — il ne declare pas `web`, donc il n'est pas le magasin de `web`.
      assert {:ok, found} =
               list(
                 [repo("web/_catalogue")],
                 %{"web/_catalogue" => "name: autre-chose\n"},
                 %{{"web/_catalogue", "main"} => "sha7"}
               )

      assert %{"autre-chose" => %{repo: "web/_catalogue"}} = found
    end

    test "`split/2` rend les DEUX moities d'une seule classification" do
      # Les deux moities ne peuvent pas se contredire parce qu'elles sortent de la MEME decision.
      # Deux lecteurs de « est-ce un store ? » divergent le jour ou un seul est corrige — c'etait
      # l'etat d'avant, `store_or_empty?` d'un cote et `stores/3` de l'autre.
      repos = [repo("web/_catalogue"), repo("alice/mob"), repo("bob/catalogue")]

      manifests = %{
        "web/_catalogue" => "name: web\n",
        "alice/mob" => "name: mobile\n",
        "bob/catalogue" => "name: notes\n"
      }

      assert {:ok, deposits, stores} =
               CatalogueDeposits.split(repos,
                 forge_repo: FakeRepo,
                 forge_files: FakeFiles,
                 manifests: manifests,
                 shas: %{{"alice/mob", "main"} => "s1", {"bob/catalogue", "main"} => "s2"}
               )

      assert Enum.sort(Map.keys(deposits)) == ["mobile", "notes"]
      assert %{"web" => %{"full_name" => "web/_catalogue"}} = stores
      assert Map.keys(stores) == ["web"]
    end
  end

  test "un depot VIDE est ecarte — il ne peut rien porter" do
    assert {:ok, %{}} == list([repo("alice/vide", %{"empty" => true})])
  end

  test "DEUX depots du meme nom : refus, et les DEUX sont nommes" do
    # ⚖ user 2026-08-16 : on ne devine pas lequel est le vrai. Un refus qui n'en nommerait qu'un
    # ressemblerait a une reponse, et celui qui perd n'aurait aucun moyen de le savoir.
    assert {:error, {:duplicate_catalogues, dups}} =
             list(
               [repo("alice/web"), repo("bob/web")],
               %{"alice/web" => "name: web\n", "bob/web" => "name: web\n"},
               %{{"alice/web", "main"} => "s1", {"bob/web", "main"} => "s2"}
             )

    assert [{"web", repos}] = dups
    assert Enum.sort(repos) == ["alice/web", "bob/web"]
  end

  test "un manifeste ILLISIBLE fait tomber SON depot, pas la liste" do
    assert {:ok, found} =
             list(
               [repo("alice/casse"), repo("bob/sain")],
               %{"alice/casse" => :unreadable, "bob/sain" => "name: sain\n"},
               %{{"bob/sain", "main"} => "sha3"}
             )

    assert Map.keys(found) == ["sain"]
  end

  test "un manifeste SANS `name:` tombe — on n'invente pas une identite" do
    assert {:ok, %{}} ==
             list([repo("alice/anonyme")], %{"alice/anonyme" => "api_version: 1\n"})
  end

  test "une forge ILLISIBLE ne devient PAS une liste vide" do
    # Le mensonge que ce temoin interdit : conclure « aucun catalogue disponible » d'une panne
    # reseau. L'appelant doit voir l'erreur, pas un ensemble vide qui a l'air d'une reponse.
    assert {:error, {:http, 500, _}} = list({:error, {:http, 500, "boom"}})
  end

  test "le sha vient de la branche PAR DEFAUT du depot, pas de `main` en dur" do
    # Un depot dont la branche par defaut est `trunk` doit etre suivi sur `trunk` : comparer le sha
    # d'une branche qui n'existe pas ferait apparaitre une mise a jour qui n'existe pas non plus.
    assert {:ok, found} =
             list(
               [repo("alice/cat", %{"default_branch" => "trunk"})],
               %{"alice/cat" => "name: cat\n"},
               %{{"alice/cat", "trunk"} => "sha-trunk"}
             )

    assert %{"cat" => %{branch: "trunk", sha: "sha-trunk"}} = found
  end

  test "le `name:` se lit guillemete, et suivi d'un commentaire" do
    for {yaml, attendu} <- [
          {"name: web\n", "web"},
          {"name: \"web\"\n", "web"},
          {"name: web   # le metier\n", "web"},
          {"api_version: 1\nname: web\nautre: x\n", "web"}
        ] do
      assert {:ok, found} =
               list([repo("a/b")], %{"a/b" => yaml}, %{{"a/b", "main"} => "s"})

      assert Map.keys(found) == [attendu], "manifeste refuse : #{inspect(yaml)}"
    end
  end

  test "un `name:` INDENTE appartient a sa cle, il ne vole pas l'identite du catalogue" do
    # En YAML `roles:\n  name: dev` declare un role. Accepter l'indentation ferait prendre le
    # PREMIER `name:` du fichier quelle que soit sa profondeur — une lecture qui marche par accident
    # sur nos manifestes, ou la cle racine vient en tete, et se trompe sur celui de quelqu'un
    # d'autre. Les deux formes indentees sont ici, avec et sans tiret.
    for yaml <- ["roles:\n  - name: dev\nname: web\n", "roles:\n  name: dev\nname: web\n"] do
      assert {:ok, found} = list([repo("a/b")], %{"a/b" => yaml}, %{{"a/b", "main"} => "s"})
      assert Map.keys(found) == ["web"], "identite volee par un name: indente : #{inspect(yaml)}"
    end
  end
end
