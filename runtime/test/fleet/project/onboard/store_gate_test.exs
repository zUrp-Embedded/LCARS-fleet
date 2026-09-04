defmodule Fleet.Project.Onboard.StoreGateTest do
  @moduledoc """
  Le magasin d'un catalogue n'est pas un projet — le refus sur les portes ou un ADMIN TAPE LE NOM.

  ## Pourquoi ces portes-la et pas `reconcile`

  `reconcile/2` est deja garde, et mieux que par un nom : il demande a chaque depot « portes-tu une
  declaration de projet (`.lcars.json` sur `main`) ? ». Un garde par PROPRIETE, qui tient sans jamais
  connaitre le mot « catalogue ».

  Les portes explicites n'ont pas ce bouclier, et le scenario n'est pas theorique : un admin importe
  `web/_catalogue` « pour voir », la fleet pose trois faces et ecrit `.lcars.json` a la racine — et
  le magasin DEVIENT un projet declare. Le garde par propriete se retourne alors : a partir du
  passage suivant, il defend la propriete posee par erreur. C'est pour ca que c'est un refus a la
  porte et pas une reparation apres coup.

  ## Les TROIS portes, et deux questions differentes

  `import` et `migrate` agissent sur un depot qui EXISTE : on lui demande son identite
  (`owner == manifest.name`), la meme question que `CatalogueDeposits.split/2`, donc les deux ne
  peuvent pas etre en desaccord sur ce qu'est un magasin.

  `adopt_project` CREE un depot : il n'y a rien a interroger. Ce avec quoi il peut entrer en
  collision est l'ADRESSE — `push_store` force-pousse la, donc un projet adopte a ce nom est un
  projet que le prochain `catalogue install` ecrase sans un mot.

  Tester une seule des trois est la forme exacte du defaut trouve cette nuit-la : la reservation du
  nom etait appliquee aux depots et pas aux magasins, et l'asymetrie a tenu deux auto-audits.
  """
  use ExUnit.Case, async: true

  alias Fleet.Project.Onboard.Refute, as: ProjectOnboard

  @moduletag :tmp_dir

  # Le magasin de `web` : son manifeste declare le nom de son org. C'est ce que la forge sert
  # reellement — le magasin est une PROJECTION de l'arbre du depot, donc il porte son manifeste.
  defmodule StoreFiles do
    def get_file("web/_catalogue", "catalogue.yaml", _fc),
      do: {:ok, %{content: "api_version: 1\nname: web\n", sha: "f00"}}

    def get_file(_repo, "catalogue.yaml", _fc), do: {:error, :not_found}
  end

  # Un depot pose A L'ADRESSE d'un magasin, dans une vraie org de catalogue, mais qui declare un
  # AUTRE nom. Ce n'est pas le magasin de `web` : le nom ne decide rien, l'identite si.
  defmodule ImposterFiles do
    def get_file("web/_catalogue", "catalogue.yaml", _fc),
      do: {:ok, %{content: "api_version: 1\nname: autre-chose\n", sha: "f00"}}

    def get_file(_repo, "catalogue.yaml", _fc), do: {:error, :not_found}
  end

  defmodule MuteFiles do
    def get_file(_repo, "catalogue.yaml", _fc), do: {:error, {:http, 503, "down"}}
  end

  describe "refute_store/2 — la question posee a un depot qui existe" do
    test "le magasin de son propre catalogue est REFUSE, et le refus nomme le bon geste" do
      assert {:error, {:repo_is_catalogue_store, "web/_catalogue", why}} =
               ProjectOnboard.refute_store("web/_catalogue", forge_files: StoreFiles)

      # Le refus doit NOMMER ce qu'il refuse et ce qu'il fallait faire. Un refus qui dit seulement
      # « non » envoie l'admin chercher la cause dans le code.
      assert why =~ "STORE of the catalogue 'web'"
      assert why =~ "lcars catalogue install web"
    end

    test "un depot a l'ADRESSE d'un magasin qui declare un autre nom PASSE" do
      # Le complement, et le plus dur a passer par accident : sans lui, un garde qui lirait le nom du
      # depot serait vert sur le test precedent tout en etant faux.
      assert :ok = ProjectOnboard.refute_store("web/_catalogue", forge_files: ImposterFiles)
    end

    test "un depot ordinaire PASSE, en silence" do
      assert :ok = ProjectOnboard.refute_store("web/vitrine", forge_files: StoreFiles)
    end

    test "manifeste ILLISIBLE : refus NOMME comme illisible, jamais comme un magasin" do
      # ⚠ LA DIFFERENCE QUI COUTE. 404 est une reponse (« pas un catalogue ») ; une forge muette est
      # une ABSENCE de reponse. Les confondre dans un sens importe un magasin sur un hoquet ; dans
      # l'autre, ca accuse un depot parfaitement sain d'etre un magasin, et l'admin va supprimer le
      # mauvais objet. Importer est cher et se defend tout seul ensuite ; reessayer est gratuit.
      assert {:error, {:store_check_unreadable, "web/vitrine", why}} =
               ProjectOnboard.refute_store("web/vitrine", forge_files: MuteFiles)

      assert why =~ "unknown whether this repo is a catalogue's store"
      refute why =~ "STORE of the catalogue"
    end
  end

  describe "refute_store_address/2 — la question posee a un depot qui n'existe pas encore" do
    test "l'adresse du magasin est refusee, et le refus dit ce qui l'ecraserait" do
      store = Fleet.Catalogue.store_repo()

      assert {:error, {:store_address, full, why}} =
               ProjectOnboard.refute_store_address("web/#{store}", store)

      assert full == "web/#{store}"
      assert why =~ "force-pushes"
    end

    test "tout autre nom passe" do
      assert :ok = ProjectOnboard.refute_store_address("web/catalogue", "catalogue")
      assert :ok = ProjectOnboard.refute_store_address("web/vitrine", "vitrine")
    end
  end

  describe "LES TROIS PORTES sont cablees — une seule gardee est le defaut, pas le correctif" do
    # Ce temoin lit la SOURCE, comme celui de l'admission commune et pour la meme raison : exercer
    # les trois portes de bout en bout demanderait trois mondes (forge, depots, arbres locaux), et
    # c'est precisement ce cout qui laisse une porte non gardee passer inapercue.
    # ⚠ LA FAMILLE, PAS UN FICHIER. Ce temoin lisait `lib/fleet/project/onboard.ex` seul ; au
    # decoupage, `migrate/3` a change de module et le temoin est tombe sur un `MatchError` — le cas
    # heureux. Un temoin de SOURCE attache a une adresse cesse de voir ce qui demenage, et le
    # silencieux, c'est celui qui aurait trouve son verbe ailleurs et l'aurait rate.
    @src ["lib/fleet/project/onboard.ex" | Path.wildcard("lib/fleet/project/onboard/*.ex")]

    test "`import/2` interroge l'identite de sa cible" do
      assert door_preamble("import") =~ "refute_store(full_name, opts)"
    end

    test "`migrate/3` interroge l'identite de sa cible" do
      assert door_preamble("migrate") =~ "refute_store(full_name, opts)"
    end

    test "`adopt_project/2` refuse l'ADRESSE, parce qu'il n'y a rien a interroger" do
      corps = door_preamble("adopt_project")

      assert corps =~ "refute_store_address(full_name, name)"

      # ET PAS `refute_store` : interroger un depot qui n'existe pas rendrait `:not_found`, donc
      # `:ok`, donc un garde vert qui ne garde rien. La porte qui CREE ne pose pas la question de la
      # porte qui LIT.
      refute corps =~ "refute_store(full_name"
    end

    defp door_preamble(verb) do
      motif = ~r/^  def #{verb}\(/m

      corps =
        for f <- @src, source = File.read!(f), Regex.match?(motif, source) do
          [_, body] = String.split(source, motif, parts: 2)
          String.slice(body, 0, 1400)
        end

      case corps do
        [body] -> body
        [] -> flunk("`def #{verb}(` introuvable dans la famille onboarding")
        n -> flunk("`def #{verb}(` defini #{length(n)} fois : le temoin ne sait pas lequel lire")
      end
    end
  end
end
