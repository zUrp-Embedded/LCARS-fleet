defmodule Fleet.SystemConfigTest do
  @moduledoc """
  A1 — the container-wide admin settings file (`/etc/lcars/fleet.json`). Both failure directions are
  deliberate and PINNED: absent = defaults in silence (the nominal state of a fresh container);
  present-but-broken = defaults OUT LOUD (an admin who wrote a file expects it to act).
  """
  use ExUnit.Case, async: true

  alias Fleet.SystemConfig

  @moduletag :tmp_dir

  # ⚠ ON NIE LE BRUIT DE CE MODULE, PAS TOUT BRUIT — `capture_log` LIT LE LOGGER GLOBAL. Cette
  # assertion etait `assert log == ""`, dans un cas `async: true` : elle exigeait donc que RIEN dans
  # toute la suite n'ecrive pendant ces quelques microsecondes. Mesure du 2026-08-20, gate rouge sur
  # 3118 tests : la capture avait ramasse une ligne de `ProjectOnboard` d'un test voisin — un module
  # qui n'a rien a voir avec celui-ci. Ce n'est pas un flake a retenter, c'est une assertion sur un
  # objet PARTAGE, et la reponse n'est pas de passer le cas en `async: false` (ca reduirait la
  # fenetre sans fermer la course, et paierait en temps de suite ce qui reste faux).
  #
  # Toutes les sorties de ce module portent son prefixe : le nier est exactement le contrat annonce
  # — « un conteneur neuf n'est pas un evenement » — et c'est vrai quoi qu'il tourne a cote.
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
