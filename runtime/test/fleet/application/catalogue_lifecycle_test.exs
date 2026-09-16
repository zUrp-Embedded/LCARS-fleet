defmodule Fleet.Application.CatalogueLifecycleTest do
  use ExUnit.Case, async: true

  alias Fleet.Application.CatalogueLifecycle

  # ⚠ DEUX MOITIES, DEUX LECTURES (⚖ user 2026-09-16) : les DEPOTS viennent d'une recherche de
  # depots (ce qu'un auteur a pousse), les INSTALLES des BRANCHES du magasin des catalogues. Ce
  # decor les tient separes, comme la forge.
  @store "lcars/_catalogues"

  defmodule FakeRepo do
    def search_repos(opts) do
      case Keyword.fetch!(opts, :repos) do
        {:error, _} = err -> err
        repos -> {:ok, repos}
      end
    end

    def branch_head(full, branch, opts) do
      case Keyword.get(opts, :shas, %{}) |> Map.fetch({full, branch}) do
        {:ok, :unreadable} -> {:error, {:http, 500, "boom"}}
        {:ok, sha} -> {:ok, sha}
        :error -> {:error, :not_found}
      end
    end

    # Le magasin : une branche par catalogue, sa tete et le message qui porte le trailer.
    def list_branches(_repo, opts) do
      case Keyword.get(opts, :stores, %{}) do
        {:error, _} = err ->
          err

        stores ->
          {:ok,
           for {nom, {sha, src}} <- stores do
             msg = if src, do: "projection\n\nSource-Commit: #{src}", else: "projection"
             %{name: nom, sha: sha, message: msg}
           end}
      end
    end
  end

  defmodule FakeFiles do
    # Le manifeste d'un depot se lit sur sa branche par defaut ; celui d'un magasin, sur SA branche.
    def get_file(full, "catalogue.yaml", opts) do
      ref = Keyword.get(opts, :ref)

      # ⚠ LE MANIFESTE N'EST PAS FABRIQUE DEPUIS LA BRANCHE : il est DONNE, comme sur la forge. Une
      # doublure qui le derive du nom demande rend l'identite vraie par construction, et un vrai
      # defaut d'identite n'y serait jamais vu.
      cherche =
        if full == "lcars/_catalogues",
          do: Keyword.get(opts, :store_manifests, %{}) |> Map.fetch(ref),
          else: Keyword.get(opts, :manifests, %{}) |> Map.fetch(full)

      case cherche do
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

  # `stores` : %{"<catalogue>" => {<sha de la branche>, <source projetee ou nil>}}. Le manifeste de
  # chaque branche est pose a part, pour qu'une branche puisse MENTIR sur son identite.
  defp states(repos, manifests \\ %{}, shas \\ %{}, stores \\ %{}, store_manifests \\ nil) do
    store_manifests =
      store_manifests || Map.new(stores, fn {nom, _} -> {nom, "name: #{nom}\n"} end)

    CatalogueLifecycle.states(
      forge_repo: FakeRepo,
      forge_files: FakeFiles,
      store_repo: @store,
      repos: repos,
      manifests: manifests,
      shas: shas,
      stores: stores,
      store_manifests: store_manifests
    )
  end

  test "une branche du magasin qui MENT sur son identite n'installe rien" do
    assert {:ok, s} =
             states([], %{}, %{}, %{"web" => {"s", nil}}, %{"web" => "name: autre-chose\n"})

    refute match?(%{state: :installed}, s["web"])
  end

  test "un depot SANS store est AVAILABLE — deposer n'installe pas" do
    assert {:ok, s} =
             states([repo("alice/web")], %{"alice/web" => "name: web\n"}, %{
               {"alice/web", "main"} => "d1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4"
             })

    assert %{state: :available, updatable?: nil, store: nil} = s["web"]
  end

  test "la branche du magasin PROJETTE le depot courant : installe, et PAS updatable" do
    # Distinct projection/source commits can carry identical trees; compare the recorded source.
    assert {:ok, s} =
             states(
               [repo("alice/web")],
               %{"alice/web" => "name: web\n"},
               %{{"alice/web", "main"} => "d1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4"},
               %{"web" => {"aaaabbbb", "d1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4"}}
             )

    assert %{state: :installed, updatable?: false, store: "lcars/_catalogues:web"} = s["web"]
  end

  test "le depot a BOUGE depuis la projection : installe ET updatable" do
    assert {:ok, s} =
             states(
               [repo("alice/web")],
               %{"alice/web" => "name: web\n"},
               %{{"alice/web", "main"} => "e2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5"},
               %{"web" => {"aaaabbbb", "d1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4"}}
             )

    assert %{state: :installed, updatable?: true} = s["web"]
  end

  test "un store SANS trailer de source : installe, fraicheur INCONNUE — jamais `false`" do
    assert {:ok, s} =
             states(
               [repo("alice/web")],
               %{"alice/web" => "name: web\n"},
               %{{"alice/web", "main"} => "d1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4"},
               %{"web" => {"aaaabbbb", nil}}
             )

    assert %{state: :installed, updatable?: nil} = s["web"]
    refute s["web"].updatable? == false
  end

  test "une branche de magasin SANS depot : installe, et la fraicheur est INCONNUE — jamais `false`" do
    assert {:ok, s} = states([], %{}, %{}, %{"web" => {"s", nil}})

    assert %{state: :installed, updatable?: nil, deposit: nil} = s["web"]
    refute s["web"].updatable? == false
  end

  test "le magasin ILLISIBLE remonte — jamais « plus rien n'est installe »" do
    assert {:error, {:http, 500, _}} =
             states([], %{}, %{}, {:error, {:http, 500, "boom"}}, %{})
  end

  test "magasin ABSENT : rien n'est installe, et la liste reste lisible" do
    assert {:ok, s} =
             states([repo("bob/mob")], %{"bob/mob" => "name: mobile\n"}, %{
               {"bob/mob", "main"} => "s"
             })

    assert %{state: :available} = s["mobile"]
  end

  test "`fleet` est INSTALLE par construction, meme sur une forge qui n'en sait rien" do
    assert {:ok, s} = states([])
    assert %{state: :installed, store: nil} = s["fleet"]
  end

  test "un depot d'utilisateur NOMME `catalogue` sort AVAILABLE, avec son adresse" do
    # Checks states plus line rendering, not the CLI process or actual stdout.
    assert {:ok, s} =
             states([repo("bob/catalogue")], %{"bob/catalogue" => "name: mobile\n"}, %{
               {"bob/catalogue", "main"} => "s"
             })

    assert %{state: :available, deposit: %{repo: "bob/catalogue"}} = s["mobile"]
    assert "AVAILABLE mobile bob/catalogue" in CatalogueLifecycle.lines(s)
  end

  test "un DOUBLON retire SON nom de la liste, sans emporter les autres" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, s} =
                 states(
                   [repo("alice/web"), repo("bob/web"), repo("carol/mob")],
                   %{
                     "alice/web" => "name: web\n",
                     "bob/web" => "name: web\n",
                     "carol/mob" => "name: mobile\n"
                   },
                   %{
                     {"alice/web", "main"} => "a",
                     {"bob/web", "main"} => "b",
                     {"carol/mob", "main"} => "c"
                   }
                 )

        refute Map.has_key?(s, "web")
        assert %{state: :available} = s["mobile"]
        assert %{state: :installed} = s["fleet"]
      end)

    assert log =~ "AMBIGUOUS"
  end

  test "une forge ILLISIBLE remonte, elle ne devient pas « rien d'installe »" do
    assert {:error, {:http, 500, _}} = states({:error, {:http, 500, "boom"}})
  end

  describe "lines/1 — ce que `lcars catalogue list` imprime" do
    test "AVAILABLE porte le DEPOT, donc son proprietaire en premier segment" do
      # Available lines identify whose material installation would consume.
      assert {:ok, s} =
               states([repo("bob/mob")], %{"bob/mob" => "name: mobile\n"}, %{
                 {"bob/mob", "main"} => "d1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4"
               })

      assert "AVAILABLE mobile bob/mob" in CatalogueLifecycle.lines(s)
    end

    test "INSTALLED ne porte PAS le depot — ce n'est plus la source que le conteneur suit" do
      # Installed lines hide the old deposit; the installed source is the store.
      assert {:ok, s} =
               states(
                 [repo("alice/web")],
                 %{"alice/web" => "name: web\n"},
                 %{{"alice/web", "main"} => "d1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4"},
                 %{"web" => {"aaaabbbb", "d1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4"}}
               )

      assert "INSTALLED web -" in CatalogueLifecycle.lines(s)
    end

    test "UPDATABLE le REPREND — c'est de la que la mise a jour viendrait" do
      assert {:ok, s} =
               states(
                 [repo("alice/web")],
                 %{"alice/web" => "name: web\n"},
                 %{{"alice/web", "main"} => "e2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5"},
                 %{"web" => {"aaaabbbb", "d1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4"}}
               )

      assert "UPDATABLE web alice/web" in CatalogueLifecycle.lines(s)
    end
  end

  describe "les portes eval — ce que les doublures ne pouvaient pas voir" do
    test "les fonctions que les DOUBLURES remplacent existent sur le vrai module" do
      # Dynamic calls can survive a removed real function when stubs retain its old name.
      # Check exports as well; this does not validate transport or response semantics.
      for {m, f, a} <- [
            {Fleet.Forge.Client.Repo, :search_repos, 1},
            {Fleet.Forge.Client.Repo, :branch_head, 3},
            {Fleet.Forge.Client.Repo, :list_branches, 2},
            {Fleet.Forge.Client.Repo, :branch_head, 3},
            {Fleet.Forge.Client.Files, :get_file, 3}
          ] do
        Code.ensure_loaded!(m)

        assert function_exported?(m, f, a),
               "#{inspect(m)}.#{f}/#{a} n'existe plus — les doublures d'ici le cachent"
      end
    end

    test "les deux portes demarrent le transport avant d'appeler la forge" do
      # Fresh tool eval needs req/Finch startup. Stubs bypass that need, so this test
      # checks source structure, not a release process actually starting transport.
      src = File.read!("lib/fleet/application/catalogue_lifecycle.ex")

      assert src =~ "defp with_transport",
             "le demarrage du transport a disparu — les portes eval rendront une ArgumentError"

      # Emptying with_transport to fun.() kept its name; check startup call text in its body.
      corps_transport =
        src
        |> String.split("defp with_transport", parts: 2)
        |> List.last()
        |> String.split(~r/\n  defp? /, parts: 2)
        |> hd()

      assert corps_transport =~ "ensure_all_started(:req)",
             "with_transport ne demarre plus `:req` — le nom reste, le transport non"

      assert corps_transport =~ "finch_spec",
             "with_transport ne pose plus le pool Finch — `unknown registry` revient"

      # Bound the search by the next function, not an arbitrary character count affected by prose.
      for porte <- ["def eval_main do", "def eval_source(name) when is_binary(name) do"] do
        [_, apres] = String.split(src, porte, parts: 2)
        corps = apres |> String.split(~r/\n  defp? /, parts: 2) |> hd()

        assert corps =~ "with_transport",
               "#{porte} appelle la forge sans demarrer le transport"
      end
    end
  end
end
