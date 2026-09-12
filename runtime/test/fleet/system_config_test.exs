defmodule Fleet.SystemConfigTest do
  @moduledoc """
  Defaults are silent for a missing settings file; malformed content and unknown keys are diagnosed.
  """
  use ExUnit.Case, async: true

  alias Fleet.SystemConfig

  @moduletag :tmp_dir

  # capture_log can include concurrent modules. Assert absence of this module's prefix,
  # not an empty global log, so unrelated activity cannot fail the silence test.
  test "absent file → defaults, in SILENCE (a fresh container is no event)", %{tmp_dir: dir} do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert %{conflict_engine: false} = SystemConfig.read(Path.join(dir, "nope.json"))
      end)

    refute log =~ "SystemConfig"
  end

  test "conflict_engine: true → armed", %{tmp_dir: dir} do
    p = Path.join(dir, "fleet.json")
    File.write!(p, ~s({"conflict_engine": true}))
    assert %{conflict_engine: true} = SystemConfig.read(p)
  end

  test "malformed JSON → defaults, OUT LOUD", %{tmp_dir: dir} do
    p = Path.join(dir, "fleet.json")
    File.write!(p, "{oops")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert %{conflict_engine: false} = SystemConfig.read(p)
      end)

    assert log =~ "not a JSON object"
  end

  test "a misspelled knob is NAMED, never silently inert", %{tmp_dir: dir} do
    p = Path.join(dir, "fleet.json")
    File.write!(p, ~s({"conflict_engin": true}))

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert %{conflict_engine: false} = SystemConfig.read(p)
      end)

    assert log =~ "unknown key"
    assert log =~ "conflict_engin"
  end

  test "a non-boolean value falls back to the default, and says so", %{tmp_dir: dir} do
    p = Path.join(dir, "fleet.json")
    File.write!(p, ~s({"conflict_engine": "yes"}))

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert %{conflict_engine: false} = SystemConfig.read(p)
      end)

    assert log =~ "must be true or false"
  end
end
