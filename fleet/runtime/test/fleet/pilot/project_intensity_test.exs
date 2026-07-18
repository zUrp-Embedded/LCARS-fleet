defmodule Fleet.Pilot.ProjectIntensityTest do
  @moduledoc """
  The criticality declaration: always written complete and schema-valid; the human's
  level RELAYED (never agent-assessed); absence recorded honestly (undeclared C0), never
  fabricated and never walled; the burn reads the declared card with quiet/loud fallbacks.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Fleet.Pilot.ProjectIntensity

  @moduletag :tmp_dir

  test "declared: writes a schema-valid intensity.json relaying the human's level", %{tmp_dir: tmp} do
    assert :ok =
             ProjectIntensity.write(tmp,
               intensity_level: "C3",
               intensity_justification: "dashboard client multi-year",
               intensity_nature: "web-gui"
             )

    d = tmp |> Path.join("intensity.json") |> File.read!() |> Jason.decode!()
    assert d["level"] == "C3"
    assert d["declared_by"] == "architect"
    assert d["nature"] == "web-gui"
    assert d["pipeline_default"] == "brief-gate"
  end

  test "undeclared: an HONEST C0 default, explicitly marked — absence recorded, never fabricated",
       %{tmp_dir: tmp} do
    assert :ok = ProjectIntensity.write(tmp, [])

    d = tmp |> Path.join("intensity.json") |> File.read!() |> Jason.decode!()
    assert d["level"] == "C0"
    assert d["declared_by"] == "system-default"
    assert d["justification"] =~ "NON DÉCLARÉ"
  end

  test "card WITHOUT level: naming a card IS a declaration — level ABSENT, declared_by architect, NO off-matrix noise",
       %{tmp_dir: tmp} do
    # standard-qa claims [C2..C4]: under the old behavior the fabricated C0 default made
    # this off-matrix LOUD — a "disagreement" nobody expressed. A system default can never
    # be off-matrix against a human choice.
    log =
      capture_log(fn ->
        assert :ok = ProjectIntensity.write(tmp, workflow_map: "standard-qa")
      end)

    refute log =~ "OFF-MATRIX"

    d = tmp |> Path.join("intensity.json") |> File.read!() |> Jason.decode!()
    refute Map.has_key?(d, "level")
    assert d["declared_by"] == "architect"
    assert d["justification"] =~ "carte choisie explicitement"
    assert d["pipeline_default"] == "standard-qa"
  end

  test "malformed FORM is returned (fixing a format is not lying)", %{tmp_dir: tmp} do
    assert {:error, {:invalid_declaration, _}} =
             ProjectIntensity.write(tmp, intensity_level: "C9")
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
    d = tmp |> Path.join("intensity.json") |> File.read!() |> Jason.decode!()
    assert d["pipeline_default"] == "brief-gate"
  end

  test "pipeline_default: declared card read back; absent → default card (quiet); invalid → default + LOUD",
       %{tmp_dir: tmp} do
    proj = Path.join(tmp, "demo")
    File.mkdir_p!(proj)
    :ok = ProjectIntensity.write(proj, intensity_level: "C2", intensity_justification: "x", workflow_map: "standard-qa")
    assert "standard-qa" == ProjectIntensity.pipeline_default("fleet/demo", projects_root: tmp)

    # absent (legacy project) → the delegation default, no log requirement
    assert "brief-gate" == ProjectIntensity.pipeline_default("fleet/ghost", projects_root: tmp)

    # invalid file → default + LOUD warning
    broken = Path.join(tmp, "broken")
    File.mkdir_p!(broken)
    File.write!(Path.join(broken, "intensity.json"), "{not json")

    log =
      capture_log(fn ->
        assert "brief-gate" == ProjectIntensity.pipeline_default("fleet/broken", projects_root: tmp)
      end)

    assert log =~ "unreadable/invalid"
  end
end
