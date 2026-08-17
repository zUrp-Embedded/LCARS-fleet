defmodule Fleet.Project.IntensityTest do
  @moduledoc """
  The criticality declaration: always written complete and schema-valid; the human's
  level RELAYED (never agent-assessed); absence recorded honestly (undeclared C0), never
  fabricated and never walled; the burn reads the declared card with quiet/loud fallbacks.
  """
  use ExUnit.Case, async: true

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
    # attribution, the same one `GatekeeperSeal` refuses when it declines the system token.
    assert :ok = ProjectIntensity.write(tmp, intensity_level: "C3")

    d = tmp |> Path.join(".lcars.json") |> File.read!() |> Jason.decode!()
    assert d["level"] == "C3"
    assert d["declared_by"] == "unknown"

    refute d["declared_by"] in ["architect", "starfleet", "engineer"],
           "a role name was fabricated for a declaration nobody claimed"
  end

  test "undeclared: the level silence buys, explicitly marked — absence recorded, never fabricated",
       %{tmp_dir: tmp} do
    # It was C0, the BOTTOM of the scale, and that is a claim: C0 is the disposable posture and
    # nobody said the work was disposable. Silence buys "we do not know, therefore we judge" — and
    # it is also the only reading under which the catalogue holds together, since its `default_card`
    # declares a matrix that starts at C1.
    #
    # Read from its owner rather than restated: a test that spells the constant is a test that
    # keeps asserting yesterday's default.
    assert :ok = ProjectIntensity.write(tmp, [])

    d = tmp |> Path.join(".lcars.json") |> File.read!() |> Jason.decode!()
    assert d["level"] == ProjectIntensity.undeclared_level()
    assert d["declared_by"] == "system-default"
    assert d["justification"] =~ "NON DÉCLARÉ"

    # And it is ON-MATRIX for the card an undeclared project actually receives — the pairing the
    # boot guard now refuses to let drift.
    card = Fleet.Workflow.Loader.load!(d["pipeline_default"])
    assert ProjectIntensity.undeclared_level() in card["applicable_intensity"]
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

  test "off-matrix explicit override: ACCEPTED + logged LOUD (the human has the last word)",
       %{tmp_dir: tmp} do
    # audit-only claims [C0..C4]... use a card whose matrix excludes the level: brief-gate
    # claims [C1..C4] → C0 + brief-gate override is off-matrix.
    log =
      capture_log(fn ->
        assert :ok =
                 ProjectIntensity.write(tmp,
                   intensity_level: "C0",
                   intensity_justification: "PoC assumé sur la carte lourde",
                   workflow_map: "brief-gate"
                 )
      end)

    assert log =~ "OFF-MATRIX"
    d = tmp |> Path.join(".lcars.json") |> File.read!() |> Jason.decode!()
    assert d["pipeline_default"] == "brief-gate"
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
      tmp = Path.join(System.tmp_dir!(), "carte-#{System.unique_integer([:positive])}")
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
  end
end
