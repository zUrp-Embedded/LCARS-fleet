defmodule Fleet.SystemConfigTest do
  @moduledoc """
  A1 — the box-wide admin settings file (`/etc/lcars/fleet.json`). Both failure directions are
  deliberate and PINNED: absent = defaults in silence (the nominal state of a fresh box);
  present-but-broken = defaults OUT LOUD (an admin who wrote a file expects it to act).
  """
  use ExUnit.Case, async: true

  alias Fleet.SystemConfig

  @moduletag :tmp_dir

  test "absent file → defaults, in SILENCE (a fresh box is not an event)", %{tmp_dir: dir} do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert %{conflict_engine: false} = SystemConfig.read(Path.join(dir, "nope.json"))
      end)

    assert log == ""
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
