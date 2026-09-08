defmodule Mix.Tasks.Lcars.Contracts.TestsCorpusWallsCheckTest do
  @moduledoc """
  Les quatre murs qui gardent la FORME du corpus de temoins, prouves contre des arbres FABRIQUES.

  `tests.witness_naming`, `tests.negations_bite`, `tests.refute_copies_agree`,
  `tests.dirs_mirror_source`. Aucun n'avait de temoin : ils n'etaient tenus que par le garde
  universel « aucun mur ne passe sur rien », qui mesure une POPULATION, pas une morsure.

  ⚖ Un mur sur la suite de tests que la suite de tests ne mesure pas est le cas le plus exposé du
  dépôt : il se corrige comme n'importe quel code, et rien ne dit qu'il mord encore.

  ## Pourquoi des arbres fabriques, et pas le vrai depot

  Le depot est PROPRE — c'est le travail de ces murs. Joue sur lui, chaque mur rend `:pass` et ne
  peut donc prouver ni qu'il attrape sa violation, ni qu'il epargne les formes qu'il exempte
  volontairement. Un comportement qu'aucun temoin ne rougit est un comportement que le prochain
  lecteur supprimera en croyant simplifier.

  Chaque mur a ici trois temoins : sa VIOLATION est nommee, son EXEMPTION passe, et son garde
  d'instrument se declenche sur un arbre vide.
  """
  use ExUnit.Case, async: true

  # ⚠ LA PHRASE DE L'INSTRUMENT CASSE EST EN ANGLAIS, ET C'EST UNE CORRECTION. Ce fichier de murs
  # ecrivait « INSTRUMENT CASSE » la ou tous les autres ecrivent « INSTRUMENT BROKEN » — deux
  # formulations pour un meme etat, donc deux choses a chercher pour l'operateur, et des temoins
  # qui epinglent l'une deviennent aveugles a l'autre. Le combinateur `Support.measured_verdict/2`
  # n'en porte plus qu'une.

  alias Mix.Tasks.Lcars.Contracts.Check.Tests

  # ⚠ LA FORME DU DECOR EST IMPOSEE PAR LES MURS EUX-MEMES, et pas par confort. Trois d'entre eux
  # lisent DEUX arbres freres — `test/` sous la racine Mix, et `../deploy/tests` a cote — et
  # `Support.mirror_scope/2` decide de sauter le second s'il n'existe pas. Un decor qui n'aurait
  # qu'un arbre ferait donc mesurer autre chose que le sujet : `refute_copies_agree` dirait
  # « INSTRUMENT CASSE » et `dirs_mirror_source` compterait un arbre absent.
  #
  #   <tmp>/runtime/       ← la racine passee au mur
  #   <tmp>/deploy/tests/  ← l'arbre frere, vu comme `../deploy/tests`
  defp depot(opts) do
    root = Fleet.TestEnv.tmp_path("murs_corpus")
    on_exit(fn -> File.rm_rf!(root) end)

    runtime = Path.join(root, "runtime")
    File.mkdir_p!(Path.join(runtime, "test"))
    File.mkdir_p!(Path.join(root, "deploy/tests"))

    for {rel, contenu} <- Keyword.get(opts, :fichiers, []) do
      chemin = Path.join(root, rel)
      File.mkdir_p!(Path.dirname(chemin))
      File.write!(chemin, contenu)
    end

    runtime
  end

  # Le corps de `refute.bash`, identique des deux cotes sauf sur ce que le mur ignore EXPRES : les
  # commentaires. C'est la distinction que le mur porte — le comportement, pas le fichier.
  defp refute_bash(entete),
    do: "# SOURCE: #{entete}\nrefute() {\n  ! \"$@\"\n}\n"

  # ══════════════════════════════════════════════════════════════════════════════════════════════
  describe "tests.witness_naming — un temoin mal nomme n'est pas ramasse, et ne le dit pas" do
    test "un `.exs` sans suffixe `_test` est NOMME" do
      # ⚠ LE COUT EST ASYMETRIQUE, et c'est ce qui justifie un mur. `mix test` ramasse `*_test.exs`
      # par defaut : la faute est une lettre, la consequence est un fichier qui figure dans l'arbre
      # et n'a jamais tourne. Rien ne le signale — pas meme un compte de tests, qui n'a pas de
      # reference.
      root = depot(fichiers: [{"runtime/test/fleet/truc.exs", "defmodule T do\nend\n"}])

      assert %{status: :fail, evidence: [ev]} = Tests.check_witness_naming(root)
      assert ev =~ "truc.exs"
      assert ev =~ "_test.exs"
    end

    test "un `.py` a la mode pytest (`test_x.py`) est NOMME — l'habitude d'a cote n'est pas la regle" do
      # Trois langages cohabitent, et l'extension ne parle que pour `.bats`. Un `test_foo.py` pose a
      # cote d'un `foo_test.py` enseigne DEUX regles pour un meme dossier.
      root = depot(fichiers: [{"deploy/tests/test_installeur.py", "def test_x(): pass\n"}])

      assert %{status: :fail, evidence: [ev]} = Tests.check_witness_naming(root)
      assert ev =~ "test_installeur.py"
    end

    test "`.bats` suffit, et les zones sans temoins sont epargnees" do
      # ⚠ LES QUATRE EXEMPTIONS SONT LE SUJET DE CE TEMOIN. Sans lui, un durcissement du mur
      # (« tout fichier doit finir par `_test` ») serait vert sur le depot reel jusqu'au jour ou
      # quelqu'un ajoute un helper — et le rouge accuserait alors le helper, pas le mur.
      root =
        depot(
          fichiers: [
            {"runtime/test/porte.bats", "@test \"x\" { true; }\n"},
            {"runtime/test/support/aide.ex", "defmodule Aide do\nend\n"},
            {"runtime/test/fixtures/forge/pr.json", "{}\n"},
            {"runtime/test/probes/sonde.exs", "IO.puts(:ok)\n"},
            {"runtime/test/integration/bout_en_bout.exs", "IO.puts(:ok)\n"},
            {"runtime/test/test_helper.exs", "ExUnit.start()\n"},
            {"runtime/test/README.md", "# la carte\n"}
          ]
        )

      assert %{status: :pass, evidence: []} = Tests.check_witness_naming(root)
    end

    test "arbre VIDE → INSTRUMENT BROKEN, jamais un vert propre" do
      assert %{status: :fail, evidence: [ev]} = Tests.check_witness_naming(depot([]))
      assert ev =~ "INSTRUMENT BROKEN"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════════════════════════
  describe "tests.negations_bite — `! cmd` sous bats est INERTE partout sauf en fin de bloc" do
    # POSIX exempte d'`errexit` toute commande niee par `!` : la ligne s'execute, rend 1, et bats
    # passe a la suivante. Elle ne mord QUE si elle est la derniere de son bloc, ou si un `||`
    # rattrape son echec. Partout ailleurs elle est verte au moment PRECIS ou ce qu'elle interdit
    # arrive — deux temoins de securite ont menti des semaines sous cette forme.
    test "une negation SUIVIE d'autre chose est nommee, avec sa ligne" do
      root =
        depot(
          fichiers: [
            {"runtime/test/x.bats",
             "@test \"fuite\" {\n  ! grep -q secret sortie.txt\n  [ -f sortie.txt ]\n}\n"}
          ]
        )

      assert %{status: :fail, evidence: [ev]} = Tests.check_negations_bite(root)
      assert ev =~ "x.bats:2"
      assert ev =~ "inerte"
    end

    test "la negation TERMINALE passe — son code devient celui du test" do
      root =
        depot(
          fichiers: [
            {"runtime/test/x.bats",
             "@test \"fuite\" {\n  [ -f s.txt ]\n  ! grep -q secret s.txt\n}\n"}
          ]
        )

      assert %{status: :pass, evidence: []} = Tests.check_negations_bite(root)
    end

    test "la negation gardee par `||` passe — le rattrapage rend le code" do
      root =
        depot(
          fichiers: [
            {"runtime/test/x.bats",
             "@test \"fuite\" {\n  ! grep -q secret s.txt || { echo 'fuite'; return 1; }\n  true\n}\n"}
          ]
        )

      assert %{status: :pass, evidence: []} = Tests.check_negations_bite(root)
    end

    test "aucun `.bats` → INSTRUMENT BROKEN" do
      assert %{status: :fail, evidence: [ev]} = Tests.check_negations_bite(depot([]))
      assert ev =~ "INSTRUMENT BROKEN"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════════════════════════
  describe "tests.refute_copies_agree — deux corpus qui croient utiliser le meme outil" do
    test "deux corps DIFFERENTS sont nommes, chacun avec son empreinte" do
      # Une correction posee d'un seul cote ne casse aucun test : elle rend un corpus plus
      # PERMISSIF que l'autre, et rien ne le dit.
      root =
        depot(
          fichiers: [
            {"runtime/test/refute.bash", refute_bash("runtime/test/refute.bash")},
            {"deploy/tests/refute.bash",
             "# SOURCE: deploy/tests/refute.bash\nrefute() {\n  \"$@\" && return 1\n}\n"}
          ]
        )

      assert %{status: :fail, evidence: ev} = Tests.check_refute_copies_agree(root)
      assert length(ev) == 2
      assert Enum.any?(ev, &(&1 =~ "runtime/test/refute.bash"))
      assert Enum.any?(ev, &(&1 =~ "deploy/tests/refute.bash"))
    end

    test "meme CODE, commentaires differents → accord : c'est le comportement qui est compare" do
      # ⚠ LES DEUX COPIES NE PEUVENT PAS ETRE IDENTIQUES : `# SOURCE:` porte le chemin du fichier
      # par convention du depot. Un `cmp` serait rouge pour toujours, et un mur toujours rouge
      # apprend a lire « rouge » comme « normal ».
      root =
        depot(
          fichiers: [
            {"runtime/test/refute.bash", refute_bash("runtime/test/refute.bash")},
            {"deploy/tests/refute.bash", refute_bash("deploy/tests/refute.bash")}
          ]
        )

      assert %{status: :pass, evidence: []} = Tests.check_refute_copies_agree(root)
    end

    test "⚠ UNE SEULE COPIE VUE POUR DEUX ARBRES → INSTRUMENT BROKEN, pas un accord" do
      # C'EST LE DEFAUT QUE CE MUR A DEJA EU (relecture hostile du 2026-09-04). Un wildcard qui ne
      # lisait qu'un arbre rendait `distinct == 1`, donc `<= 1`, donc vert — et le mur imprimait
      # lui-meme sa preuve : « 1 copie(s), 1 corps distinct(s) ». Une copie seule s'accorde toujours
      # avec elle-meme.
      root =
        depot(fichiers: [{"runtime/test/refute.bash", refute_bash("runtime/test/refute.bash")}])

      assert %{status: :fail, evidence: [ev]} = Tests.check_refute_copies_agree(root)
      assert ev =~ "INSTRUMENT BROKEN"
      assert ev =~ "s'accorde toujours avec elle-meme"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════════════════════════
  describe "tests.dirs_mirror_source — un chemin de temoin qui ne reflete rien se lit comme un trou" do
    test "un dossier de temoins sans source en face est NOMME" do
      # UN CHEMIN QUI MENT SUR SON DOMAINE COUTE PLUS CHER QU'UN TEMOIN ABSENT : l'absence se voit,
      # le chemin faux SE LIT COMME UNE REPONSE — qui cherche les temoins de `lib/fleet/projet.ex`
      # sous `test/fleet/` n'y trouve rien et en conclut une couverture absente qui est fausse.
      root =
        depot(
          fichiers: [
            {"runtime/lib/fleet/projet.ex", "defmodule P do\nend\n"},
            {"runtime/test/fleet/nulle_part/projet_test.exs", "defmodule PT do\nend\n"},
            {"deploy/tests/transverse/x.bats", "@test \"x\" { true; }\n"}
          ]
        )

      assert %{status: :fail, evidence: [ev]} = Tests.check_test_dirs_mirror_source(root)
      assert ev =~ "test/fleet/nulle_part"
      assert ev =~ "aucune source en face"
    end

    test "un dossier adosse a sa source passe, et les zones declarees aussi" do
      root =
        depot(
          fichiers: [
            {"runtime/lib/fleet/projet.ex", "defmodule P do\nend\n"},
            {"runtime/test/fleet/projet_test.exs", "defmodule PT do\nend\n"},
            {"runtime/test/support/aide_test.exs", "defmodule A do\nend\n"},
            {"deploy/tests/transverse/x.bats", "@test \"x\" { true; }\n"}
          ]
        )

      assert %{status: :pass, evidence: []} = Tests.check_test_dirs_mirror_source(root)
    end

    test "⚠ UN ARBRE DECLARE MAIS ABSENT SE NOMME, IL NE SE COMPTE PAS ZERO" do
      # LA PANNE LA PLUS CHERE, celle qui se presente comme un succes : `Path.wildcard` sur un
      # chemin inexistant rend `[]`, `strays` reste vide, et le total d'un AUTRE arbre garde le
      # verdict positif. Le mur ne dit alors plus « rien a signaler » mais « je n'ai pas regarde ».
      #
      # Ici l'arbre frere `deploy/` EXISTE (donc n'est pas hors artefact) mais `deploy/tests` non.
      root = Fleet.TestEnv.tmp_path("murs_corpus_sans_deploy")
      on_exit(fn -> File.rm_rf!(root) end)
      runtime = Path.join(root, "runtime")
      File.mkdir_p!(Path.join(runtime, "lib/fleet"))
      File.mkdir_p!(Path.join(runtime, "test/fleet"))
      File.mkdir_p!(Path.join(root, "deploy/lib"))
      File.write!(Path.join(runtime, "lib/fleet/projet.ex"), "defmodule P do\nend\n")
      File.write!(Path.join(runtime, "test/fleet/projet_test.exs"), "defmodule PT do\nend\n")

      assert %{status: :fail, evidence: [ev]} = Tests.check_test_dirs_mirror_source(runtime)
      assert ev =~ "../deploy/tests"
      assert ev =~ "absent du disque"
      assert ev =~ "n'a lu aucun de ses temoins"
    end

    test "un arbre frere HORS ARTEFACT se saute, et le dit dans la note" do
      # ⚠ HORS ARTEFACT N'EST PAS DISPARU. Le stage `build` de l'image exclut `deploy/` a dessein :
      # un `absents` sur ce cas rendait `mix release` impossible DANS l'image. La distinction est
      # l'existence de l'arbre frere lui-meme, pas celle de son sous-dossier de temoins.
      root = Fleet.TestEnv.tmp_path("murs_corpus_hors_artefact")
      on_exit(fn -> File.rm_rf!(root) end)
      runtime = Path.join(root, "runtime")
      File.mkdir_p!(Path.join(runtime, "lib/fleet"))
      File.mkdir_p!(Path.join(runtime, "test/fleet"))
      File.write!(Path.join(runtime, "lib/fleet/projet.ex"), "defmodule P do\nend\n")
      File.write!(Path.join(runtime, "test/fleet/projet_test.exs"), "defmodule PT do\nend\n")

      assert %{status: :pass, note: note} = Tests.check_test_dirs_mirror_source(runtime)
      assert note =~ "deploy"
    end
  end
end
