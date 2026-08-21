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

    # Par defaut TOUT proprietaire est une org : les temoins anterieurs a D1 decrivent des stores
    # legitimes, et les faire tous declarer une carte d'orgs noierait ce qu'ils tiennent. Le temoin
    # D1 passe `orgs:` explicitement.
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

    # LE MESSAGE FAIT PARTIE DE LA REPONSE, et la doublure le porte : c'est lui qui dit quelle
    # source le store projette. Une doublure qui ne rendrait que le sha ferait passer tous les
    # temoins d'`updatable` sur une comparaison que le vrai code ne fait plus.
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

  # ⚠ UN STORE PORTE SON MANIFESTE, ET C'EST CE QUI LE DESIGNE COMME STORE depuis 2026-08-21
  # (`owner == manifest.name`). Ce n'est pas une commodite de doublure : le store est une PROJECTION
  # de l'arbre du depot, donc il porte le `catalogue.yaml` de ce depot, avec le meme `name:`. Une
  # doublure qui l'omet decrit un store que la forge ne produit pas — et fait passer un temoin sur
  # une absence de manifeste au lieu du garde qu'il pretend tenir.
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
    # ⚠ LES DEUX SHA DE COMMIT SONT DIFFERENTS ICI, ET C'EST LE POINT. Le store est un commit FRAIS
    # qui reflete l'arbre du depot ; deux commits de contenu identique ne partagent jamais de sha.
    # La premiere version comparait ces deux tetes et repondait donc « updatable » TOUJOURS —
    # mesure sur banc du 2026-08-16, `web-demo` installe trente secondes plus tot s'affichait
    # « MAJ DISPO ». Ce qui les relie est le trailer que la projection porte.
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
    # Un store pousse par une version anterieure du geste. On ne peut pas comparer, donc on ne dit
    # pas « a jour » : ce serait annoncer frais un catalogue dont on ignore l'etat.
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
    # `nil` et `false` sont deux reponses differentes : « on ne peut pas savoir » et « c'est a
    # jour ». Les confondre annoncerait comme frais un catalogue dont la source a disparu.
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
    # Il vit dans le release. Repondre « available » pour lui serait mentir sur le SEUL catalogue
    # qui marche toujours, y compris quand la forge ne porte rien.
    assert {:ok, s} = states([])
    assert %{state: :installed, store: nil} = s["fleet"]
  end

  test "un depot d'utilisateur NOMME `catalogue` sort AVAILABLE, avec son adresse" do
    # ⚠ DE BOUT EN BOUT : c'est la ligne que `lcars catalogue list` imprime, pas seulement l'etat
    # interne. Avant le 2026-08-21, `bob` ne voyait AUCUNE ligne — la reservation du nom l'ecartait
    # en silence, et il n'avait aucun moyen d'apprendre pourquoi.
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
    # Sinon un catalogue installe serait AUSSI disponible depuis son propre store, donc toujours
    # « a jour » par construction — une comparaison d'un objet avec lui-meme.
    assert {:ok, s} =
             states([repo("web/_catalogue")], %{"web/_catalogue" => "name: web\n"}, %{
               {"web/_catalogue", "main"} => "s"
             })

    assert %{state: :installed, deposit: nil} = s["web"]
  end

  describe "D1 — signer une installation demande une ORG, pas seulement une identite" do
    test "un depot qui se declare a son propre nom, dans un espace PERSO, ne signe RIEN" do
      # ⚠ LE TROU QUE LE TROISIEME REGARD A TROUVE, apres que deux auto-audits l'ont rate : orgs et
      # comptes perso partagent l'espace de noms Gitea, et rien ne verifiait le TYPE du
      # proprietaire. `alice` poussait un depot public `catalogue` chez elle -> `alice` sortait
      # INSTALLE, le convergeur clonait son materiel, le mint derivait son roster. Le gate admin
      # contourne par un push.
      #
      # ⚠ LE MANIFESTE DIT `name: alice`, ET C'EST DELIBERE. Depuis que le garde est
      # `owner == manifest.name`, un depot sans manifeste n'est plus un candidat store du tout : le
      # laisser vide ferait passer ce temoin sur l'absence de manifeste, en ayant l'air de tenir le
      # type du proprietaire. Ici l'identite est SATISFAITE et la SEULE chose qui refuse est
      # `org_exists?` — ce que ce temoin pretend mesurer.
      assert {:ok, s} =
               states(
                 [repo("alice/_catalogue")],
                 %{"alice/_catalogue" => "name: alice\n"},
                 %{{"alice/_catalogue", "main"} => "s"},
                 %{},
                 %{"alice" => false}
               )

      refute Map.has_key?(s, "alice")

      # Et il ne redevient pas un DEPOT par la bande : son identite est celle de son proprietaire,
      # donc `split/2` l'a range en candidat store — c'est `org_exists?` qui le jette, pas son nom.
      assert Map.keys(s) == ["fleet"]
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
      # `{:error, _}` n'est pas « pas une org ». L'autre lecture retrograderait un catalogue
      # installe en disponible pendant une panne — le mensonge inverse de D1, plus cher que le cout
      # transitoire accepte (un depot perso frais annonce installe le temps du hoquet).
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
      # ⚖ user, 2026-08-16 : « il peut afficher de quel user vient les catalogues available ? ».
      # C'est LA question d'un admin avant d'installer : le materiel de QUI est-ce que je m'apprete
      # a servir a tout le monde. L'owner est le premier segment du `full_name` — la convention de
      # la forge elle-meme, pas un second rendu du meme fait.
      assert {:ok, s} =
               states([repo("bob/mob")], %{"bob/mob" => "name: mobile\n"}, %{
                 {"bob/mob", "main"} => "d1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4"
               })

      assert "AVAILABLE mobile bob/mob" in CatalogueLifecycle.lines(s)
    end

    test "INSTALLED ne porte PAS le depot — ce n'est plus la source que la boite suit" do
      # ⚖ user : « une fois installe, osef de l'origine ». Et ce n'est pas qu'une question de bruit :
      # ce que la boite suit desormais est `<nom>/_catalogue`, le store. Imprimer le depot la nomme
      # quelque chose qui n'est plus la source, dans la colonne qu'un operateur lit COMME la source.
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
      # Meme regle, pas une exception : le depot redevient ce que le prochain `install` tirerait.
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
      # ⚠ LE DEFAUT QUE CE TEMOIN GARDE, ET IL A EU LIEU LE 2026-08-16 : `branch_sha/3` a ete
      # supprime de `Fleet.Forge.Client.Repo` (c'etait un doublon de `branch_head/3`, ajoute sans
      # avoir cherche s'il existait deja). Le compilateur n'a rien dit — l'appel passe par une
      # VARIABLE (`repo_mod.branch_sha(...)`), donc il est invisible a l'analyse — et toute la
      # suite restait verte, parce que les doublures, elles, definissaient encore le nom.
      #
      # Une doublure ne prouve rien sur le module qu'elle remplace. Celui-ci le verifie.
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
      # ⚠ LE DEFAUT QUE CE TEMOIN GARDE, ET IL A ETE MESURE SUR BANC LE 2026-08-16 :
      # `lcars catalogue list` rendait `** (ArgumentError) unknown registry: Fleet.Forge.Finch`
      # sous la ligne « la forge n'a pas repondu ». Une porte `eval` saute le corps de config de
      # deploiement (c'est le but de `LCARS_TOOL_EVAL`), donc l'app n'est pas demarree et le pool
      # Finch de `Fleet.Forge` n'existe pas.
      #
      # AUCUN TEMOIN NE POUVAIT L'ATTRAPER : tous ceux d'au-dessus injectent `forge_repo` et
      # `forge_files`, donc le chemin qui a besoin du pool n'etait pris par personne. Celui-ci lit
      # la SOURCE et exige l'appel — la seule facon de tenir un demarrage depuis un test qui tourne
      # deja dans une VM ou tout est demarre.
      src = File.read!("lib/fleet/application/catalogue_lifecycle.ex")

      assert src =~ "defp with_transport",
             "le demarrage du transport a disparu — les portes eval rendront une ArgumentError"

      # ⚠ CE TEMOIN MESURAIT UNE DISTANCE EN CARACTERES (`String.slice(corps, 0, 200)`), et une
      # distance n'est pas une structure : ajouter un commentaire en tete d'une porte — un geste
      # qui ne touche a aucun appel — poussait `with_transport` hors de la fenetre et rendait le
      # temoin rouge. Un test qui casse sur de la prose apprend a le contourner. La borne est
      # desormais la FIN DE LA FONCTION : la definition suivante au meme niveau d'indentation.
      for porte <- ["def eval_main do", "def eval_source(name) when is_binary(name) do"] do
        [_, apres] = String.split(src, porte, parts: 2)
        corps = apres |> String.split(~r/\n  defp? /, parts: 2) |> hd()

        assert corps =~ "with_transport",
               "#{porte} appelle la forge sans demarrer le transport"
      end
    end
  end
end
