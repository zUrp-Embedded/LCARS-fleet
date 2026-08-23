defmodule Fleet.Project.IntensityTest do
  @moduledoc """
  The criticality declaration: always written complete and schema-valid; the human's
  level RELAYED (never agent-assessed); absence recorded honestly (undeclared C0), never
  fabricated and never walled; the burn reads the declared card with quiet/loud fallbacks.
  """
  # ⚠ `async: false` : ce fichier ECRIT `:catalogue_install_dirs` — la cle la plus large des six : toute resolution de catalogue la lit en env d'APPLICATION, qui est
  # globale au node. Pendant la fenetre — restauration `on_exit` comprise — tout test concurrent qui
  # lit cette cle lit la valeur de celui-ci. Mesure du 2026-08-17 : la meme forme a tue
  # `Pilot.ApplicationTest` sur une racine de catalogue temporaire qui ne lui appartenait pas, dans
  # le build d'image et pas sur la machine de dev — la collision depend du nombre de coeurs et de
  # l'ordre du seed, donc elle mord la ou ca coute le plus cher.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Fleet.Project.Intensity, as: ProjectIntensity

  @moduletag :tmp_dir

  test "declared: writes a schema-valid .lcars.json relaying the human's level", %{
    tmp_dir: tmp
  } do
    assert :ok =
             ProjectIntensity.write(tmp,
               intensity_level: "C3",
               intensity_justification: "dashboard client multi-year",
               intensity_nature: "web-gui",
               onboarded_by: "architect"
             )

    d = tmp |> Path.join(".lcars.json") |> File.read!() |> Jason.decode!()
    assert d["level"] == "C3"
    assert d["declared_by"] == "architect"
    assert d["nature"] == "web-gui"
    assert d["pipeline_default"] == "brief-gate"
  end

  @tag :tmp_dir
  test "a declaration whose declarer is unknown records UNKNOWN, never a plausible role",
       %{tmp_dir: tmp} do
    # `declared_by` ships in the project repo for good. A caller that declares a level without
    # saying who must not have a role name written on its behalf: that is a permanent false
    # attribution, the same one `MergeAndPromote` refuses when it declines the system token.
    assert :ok = ProjectIntensity.write(tmp, intensity_level: "C3")

    d = tmp |> Path.join(".lcars.json") |> File.read!() |> Jason.decode!()
    assert d["level"] == "C3"
    assert d["declared_by"] == "unknown"

    refute d["declared_by"] in ["architect", "starfleet", "engineer"],
           "a role name was fabricated for a declaration nobody claimed"
  end

  test "undeclared: writes a complete, schema-valid declaration naming the default card — absence recorded, never walled",
       %{tmp_dir: tmp} do
    # Nobody declared: the file is still written, complete and schema-valid, and it NAMES the
    # delegation default card. The card IS the criticality declaration — there is no separate level
    # to assert (crit_quarantine removed it).
    assert :ok = ProjectIntensity.write(tmp, [])

    d = tmp |> Path.join(".lcars.json") |> File.read!() |> Jason.decode!()
    assert d["declared_by"] == "system-default"
    assert d["justification"] =~ "NON DÉCLARÉ"

    # The named card LOADS — an undeclared project can actually be dispatched under it.
    assert is_map(Fleet.Workflow.Loader.load!(d["pipeline_default"])["steps"])
  end

  test "card WITHOUT level: naming a card IS a declaration — level ABSENT, declarer recorded, NO off-matrix noise",
       %{tmp_dir: tmp} do
    # standard-qa claims [C2..C4]: under the old behavior the fabricated C0 default made
    # this off-matrix LOUD — a "disagreement" nobody expressed. A system default can never
    # be off-matrix against a human choice.
    log =
      capture_log(fn ->
        assert :ok =
                 ProjectIntensity.write(tmp,
                   workflow_map: "standard-qa",
                   onboarded_by: "starfleet"
                 )
      end)

    refute log =~ "OFF-MATRIX"

    d = tmp |> Path.join(".lcars.json") |> File.read!() |> Jason.decode!()
    refute Map.has_key?(d, "level")
    # The ACTUAL onboarder, not a role the code picked: starfleet onboards too since the
    # 2026-07-19 reorg, and this field ships in the project's repo for good.
    assert d["declared_by"] == "starfleet"
    assert d["justification"] =~ "carte choisie explicitement"
    assert d["pipeline_default"] == "standard-qa"
  end

  test "malformed FORM is returned (fixing a format is not lying)", %{tmp_dir: tmp} do
    assert {:error, {:invalid_declaration, _}} =
             ProjectIntensity.write(tmp, intensity_level: "C9")
  end

  test "the intensity schema resolves through the SchemaCache authority, not a local pipeline copy",
       %{tmp_dir: tmp} do
    assert :ok = ProjectIntensity.write(tmp, [])

    path =
      Path.join([
        to_string(:code.priv_dir(:lcars_fleet)),
        "cap_profile",
        "schema",
        "intensity-v1.json"
      ])

    key = {ProjectIntensity, :schema, path}

    # A validation that re-reads the file through a private pipeline leaves this key
    # unpopulated — the assertion pins the authority, not just the outcome.
    assert %ExJsonSchema.Schema.Root{} = :persistent_term.get(key, :not_cached),
           "validation did not go through Fleet.SchemaCache (key not populated)"
  end

  test "6-125: an override the loader cannot answer is REFUSED, and the refusal names the cards",
       %{tmp_dir: tmp} do
    # La distinction que le schema ne peut PAS faire : `pipeline_default` est une chaine libre, et
    # un nom de carte n'est unique qu'a l'interieur d'un catalogue. Hors-matrice reste accepte —
    # c'est un arbitrage humain contre ce que la carte dit d'elle-meme ; un nom qui ne CHARGE pas
    # n'est pas un arbitrage, c'est une faute de frappe, et la declaration engraverait une route
    # que personne ne peut bruler.
    log =
      capture_log(fn ->
        assert {:error, {:unknown_card, "wfmap/ghost"}} =
                 ProjectIntensity.write(tmp,
                   intensity_level: "C2",
                   intensity_justification: "x",
                   workflow_map: "wfmap/ghost"
                 )
      end)

    assert log =~ "REFUSED"
    # Un refus qui ne dit pas quoi ecrire a la place renvoie l'operateur par le meme appel.
    assert log =~ "brief-gate"
    refute File.exists?(Path.join(tmp, Fleet.Layout.project_declaration_file()))
  end

  test "6-125: a TICKET-scoped card is refused at declaration too — loadable is not declarable",
       %{tmp_dir: tmp} do
    # `workshop-direct` charge parfaitement : elle est atteinte par le GENRE d'un ticket, et un
    # projet qui la declare routerait CHAQUE ticket par un sceau direct sans jury. La revision de
    # carte refusait deja ce cas ; la declaration l'acceptait.
    assert {:error, {:card_not_project_scoped, "workshop-direct", "ticket"}} =
             ProjectIntensity.write(tmp,
               intensity_level: "C2",
               intensity_justification: "x",
               workflow_map: "workshop-direct"
             )

    refute File.exists?(Path.join(tmp, Fleet.Layout.project_declaration_file()))
  end

  test "6-125: no card declared at all → the catalogue default, never a refusal", %{tmp_dir: tmp} do
    # La contre-partie du refus, et elle porte : la regle ne mord QUE sur un override explicite.
    # Etendue au defaut du catalogue, elle bloquerait tout onboarding sur une boite dont le
    # catalogue ne tient pas ensemble — un catalogue casse se repare la, pas dans chaque projet.
    assert :ok = ProjectIntensity.write(tmp, intensity_level: "C2", intensity_justification: "x")

    d = tmp |> Path.join(".lcars.json") |> File.read!() |> Jason.decode!()
    assert d["pipeline_default"] == "brief-gate"
  end

  test "pipeline_default: declared card read back; absent → default card (quiet); invalid → default + LOUD",
       %{tmp_dir: tmp} do
    proj = Path.join(tmp, "demo")
    File.mkdir_p!(proj)

    :ok =
      ProjectIntensity.write(proj,
        intensity_level: "C2",
        intensity_justification: "x",
        workflow_map: "standard-qa"
      )

    assert "standard-qa" == ProjectIntensity.pipeline_default("fleet/demo", code_root: tmp)

    # absent (legacy project) → the delegation default, no log requirement
    assert "brief-gate" == ProjectIntensity.pipeline_default("fleet/ghost", code_root: tmp)

    # invalid file → default + LOUD warning
    broken = Path.join(tmp, "broken")
    File.mkdir_p!(broken)
    File.write!(Path.join(broken, ".lcars.json"), "{not json")

    log =
      capture_log(fn ->
        assert "brief-gate" ==
                 ProjectIntensity.pipeline_default("fleet/broken", code_root: tmp)
      end)

    assert log =~ "unreadable/invalid"
  end

  test "an invalid declaration records a durable INCIDENT, never only a warning", %{
    tmp_dir: tmp
  } do
    # The never-stall fallback swaps the project's judgment layer (an audit-only project
    # would burn as a producing rail): the substitution must become a durable fact
    # (recurrence → sysadmin issue), not a whisper in a log nobody tails.
    broken = Path.join(tmp, "broken")
    File.mkdir_p!(broken)
    File.write!(Path.join(broken, ".lcars.json"), "{not json")

    me = self()

    log =
      capture_log(fn ->
        assert "brief-gate" ==
                 ProjectIntensity.pipeline_default("fleet/broken",
                   code_root: tmp,
                   incident_fun: fn op, subject, reason, opts ->
                     send(me, {:incident, op, subject, reason, opts})
                     :recorded
                   end
                 )
      end)

    assert_received {:incident, "intensity", "fleet/broken", :declaration_invalid, iopts}
    assert iopts[:reason_detail] =~ ".lcars.json"
    assert log =~ "unreadable/invalid"
  end

  describe "une carte inconnue ICI mais presente AILLEURS — le refus nomme le catalogue" do
    setup do
      tmp = Fleet.TestEnv.tmp_path("carte")
      on_exit(fn -> File.rm_rf!(tmp) end)

      for {cat, cartes} <- [{"aaa", ["commune", "propre-a-aaa"]}, {"bbb", ["commune"]}] do
        root = Path.join(tmp, cat)
        dir = Path.join(root, Fleet.Catalogue.rel(:workflow_maps))
        File.mkdir_p!(dir)
        File.write!(Path.join(root, "catalogue.yaml"), "api_version: 1\nname: #{cat}\n")

        for n <- cartes do
          File.write!(Path.join(dir, "#{n}.yaml"), """
          kind: WorkflowMap
          metadata:
            name: #{n}
          spec:
            jury: []
            ci: ignore
            max_rework_rounds: 1
            steps:
              build:
                role: architect
                needs: []
                inputs:
                  - ticket.body
          """)
        end
      end

      # UNE CARTE DECLAREE PAR LE CATALOGUE ET ILLISIBLE : le fichier existe, donc `canon_names` la
      # liste, mais son enveloppe viole le schema (`ci`, `max_rework_rounds`, `steps` absents), donc
      # `load!` leve. C'est exactement le cas que le `rescue _` d'avant rebaptisait « inconnue ».
      File.write!(
        Path.join([tmp, "bbb", Fleet.Catalogue.rel(:workflow_maps), "cassee.yaml"]),
        "kind: WorkflowMap\nmetadata:\n  name: cassee\nspec:\n  jury: []\n"
      )

      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_install_dirs, [tmp])
      :ok
    end

    test "la carte existe chez le VOISIN : le refus le NOMME, et nomme l'argument manquant" do
      # ⚠ MESURE DU 2026-08-17, transcript d'un starfleet, reproduite au caractere pres : le guichet
      # presente `standard` du catalogue `web-demo`, l'agent la choisit, `project_create` refuse en
      # `{:unknown_card, "standard"}` en enumerant les cartes de `fleet`. Cause : l'appel n'a pas
      # porte `catalogue`, l'org a pris le defaut, et la carte s'est resolue dans le mauvais
      # catalogue. Le message accusait le NOM alors que ce qui manquait etait l'ARGUMENT VOISIN —
      # l'agent en a conclu, raisonnablement et faussement, que « la creation ne sait resoudre que
      # les cartes de fleet ».
      assert {:error, {:card_in_another_catalogue, "propre-a-aaa", ["aaa"]}} =
               Fleet.Project.Intensity.declarable_card("propre-a-aaa", "bbb/un-projet", [])
    end

    test "vraiment inconnue partout : `unknown_card`, comme avant" do
      # Le refus d'origine survit pour ce qu'il decrit VRAIMENT — une faute de frappe. Sans cette
      # separation, le nouveau message dirait « elle existe ailleurs » en listant zero catalogue.
      assert {:error, {:unknown_card, "carte-fantome"}} =
               Fleet.Project.Intensity.declarable_card("carte-fantome", "bbb/un-projet", [])
    end

    test "la carte de SON catalogue passe — le refus ne mord pas sur le cas nominal" do
      assert :ok = Fleet.Project.Intensity.declarable_card("commune", "bbb/un-projet", [])
    end

    # ─── LE MEME AIGUILLAGE, MAIS PAR LA PORTE QUE LES APPELANTS EMPRUNTENT ─────────────────────
    #
    # Les trois tests ci-dessus interrogent `declarable_card/3`, ou le depot est un ARGUMENT qu'on ne
    # peut pas omettre. `write/2`, lui, le lit dans ses options — et c'est cette lecture-la que les
    # quatre portes d'`Onboard` ne nourrissaient pas. Epingler la resolution sur la fonction dont la
    # signature protege deja l'appelant, c'est mesurer le cas qui ne casse jamais.
    test "write/2 resout la carte dans le catalogue DU DEPOT qu'on lui nomme" do
      tmp = Fleet.TestEnv.tmp_path("wr")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      assert :ok =
               Fleet.Project.Intensity.write(tmp,
                 workflow_map: "propre-a-aaa",
                 repo: "aaa/un-projet",
                 onboarded_by: "starfleet"
               )
    end

    test "write/2 REFUSE la carte du voisin — et le refus nomme le catalogue qui la porte" do
      tmp = Fleet.TestEnv.tmp_path("wr")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      assert {:error, {:card_in_another_catalogue, "propre-a-aaa", ["aaa"]}} =
               Fleet.Project.Intensity.write(tmp,
                 workflow_map: "propre-a-aaa",
                 repo: "bbb/un-projet",
                 onboarded_by: "starfleet"
               )

      # RIEN N'EST ECRIT SUR UN REFUS : la declaration est le contrat du projet, et une carte que le
      # projet ne peut pas charger y serait un mensonge committe.
      refute File.exists?(Path.join(tmp, Fleet.Layout.project_declaration_file()))
    end

    test "sans depot, write/2 resout dans le catalogue RACINE — le silence que les appelants ont mange" do
      # ⚠ CE TEST N'EPINGLE PAS UN BON COMPORTEMENT, IL EPINGLE LE PIEGE. `write/2` ne peut pas
      # exiger `:repo` : 38 appels le declarent sans, et prennent la racine A BON DROIT. Sa
      # tolerance est donc legitime ICI et fatale chez un appelant qui tient le depot et l'oublie —
      # d'ou l'entonnoir a argument positionnel dans `Onboard`. Le jour ou quelqu'un voudra faire
      # refuser `write/2`, ce test lui dira ce qu'il casse.
      tmp = Fleet.TestEnv.tmp_path("wr")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      # LA PREUVE EST DANS LA LISTE `available:`, PAS DANS LE TERME D'ERREUR. Les deux appels
      # refusent, et de la meme FORME — ce qui differe est le catalogue consulte, et c'est
      # exactement ce que le transcript de l'architecte montrait : deux lignes de journal, deux
      # listes, un seul appel. Un temoin qui ne regarderait que le terme passerait au vert sur le
      # bug qu'il est cense tenir.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:card_in_another_catalogue, "propre-a-aaa", ["aaa"]}} =
                   Fleet.Project.Intensity.write(tmp,
                     workflow_map: "propre-a-aaa",
                     onboarded_by: "starfleet"
                   )
        end)

      # La RACINE canon, pas le catalogue d'un projet : c'est la que l'absence de `:repo` envoie.
      assert log =~ "brief-gate"
      refute log =~ "available: cassee, commune"
    end

    test "declaree mais ILLISIBLE : `card_load_failed`, PAS `unknown_card` — BL-6-116" do
      # ⚠ LE POINT DE TOUT C1. Le corps etait un `rescue _ ->` qui rebaptisait chaque levee de
      # `load!` en « carte inconnue » : nom non-slug, absence de l'image, YAML illisible, schema
      # invalide, graphe invalide, `spec.ci` manquant — six causes, un seul terme. Mesure : un
      # `{:unknown_card, "brief-gate"}` intermittent sur une carte canon qui existe, que douze seeds
      # pleins n'ont pas reproduit parce que la preuve etait detruite a la source.
      #
      # `cassee` EST dans le catalogue de `bbb` — c'est le fichier ecrit par le setup. La confondre
      # avec une absence est le bug ; l'assertion negative ci-dessous est donc la moitie qui compte.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:card_load_failed, "cassee", message}} =
                   Fleet.Project.Intensity.declarable_card("cassee", "bbb/un-projet", [])

          assert message =~ "schema"
        end)

      # Le journal NOMME la classe d'exception et l'endroit consulte : au prochain flake, la cause
      # est ecrite. Et il est en `error` — une carte declaree qui ne charge pas est un catalogue
      # casse, pas un refus de routine.
      assert log =~ "FAILED TO LOAD"
      assert log =~ "[error]"

      refute match?(
               {:error, {:unknown_card, _}},
               Fleet.Project.Intensity.declarable_card("cassee", "bbb/un-projet", [])
             )
    end
  end
end
