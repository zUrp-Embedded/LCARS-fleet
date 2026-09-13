defmodule Fleet.Project.DeclarationTest do
  @moduledoc """
  Tests declaration composition, catalogue selection and legacy read fallbacks.
  Explicit incident callbacks are observed as calls, not durable incident storage.
  """
  # Mutates the global catalogue_install_dirs setting; restoration does not isolate concurrent readers.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Fleet.Project.Declaration, as: ProjectDeclaration

  @moduletag :tmp_dir

  test "level/nature opts are IGNORED — the card is the declaration, no decorative keys written",
       %{
         tmp_dir: tmp
       } do
    # Retired level/nature options must not reappear in the declaration.
    assert :ok =
             ProjectDeclaration.write(tmp,
               workflow_map: "standard-qa",
               intensity_level: "C3",
               intensity_nature: "web-gui",
               justification: "dashboard client multi-year",
               onboarded_by: "architect"
             )

    d = tmp |> Path.join(".lcars.json") |> File.read!() |> Jason.decode!()
    refute Map.has_key?(d, "level")
    refute Map.has_key?(d, "nature")
    assert d["declared_by"] == "architect"
    assert d["pipeline_default"] == "standard-qa"
  end

  @tag :tmp_dir
  test "a declaration whose declarer is unknown records UNKNOWN, never a plausible role",
       %{tmp_dir: tmp} do
    # Missing attribution must remain unknown rather than inventing a role name.
    assert :ok = ProjectDeclaration.write(tmp, workflow_map: "standard-qa")

    d = tmp |> Path.join(".lcars.json") |> File.read!() |> Jason.decode!()
    assert d["pipeline_default"] == "standard-qa"
    assert d["declared_by"] == "unknown"

    refute d["declared_by"] in ["architect", "starfleet", "engineer"],
           "a role name was fabricated for a declaration nobody claimed"
  end

  test "undeclared: writes a complete, schema-valid declaration naming the default card — absence recorded, never walled",
       %{tmp_dir: tmp} do
    # Absence still writes a record identifying the system default.
    assert :ok = ProjectDeclaration.write(tmp, [])

    d = tmp |> Path.join(".lcars.json") |> File.read!() |> Jason.decode!()
    assert d["declared_by"] == "system-default"
    assert d["justification"] =~ "NON DÉCLARÉ"

    # The named card LOADS — an undeclared project can actually be dispatched under it.
    assert is_map(Fleet.Workflow.Loader.load!(d["pipeline_default"])["steps"])
  end

  test "naming a card IS a declaration — level ABSENT, real onboarder recorded", %{tmp_dir: tmp} do
    assert :ok =
             ProjectDeclaration.write(tmp,
               workflow_map: "standard-qa",
               onboarded_by: "starfleet"
             )

    d = tmp |> Path.join(".lcars.json") |> File.read!() |> Jason.decode!()
    refute Map.has_key?(d, "level")
    # Preserve caller-supplied attribution without substituting the architect role.
    assert d["declared_by"] == "starfleet"
    assert d["justification"] =~ "Carte choisie explicitement"
    assert d["pipeline_default"] == "standard-qa"
  end

  test "the declaration schema resolves through the SchemaCache authority, not a local pipeline copy",
       %{tmp_dir: tmp} do
    assert :ok = ProjectDeclaration.write(tmp, [])

    path =
      Path.join([
        to_string(:code.priv_dir(:lcars_fleet)),
        "cap_profile",
        "schema",
        "declaration.json"
      ])

    key = {ProjectDeclaration, :schema, path}

    # Check that the shared schema cache key is populated; earlier calls can also populate it.
    assert %ExJsonSchema.Schema.Root{} = :persistent_term.get(key, :not_cached),
           "validation did not go through Fleet.SchemaCache (key not populated)"
  end

  test "6-125: an override the loader cannot answer is REFUSED, and the refusal names the cards",
       %{tmp_dir: tmp} do
    # Free-string schema validation alone cannot resolve a card in its catalogue.
    log =
      capture_log(fn ->
        assert {:error, {:unknown_card, "wfmap/ghost"}} =
                 ProjectDeclaration.write(tmp,
                   justification: "x",
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
    # A loadable ticket-scoped card is not a valid project default.
    assert {:error, {:card_not_project_scoped, "workshop-direct", "ticket"}} =
             ProjectDeclaration.write(tmp,
               justification: "x",
               workflow_map: "workshop-direct"
             )

    refute File.exists?(Path.join(tmp, Fleet.Layout.project_declaration_file()))
  end

  test "6-125: no card declared at all → the catalogue default, never a refusal", %{tmp_dir: tmp} do
    # Positive control: absent explicit override retains the catalogue default.
    assert :ok = ProjectDeclaration.write(tmp, justification: "x")

    d = tmp |> Path.join(".lcars.json") |> File.read!() |> Jason.decode!()
    assert d["pipeline_default"] == "brief-gate"
  end

  test "pipeline_default: declared card read back; absent → default card (quiet); invalid → default + LOUD",
       %{tmp_dir: tmp} do
    proj = Path.join(tmp, "demo")
    File.mkdir_p!(proj)

    :ok =
      ProjectDeclaration.write(proj,
        justification: "x",
        workflow_map: "standard-qa"
      )

    assert "standard-qa" == ProjectDeclaration.pipeline_default("fleet/demo", code_root: tmp)

    # absent (legacy project) → the delegation default, no log requirement
    assert "brief-gate" == ProjectDeclaration.pipeline_default("fleet/ghost", code_root: tmp)

    # invalid file → default + LOUD warning
    broken = Path.join(tmp, "broken")
    File.mkdir_p!(broken)
    File.write!(Path.join(broken, ".lcars.json"), "{not json")

    log =
      capture_log(fn ->
        assert "brief-gate" ==
                 ProjectDeclaration.pipeline_default("fleet/broken", code_root: tmp)
      end)

    assert log =~ "unreadable/invalid"
  end

  test "an invalid declaration records a durable INCIDENT, never only a warning", %{
    tmp_dir: tmp
  } do
    # Observe the incident callback alongside fallback; this stub does not persist an incident.
    broken = Path.join(tmp, "broken")
    File.mkdir_p!(broken)
    File.write!(Path.join(broken, ".lcars.json"), "{not json")

    me = self()

    log =
      capture_log(fn ->
        assert "brief-gate" ==
                 ProjectDeclaration.pipeline_default("fleet/broken",
                   code_root: tmp,
                   incident_fun: fn op, subject, reason, opts ->
                     send(me, {:incident, op, subject, reason, opts})
                     :recorded
                   end
                 )
      end)

    assert_received {:incident, "declaration", "fleet/broken", :declaration_invalid, iopts}
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

      # Listed filename with an invalid envelope distinguishes load failure from absence.
      File.write!(
        Path.join([tmp, "bbb", Fleet.Catalogue.rel(:workflow_maps), "cassee.yaml"]),
        "kind: WorkflowMap\nmetadata:\n  name: cassee\nspec:\n  jury: []\n"
      )

      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_install_dirs, [tmp])
      :ok
    end

    test "la carte existe chez le VOISIN : le refus le NOMME, et nomme l'argument manquant" do
      # A card offered by another catalogue needs a catalogue-selection diagnostic.
      assert {:error, {:card_in_another_catalogue, "propre-a-aaa", ["aaa"]}} =
               ProjectDeclaration.declarable_card("propre-a-aaa", "bbb/un-projet", [])
    end

    test "vraiment inconnue partout : `unknown_card`, comme avant" do
      # Truly absent cards must not be reported as available elsewhere.
      assert {:error, {:unknown_card, "carte-fantome"}} =
               ProjectDeclaration.declarable_card("carte-fantome", "bbb/un-projet", [])
    end

    test "la carte de SON catalogue passe — le refus ne mord pas sur le cas nominal" do
      assert :ok = ProjectDeclaration.declarable_card("commune", "bbb/un-projet", [])
    end

    # Exercise write/2's repo option, not just declarable_card/3's positional repo.
    test "write/2 resout la carte dans le catalogue DU DEPOT qu'on lui nomme" do
      tmp = Fleet.TestEnv.tmp_path("wr")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      assert :ok =
               ProjectDeclaration.write(tmp,
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
               ProjectDeclaration.write(tmp,
                 workflow_map: "propre-a-aaa",
                 repo: "bbb/un-projet",
                 onboarded_by: "starfleet"
               )

      # Refusal must leave no declaration file.
      refute File.exists?(Path.join(tmp, Fleet.Layout.project_declaration_file()))
    end

    test "sans depot, write/2 resout dans le catalogue RACINE — le silence que les appelants ont mange" do
      # Omitting repo intentionally retains default-root behavior; callers holding a repo must pass it.
      tmp = Fleet.TestEnv.tmp_path("wr")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      # Error shapes are identical; the logged available list distinguishes consulted catalogues.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:card_in_another_catalogue, "propre-a-aaa", ["aaa"]}} =
                   ProjectDeclaration.write(tmp,
                     workflow_map: "propre-a-aaa",
                     onboarded_by: "starfleet"
                   )
        end)

      # La RACINE canon, pas le catalogue d'un projet : c'est la que l'absence de `:repo` envoie.
      assert log =~ "brief-gate"
      refute log =~ "available: cassee, commune"
    end

    test "declaree mais ILLISIBLE : `card_load_failed`, PAS `unknown_card` — BL-6-116" do
      # A listed but schema-invalid card must retain the load failure, not become unknown_card.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:card_load_failed, "cassee", message}} =
                   ProjectDeclaration.declarable_card("cassee", "bbb/un-projet", [])

          assert message =~ "schema"
        end)

      # Keep an error-level diagnostic naming the load failure.
      assert log =~ "FAILED TO LOAD"
      assert log =~ "[error]"

      refute match?(
               {:error, {:unknown_card, _}},
               ProjectDeclaration.declarable_card("cassee", "bbb/un-projet", [])
             )
    end
  end
end
