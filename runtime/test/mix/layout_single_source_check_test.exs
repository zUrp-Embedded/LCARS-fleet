defmodule Mix.Tasks.Lcars.Contracts.LayoutSingleSourceCheckTest do
  @moduledoc """
  Les quatre verrous `layout.*_single_source`, prouves contre des depots FABRIQUES.

  `layout.platform_root_single_source`, `layout.runtime_root_single_source`,
  `layout.face_roots_single_source`, `layout.catalogue_roots_single_source`. Aucun n'avait de
  temoin : ils n'etaient tenus que par le garde universel « aucun mur ne passe sur rien », qui
  mesure une POPULATION, pas une morsure.

  ## Ce que ces murs gardent, et pourquoi un temoin est indispensable

  `Fleet.Layout` declare les racines de la machine ; le reste du corpus — shell, manifeste,
  Dockerfile, prose — les RECOPIE, parce que le BEAM et le shell ne peuvent pas s'appeler. Le
  verrou est ce qui rend l'accord vrai. Une divergence ne casse rien : elle fait installer une
  moitie du conteneur la ou l'autre moitie ne regardera jamais.

  Et ces murs sont fait de LISTES D'EXEMPTION nommees a la main (`/opt/homebrew`,
  `/home/projects.work`, les chaines d'outils versionnees). Une exemption trop large ne rougit
  jamais : elle rend le mur muet sur la classe qu'il croit garder. C'est exactement ce qu'un arbre
  fabrique peut mesurer et que le depot reel, propre par construction, ne peut pas.

  ## Le decor

  Un depot minimal : `<tmp>/runtime/lib/fleet/layout.ex` porte les autorites, et les fichiers du
  corpus portent les copies. Les verrous lisent `root` pour `runtime/`, et `..` pour le depot
  entier (`face_roots`) ou pour les arbres freres (`catalogue_roots`, dont trois miroirs vivent
  sous `deploy/`).
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Lcars.Contracts.Check.SingleSource

  # Les autorites, dans la forme EXACTE que les verrous savent lire : un attribut, une chaine
  # litterale, en fin de ligne. Une valeur composee doit rendre l'autorite illisible — c'est une
  # propriete a part, mesuree plus bas.
  @layout """
  defmodule Fleet.Layout do
    @code_root "/home/projects"
    @ops_root "/home/projects.ops"
    @workshop_root "/home/projects.workshop"
    @platform_root "/opt/lcars"
    @catalogues_dirname "catalogues"
    @installed_catalogues_root "/opt/lcars/var/catalogues"
    @runtime_root "/run/lcars"

    def face_root("code"), do: @code_root
    def face_root("workshop"), do: @workshop_root
    def face_root("ops"), do: @ops_root
  end
  """

  # ⚠ LES CHEMINS EN VIOLATION SE COMPOSENT, ILS NE S'ECRIVENT PAS EN TOUTES LETTRES — et c'est le
  # mur lui-meme qui l'a impose. Ces verrous balaient le corpus ENTIER, `test/` compris : un
  # `"/opt/lcars2"` litteral dans ce fichier est une seconde racine sous `/opt` du point de vue du
  # depot, et il l'a accusee (mesure du 2026-09-08, gate rouge sur deux verrous).
  #
  # Le concatener laisse sur la ligne l'autorite seule (`/opt/lcars`), que le mur reconnait, et
  # reconstitue la violation A L'EXECUTION, la ou le decor en a besoin. Ce n'est pas un contournement
  # du mur : c'est la meme discipline que le reste du corpus, ou un exemple de ce qui est interdit
  # ne s'ecrit jamais sous la forme qui est interdite.
  @racine_opt_intruse "/opt/lcars" <> "2"
  @racine_run_intruse "/run/" <> "old-lcars"
  @racine_run_prefixe "/run/lcars" <> "x"

  defp depot(opts) do
    root = Fleet.TestEnv.tmp_path("layout_verrous")
    on_exit(fn -> File.rm_rf!(root) end)

    runtime = Path.join(root, "runtime")
    File.mkdir_p!(Path.join(runtime, "lib/fleet"))
    File.mkdir_p!(Path.join(root, "deploy/lib"))

    File.write!(
      Path.join(runtime, "lib/fleet/layout.ex"),
      Keyword.get(opts, :layout, @layout)
    )

    for {rel, contenu} <- Keyword.get(opts, :fichiers, []) do
      chemin = Path.join(root, rel)
      File.mkdir_p!(Path.dirname(chemin))
      File.write!(chemin, contenu)
    end

    runtime
  end

  # ══════════════════════════════════════════════════════════════════════════════════════════════
  describe "layout.platform_root_single_source — une seconde racine sous /opt" do
    test "une racine LCARS inconnue est nommee" do
      # Une moitie du conteneur s'installe sous `/opt/lcars`, l'autre sous `/opt/lcars2`, et rien
      # ne le dit : les deux chemins existent, aucun test ne les compare.
      root =
        depot(
          fichiers: [
            {"runtime/bin/lcars", "PREFIX=/opt/lcars\n"},
            {"runtime/services/x.sh", "AUTRE=#{@racine_opt_intruse}/var\n"}
          ]
        )

      assert %{status: :fail, evidence: ev} = SingleSource.check_platform_root_single_source(root)
      assert @racine_opt_intruse in ev
    end

    test "les racines ETRANGERES declarees passent, et les chaines VERSIONNEES aussi" do
      # ⚠ CE TEMOIN GARDE LES DEUX EXEMPTIONS. Elles sont le point faible de ce mur : trop larges,
      # il devient muet ; retirees, il accuse l'image entiere. Aucune des deux n'etait mesuree.
      root =
        depot(
          fichiers: [
            {"runtime/bin/lcars", "PREFIX=/opt/lcars\n"},
            {"runtime/Dockerfile",
             "COPY x /opt/homebrew/bin\nENV P=/opt/bin:/opt/skills\n" <>
               "RUN ln -s /opt/elixir-1.18.4 /opt/node-20\nEXEC /opt/claude_launch\n"}
          ]
        )

      assert %{status: :pass, evidence: []} = SingleSource.check_platform_root_single_source(root)
    end

    test "⚠ LE GARDE D'INSTRUMENT EST INATTEIGNABLE DEPUIS UN ARBRE BIEN FORME, et c'est mesure" do
      # Le mur rend INSTRUMENT BROKEN quand l'autorite ne figure pas parmi les racines vues — un
      # ensemble vide n'accuse personne et se lit comme une conformite. Mesure du 2026-09-08 : ce
      # cas ne se produit PAS sur un arbre qui declare son autorite, parce que `lib/fleet/layout.ex`
      # fait lui-meme partie du corpus balaye. La ligne `@platform_root "/opt/lcars"` est une
      # occurrence, et elle suffit.
      #
      # Le garde protege donc contre un scan qui n'a lu AUCUN fichier (racine illisible, filtre de
      # chemin trop large — les deux se sont deja produits sur ce mur), pas contre un corpus muet.
      # Ecrit ici plutot que tu : un temoin qui viserait cette branche-la serait un temoin qu'aucun
      # arbre valide ne peut rougir.
      root = depot(fichiers: [{"runtime/bin/lcars", "rien du tout\n"}])

      assert %{status: :pass, note: note} = SingleSource.check_platform_root_single_source(root)
      assert note =~ "1 files carry a /opt path"
    end

    test "une autorite COMPOSEE rend le verrou illisible — pas un prefixe tronque" do
      # `@platform_root "/opt/" <> "lcars"` n'a pas d'ancre de fin de ligne : le mur doit refuser de
      # comparer plutot que de retenir `/opt/`.
      root =
        depot(
          layout:
            String.replace(
              @layout,
              "@platform_root \"/opt/lcars\"",
              "@platform_root \"/opt/\" <> \"lcars\""
            ),
          fichiers: [{"runtime/bin/lcars", "PREFIX=/opt/lcars\n"}]
        )

      assert %{status: :fail} = SingleSource.check_platform_root_single_source(root)
    end
  end

  # ══════════════════════════════════════════════════════════════════════════════════════════════
  describe "layout.runtime_root_single_source — une socket ecrite la ou personne n'ecoute" do
    test "un second arbre /run qui nomme lcars est nomme" do
      # ⚠ LE CHOIX DE `/run/old-lcars` N'EST PAS COSMETIQUE, et ma premiere ecriture s'est trompee :
      # j'avais pris `/run/lcars-old`, que le mur ACCEPTE — le `-` est une frontiere declaree, celle
      # des freres plats (`/run/lcars-provision.rc`), et rien ne distingue `-old` de `-provision`.
      # Une violation doit donc etre un arbre qui ne commence PAS par l'autorite.
      root =
        depot(
          fichiers: [
            {"runtime/bin/lcars", "SOCK=/run/lcars/mcp.sock\n"},
            {"runtime/services/x.sh", "AUTRE=#{@racine_run_intruse}/egress.sock\n"}
          ]
        )

      assert %{status: :fail, evidence: ev} = SingleSource.check_runtime_root_single_source(root)
      assert Enum.any?(ev, &(&1 =~ @racine_run_intruse))
    end

    test "les freres plats du meme arbre passent — `-` et `.` sont des frontieres" do
      # `/run/lcars-provision.rc` et `/run/lcars.pid` sont de l'etat LCARS : ils commencent par
      # l'autorite suivie d'une FRONTIERE. Sans ce temoin, durcir la regle en « `/` uniquement »
      # accuserait des marqueurs de boot legitimes.
      root =
        depot(
          fichiers: [
            {"runtime/bin/lcars",
             "SOCK=/run/lcars/mcp.sock\nRC=/run/lcars-provision.rc\nPID=/run/lcars.pid\n"}
          ]
        )

      assert %{status: :pass, evidence: []} = SingleSource.check_runtime_root_single_source(root)
    end

    test "⚠ UN PREFIXE N'EST PAS UNE APPARTENANCE — l'autorite suivie d'une lettre est un autre arbre" do
      # C'EST LA MUTATION QUI A CORRIGE CE MUR. `String.starts_with?` seul laisse passer
      # un `/run/lcars` suivi d'une lettre : il commence bien par l'autorite. La frontiere fait la
      # difference entre un arbre et une coincidence de sous-chaine.
      root =
        depot(
          fichiers: [
            {"runtime/bin/lcars",
             "SOCK=/run/lcars/mcp.sock\nPIEGE=#{@racine_run_prefixe}/mcp.sock\n"}
          ]
        )

      assert %{status: :fail, evidence: ev} = SingleSource.check_runtime_root_single_source(root)
      assert Enum.any?(ev, &(&1 =~ @racine_run_prefixe))
    end

    test "`/run` du systeme n'est pas accuse — la machine hote n'est pas notre corpus" do
      root =
        depot(
          fichiers: [
            {"runtime/bin/lcars",
             "SOCK=/run/lcars/mcp.sock\nXDG=/run/user/1000\nSD=/run/systemd/system\n"}
          ]
        )

      assert %{status: :pass, evidence: []} = SingleSource.check_runtime_root_single_source(root)
    end
  end

  # ══════════════════════════════════════════════════════════════════════════════════════════════
  describe "layout.face_roots_single_source — un arbre que la declaration ne connait pas" do
    test "une quatrieme racine /home/projects est nommee" do
      # Une face que `Fleet.Layout.face_root/1` ignore est un arbre que le runtime ne regardera
      # jamais : les fichiers y sont, et rien ne les lit.
      root =
        depot(
          fichiers: [
            {"runtime/bin/lcars",
             "C=/home/projects\nW=/home/projects.workshop\nO=/home/projects.ops\n"},
            {"runtime/services/x.sh", "X=/home/projects.archive\n"}
          ]
        )

      assert %{status: :fail, evidence: ev} = SingleSource.check_face_roots_single_source(root)
      assert "/home/projects.archive" in ev
    end

    test "les trois faces et l'arbre HORS FACE declare passent" do
      root =
        depot(
          fichiers: [
            {"runtime/bin/lcars",
             "C=/home/projects\nW=/home/projects.workshop\nO=/home/projects.ops\n" <>
               "T=/home/projects.work\n"}
          ]
        )

      assert %{status: :pass, evidence: []} = SingleSource.check_face_roots_single_source(root)
    end

    test "⚠ MOINS DE TROIS CLAUSES `face_root/1` → rien n'a ete compare, et le mur le DIT" do
      sans_ops = String.replace(@layout, "  def face_root(\"ops\"), do: @ops_root\n", "")

      root =
        depot(
          layout: sans_ops,
          fichiers: [{"runtime/bin/lcars", "C=/home/projects\nW=/home/projects.workshop\n"}]
        )

      assert %{status: :fail, note: note} = SingleSource.check_face_roots_single_source(root)
      assert note =~ "nothing was compared"
    end

    test "⚠ ICI AUSSI le garde d'instrument est inatteignable depuis un arbre bien forme" do
      # Meme mesure que sur le verrou `/opt` : les trois racines de face sont DECLAREES dans
      # `lib/fleet/layout.ex`, qui fait partie du corpus balaye. Elles y figurent donc toujours, et
      # la branche « une face declaree absente du corpus » ne se joue pas sur un arbre valide.
      #
      # Ce qui reste atteignable, et qui est teste juste au-dessus, c'est l'autre garde : moins de
      # trois clauses `face_root/1`, ou une clause dont la racine ne se lit pas.
      root = depot(fichiers: [{"runtime/bin/lcars", "C=/home/projects\n"}])

      assert %{status: :pass, note: note} = SingleSource.check_face_roots_single_source(root)
      assert note =~ "3 faces declared"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════════════════════════
  describe "layout.catalogue_roots_single_source — la fleet lit ou l'image n'a jamais ecrit" do
    # Sept miroirs recopient deux valeurs derivees (`<platform>/<dirname>` et
    # `@installed_catalogues_root`), dont le `COPY` du Dockerfile — le CREATEUR de l'arbre. Le BEAM
    # et le shell ne peuvent pas s'appeler : l'accord EST le verrou.
    defp miroirs(shipped, installed) do
      [
        {"runtime/bin/lcars",
         "CAT_SHIPPED=\"${LCARS_CATALOGUES_SHIPPED:-#{shipped}}\"\n" <>
           "CAT_DIR=\"${LCARS_CATALOGUES_DIR:-#{installed}}\"\n"},
        {"runtime/services/forge-gestures.sh",
         "D=\"${LCARS_DEMO_CATALOGUE:-#{shipped}/web-demo}\"\n" <>
           "I=\"${LCARS_CATALOGUES_DIR:-#{installed}}\"\n"},
        {"deploy/docker/Dockerfile", "COPY catalogues #{shipped}\n"},
        {"deploy/system.manifest", "dir #{installed} 0755 root root\n"},
        {"deploy/lib/provision-lib.sh", ": \"${PROV_CATALOGUES_DIR:=#{installed}}\"\n"}
      ]
    end

    test "les sept miroirs d'accord → vert, et la preuve NOMME les fichiers lus" do
      root = depot(fichiers: miroirs("/opt/lcars/catalogues", "/opt/lcars/var/catalogues"))

      assert %{status: :pass, evidence: ev, note: note} =
               SingleSource.check_catalogue_roots_single_source(root)

      # ⚠ CE MUR PORTE SA PREUVE MEME AU VERT, et c'est une propriete, pas un residu : les sept
      # miroirs vivent dans quatre arbres dont deux hors artefact, donc « vert » sans la liste ne
      # dirait pas COMBIEN ont ete lus. Ma premiere ecriture attendait `evidence: []` et rougissait
      # sur un mur parfaitement sain.
      assert Enum.any?(ev, &(&1 =~ "Dockerfile"))
      assert Enum.any?(ev, &(&1 =~ "bin/lcars"))
      assert note =~ "7 checked copies"
    end

    test "⚠ LE CREATEUR QUI DERIVE — un `COPY` qui ne suit pas l'autorite est nomme" do
      # LE MIROIR QUI COMPTE LE PLUS : si le `COPY` de l'image ne suit pas, la fleet lit un arbre
      # que l'image n'a jamais ecrit — et le CLI montre le cache en mode DEGRADE, au moment precis
      # ou l'operateur n'a aucune seconde source pour recouper.
      fichiers =
        miroirs("/opt/lcars/catalogues", "/opt/lcars/var/catalogues")
        |> Keyword.new(fn {k, v} -> {String.to_atom(k), v} end)
        |> Keyword.put(:"deploy/docker/Dockerfile", "COPY catalogues /opt/lcars/seeds\n")
        |> Enum.map(fn {k, v} -> {Atom.to_string(k), v} end)

      root = depot(fichiers: fichiers)

      assert %{status: :fail, evidence: ev} =
               SingleSource.check_catalogue_roots_single_source(root)

      assert Enum.any?(ev, &(&1 =~ "Dockerfile"))
    end

    test "une autorite illisible fait ECHOUER, elle ne fait pas « rien a comparer »" do
      # Fail-closed : une autorite illisible est le seul cas ou TOUS les miroirs passent par defaut.
      root =
        depot(
          layout:
            String.replace(
              @layout,
              "@catalogues_dirname \"catalogues\"",
              "@catalogues_dirname @nom"
            ),
          fichiers: miroirs("/opt/lcars/catalogues", "/opt/lcars/var/catalogues")
        )

      assert %{status: :fail, note: note} =
               SingleSource.check_catalogue_roots_single_source(root)

      assert note =~ "nothing was compared"
    end
  end
end
