defmodule Fleet.Application.CatalogueDepositsTest do
  use ExUnit.Case, async: true

  alias Fleet.Application.CatalogueDeposits

  # Stubs preserve string-keyed forge payloads; they do not exercise transport or visibility.
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

    # Default org:true isolates name classification; owner-type cases override it.
    def org_exists?(owner, opts) do
      case Keyword.get(opts, :orgs, :all) do
        :all -> {:ok, true}
        %{} = m -> {:ok, Map.get(m, owner, false)}
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

  defp list(repos, manifests \\ %{}, shas \\ %{}, orgs \\ :all) do
    CatalogueDeposits.list(
      forge_repo: FakeRepo,
      forge_files: FakeFiles,
      repos: repos,
      manifests: manifests,
      shas: shas,
      orgs: orgs
    )
  end

  test "l'identite d'un depot est le NOM DE SON MANIFESTE, pas celui du depot" do
    assert {:ok, found} =
             list(
               [repo("alice/mon-truc-a-moi")],
               %{"alice/mon-truc-a-moi" => "name: mobile\n"},
               %{{"alice/mon-truc-a-moi", "main"} => "abc123"}
             )

    assert %{"mobile" => %{repo: "alice/mon-truc-a-moi", owner: "alice", sha: "abc123"}} = found
  end

  test "un depot SANS manifeste n'est pas un catalogue — et le temoin qui rend ca falsifiable" do
    # Include a valid deposit so a classifier that always returns empty cannot pass.
    assert {:ok, found} =
             list(
               [repo("bob/un-projet"), repo("bob/un-catalogue")],
               %{"bob/un-catalogue" => "name: web-demo\n"},
               %{{"bob/un-catalogue", "main"} => "sha1"}
             )

    assert Map.keys(found) == ["web-demo"]
  end

  test "le STORE d'un catalogue installe n'est pas un depot" do
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
      # Use bare catalogue, not _catalogue: repo-name exclusion once hid ordinary user deposits.
      assert {:ok, found} =
               list(
                 [repo("bob/catalogue")],
                 %{"bob/catalogue" => "name: mobile\n"},
                 %{{"bob/catalogue", "main"} => "sha9"}
               )

      assert %{"mobile" => %{repo: "bob/catalogue", owner: "bob"}} = found
    end

    test "un depot A L'ADRESSE d'un store, mais qui declare un AUTRE nom, reste un depot" do
      assert {:ok, found} =
               list(
                 [repo("web/_catalogue")],
                 %{"web/_catalogue" => "name: autre-chose\n"},
                 %{{"web/_catalogue", "main"} => "sha7"}
               )

      assert %{"autre-chose" => %{repo: "web/_catalogue"}} = found
    end

    test "`split/2` rend les DEUX moities d'une seule classification" do
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

  describe "la classification est COMPLETE — un candidat recale retombe en depot" do
    test "un utilisateur qui nomme son catalogue d'apres SON LOGIN reste un depot" do
      # Same-name personal owners must fall back to deposit, not vanish after store rejection.
      assert {:ok, found} =
               list(
                 [repo("bob/mon-catalogue")],
                 %{"bob/mon-catalogue" => "name: bob\n"},
                 %{{"bob/mon-catalogue", "main"} => "s1"},
                 %{"bob" => false}
               )

      assert %{"bob" => %{repo: "bob/mon-catalogue", owner: "bob"}} = found
    end

    test "TEMOIN de non-vacuite : sous une ORG, la meme forme EST un magasin" do
      assert {:ok, deposits, stores} =
               CatalogueDeposits.split([repo("web/_catalogue")],
                 forge_repo: FakeRepo,
                 forge_files: FakeFiles,
                 manifests: %{"web/_catalogue" => "name: web\n"},
                 orgs: %{"web" => true}
               )

      assert deposits == %{}
      assert %{"web" => %{"full_name" => "web/_catalogue"}} = stores
    end
  end

  describe "deux depots qui revendiquent le MEME magasin" do
    test "le choix est DETERMINISTE et il est DIT — jamais « le dernier vu »" do
      # Checks the selected store for this input order, not warning emission or order independence.
      assert {:ok, _deposits, stores} =
               CatalogueDeposits.split(
                 [repo("web/_catalogue"), repo("web/vieux-magasin")],
                 forge_repo: FakeRepo,
                 forge_files: FakeFiles,
                 manifests: %{
                   "web/_catalogue" => "name: web\n",
                   "web/vieux-magasin" => "name: web\n"
                 }
               )

      assert %{"web" => %{"full_name" => "web/_catalogue"}} = stores
    end
  end

  describe "le nom du catalogue LIVRE n'est jamais une candidature" do
    test "un depot qui declare `fleet` n'entre pas dans la liste" do
      assert {:ok, found} =
               list(
                 [repo("admiral/fleet"), repo("alice/mob")],
                 %{"admiral/fleet" => "name: fleet\n", "alice/mob" => "name: mobile\n"},
                 %{{"admiral/fleet", "main"} => "s1", {"alice/mob", "main"} => "s2"}
               )

      assert Map.keys(found) == ["mobile"]
    end

    test "⚠ ET SON FORK NON PLUS — sinon le premier fork casse `catalogue list` pour tout le monde" do
      # Bundled-name forks must not trigger a duplicate refusal of the entire listing.
      assert {:ok, found} =
               list(
                 [repo("admiral/fleet"), repo("bob/fleet-fork"), repo("alice/mob")],
                 %{
                   "admiral/fleet" => "name: fleet\n",
                   "bob/fleet-fork" => "name: fleet\n",
                   "alice/mob" => "name: mobile\n"
                 },
                 # Both forks need readable heads so missing-head exclusion cannot hide a broken bundled filter.
                 %{
                   {"admiral/fleet", "main"} => "s1",
                   {"bob/fleet-fork", "main"} => "s3",
                   {"alice/mob", "main"} => "s2"
                 }
               )

      assert Map.keys(found) == ["mobile"]
    end

    test "TEMOIN de non-vacuite : un depot qui declare AUTRE CHOSE entre normalement" do
      assert {:ok, found} =
               list(
                 [repo("admiral/fleet")],
                 %{"admiral/fleet" => "name: fleet-bis\n"},
                 %{{"admiral/fleet", "main"} => "s1"}
               )

      assert %{"fleet-bis" => %{repo: "admiral/fleet"}} = found
    end
  end

  test "un depot VIDE est ecarte — il ne peut rien porter" do
    assert {:ok, %{}} == list([repo("alice/vide", %{"empty" => true})])
  end

  test "DEUX depots du meme nom : refus, et les DEUX sont nommes" do
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

  test "un `name:` INDENTE est un geste d'AUTEUR, et le refus ne parle pas de forge" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, %{}} ==
                 list([repo("alice/role-vole")], %{
                   "alice/role-vole" => "api_version: 1\nroles:\n  name: dev\n"
                 })
      end)

    assert log =~ "COLUMN ZERO"

    # Global log capture can include neighbors; anchor the forbidden phrase to this emitter.
    refute log =~ ~r/CatalogueDeposits: .*could not be read/
  end

  test "une forge ILLISIBLE ne devient PAS une liste vide" do
    assert {:error, {:http, 500, _}} = list({:error, {:http, 500, "boom"}})
  end

  test "le sha vient de la branche PAR DEFAUT du depot, pas de `main` en dur" do
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
    # Cover nested name fields with and without a YAML list marker before the root identity.
    for yaml <- ["roles:\n  - name: dev\nname: web\n", "roles:\n  name: dev\nname: web\n"] do
      assert {:ok, found} = list([repo("a/b")], %{"a/b" => yaml}, %{{"a/b", "main"} => "s"})
      assert Map.keys(found) == ["web"], "identite volee par un name: indente : #{inspect(yaml)}"
    end
  end
end
