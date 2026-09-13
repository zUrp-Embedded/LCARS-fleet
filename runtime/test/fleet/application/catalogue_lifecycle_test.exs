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

    def branch_head(full, branch, opts) do
      with {:ok, %{sha: sha}} <- branch_commit(full, branch, opts), do: {:ok, sha}
    end

    # Default org:true; personal/unreachable cases override it.
    def org_exists?(owner, opts) do
      case Keyword.get(opts, :orgs, :all) do
        :all ->
          {:ok, true}

        %{} = m ->
          case Map.get(m, owner, false) do
            :unreachable -> {:error, {:transport, :econnrefused}}
            b -> {:ok, b}
          end
      end
    end

    # Source-Commit in the stub message drives freshness, not the store's own SHA.
    def branch_commit(full, branch, opts) do
      case Keyword.get(opts, :shas, %{}) |> Map.fetch({full, branch}) do
        {:ok, :unreadable} ->
          {:error, {:http, 500, "boom"}}

        {:ok, sha} ->
          src = Keyword.get(opts, :sources, %{}) |> Map.get(full)
          msg = if src, do: "projection\n\nSource-Commit: #{src}", else: "projection"
          {:ok, %{sha: sha, message: msg}}

        :error ->
          {:error, :not_found}
      end
    end
  end

  # Stores need the matching manifest; otherwise missing-manifest exclusion masks owner checks.
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

  defp states(repos, manifests \\ %{}, shas \\ %{}, sources \\ %{}, orgs \\ :all) do
    CatalogueLifecycle.states(
      forge_repo: FakeRepo,
      forge_files: FakeFiles,
      repos: repos,
      manifests: manifests,
      shas: shas,
      sources: sources,
      orgs: orgs
    )
  end

  test "un depot SANS store est AVAILABLE — deposer n'installe pas" do
    assert {:ok, s} =
             states([repo("alice/web")], %{"alice/web" => "name: web\n"}, %{
               {"alice/web", "main"} => "d1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4"
             })

    assert %{state: :available, updatable?: nil, store: nil} = s["web"]
  end

  test "le store PROJETTE le depot courant : installe, et PAS updatable" do
    # Distinct projection/source commits can carry identical trees; compare the recorded source.
    assert {:ok, s} =
             states(
               [repo("alice/web"), repo("web/_catalogue")],
               %{"alice/web" => "name: web\n", "web/_catalogue" => "name: web\n"},
               %{
                 {"alice/web", "main"} => "d1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4",
                 {"web/_catalogue", "main"} => "aaaabbbbccccddddeeeeffff0000111122223333"
               },
               %{"web/_catalogue" => "d1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4"}
             )

    assert %{state: :installed, updatable?: false} = s["web"]
  end

  test "le depot a BOUGE depuis la projection : installe ET updatable" do
    assert {:ok, s} =
             states(
               [repo("alice/web"), repo("web/_catalogue")],
               %{"alice/web" => "name: web\n", "web/_catalogue" => "name: web\n"},
               %{
                 {"alice/web", "main"} => "e2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5",
                 {"web/_catalogue", "main"} => "aaaabbbbccccddddeeeeffff0000111122223333"
               },
               %{"web/_catalogue" => "d1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4"}
             )

    assert %{state: :installed, updatable?: true} = s["web"]
  end

  test "un store SANS trailer de source : installe, fraicheur INCONNUE — jamais `false`" do
    assert {:ok, s} =
             states(
               [repo("alice/web"), repo("web/_catalogue")],
               %{"alice/web" => "name: web\n", "web/_catalogue" => "name: web\n"},
               %{
                 {"alice/web", "main"} => "d1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4",
                 {"web/_catalogue", "main"} => "aaaabbbbccccddddeeeeffff0000111122223333"
               }
             )

    assert %{state: :installed, updatable?: nil} = s["web"]
    refute s["web"].updatable? == false
  end

  test "store SANS depot : installe, et la fraicheur est INCONNUE — jamais `false`" do
    assert {:ok, s} =
             states([repo("web/_catalogue")], %{"web/_catalogue" => "name: web\n"}, %{
               {"web/_catalogue", "main"} => "s"
             })

    assert %{state: :installed, updatable?: nil, deposit: nil} = s["web"]
    refute s["web"].updatable? == false
  end

  test "un store ILLISIBLE reste INSTALLE — la source est la, c'est la comparaison qu'on perd" do
    assert {:ok, s} =
             states([repo("web/_catalogue")], %{"web/_catalogue" => "name: web\n"}, %{
               {"web/_catalogue", "main"} => :unreadable
             })

    assert %{state: :installed, updatable?: nil, store: "web/_catalogue"} = s["web"]
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
    assert {:ok, s} =
             states([repo("web/_catalogue")], %{"web/_catalogue" => "name: web\n"}, %{
               {"web/_catalogue", "main"} => "s"
             })

    assert %{state: :installed, deposit: nil} = s["web"]
  end

  describe "D1 — signer une installation demande une ORG, pas seulement une identite" do
    test "un depot qui se declare a son propre nom, dans un espace PERSO, ne signe RIEN" do
      # Match owner and manifest name so only the personal-owner check rejects store status.
      assert {:ok, s} =
               states(
                 [repo("alice/_catalogue")],
                 %{"alice/_catalogue" => "name: alice\n"},
                 %{{"alice/_catalogue", "main"} => "s"},
                 %{},
                 %{"alice" => false}
               )

      # Preserve the personal repository as available instead of dropping it after classification.
      assert %{state: :available, store: nil, deposit: %{repo: "alice/_catalogue"}} = s["alice"]
      refute s["alice"].state == :installed
    end

    test "TEMOIN de non-vacuite : le meme depot sous une ORG signe, comme avant" do
      assert {:ok, s} =
               states(
                 [repo("web/_catalogue")],
                 %{"web/_catalogue" => "name: web\n"},
                 %{{"web/_catalogue", "main"} => "s"},
                 %{},
                 %{"web" => true}
               )

      assert %{state: :installed} = s["web"]
    end

    test "type de proprietaire ILLISIBLE : le store est GARDE — on ne retrograde pas sur un hoquet" do
      # Owner-type errors favor installed, accepting possible temporary misclassification of a deposit.
      assert {:ok, s} =
               states(
                 [repo("web/_catalogue")],
                 %{"web/_catalogue" => "name: web\n"},
                 %{{"web/_catalogue", "main"} => "s"},
                 %{},
                 %{"web" => :unreachable}
               )

      assert %{state: :installed, updatable?: nil} = s["web"]
    end
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
                 [repo("alice/web"), repo("web/_catalogue")],
                 %{"alice/web" => "name: web\n", "web/_catalogue" => "name: web\n"},
                 %{
                   {"alice/web", "main"} => "d1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4",
                   {"web/_catalogue", "main"} => "aaaabbbbccccddddeeeeffff0000111122223333"
                 },
                 %{"web/_catalogue" => "d1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4"}
               )

      assert "INSTALLED web -" in CatalogueLifecycle.lines(s)
    end

    test "UPDATABLE le REPREND — c'est de la que la mise a jour viendrait" do
      assert {:ok, s} =
               states(
                 [repo("alice/web"), repo("web/_catalogue")],
                 %{"alice/web" => "name: web\n", "web/_catalogue" => "name: web\n"},
                 %{
                   {"alice/web", "main"} => "e2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5",
                   {"web/_catalogue", "main"} => "aaaabbbbccccddddeeeeffff0000111122223333"
                 },
                 %{"web/_catalogue" => "d1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4"}
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
            {Fleet.Forge.Client.Repo, :branch_commit, 3},
            {Fleet.Forge.Client.Repo, :org_exists?, 2},
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
