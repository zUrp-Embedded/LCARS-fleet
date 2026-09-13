defmodule Fleet.EnvParseTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Fleet.EnvParse

  describe "port/2" do
    test "valid (bounds inclusive)" do
      assert EnvParse.port("P", "8080") == 8080
      assert EnvParse.port("P", "1") == 1
      assert EnvParse.port("P", "65535") == 65_535
    end

    test "SOC-CONF-001: out-of-domain / non-integer → raise (boot refused)" do
      for bad <- ["0", "65536", "-1", "abc", "80x", ""] do
        assert_raise RuntimeError, ~r/boot refused/, fn -> EnvParse.port("P", bad) end
      end
    end
  end

  describe "positive_ms/2 + count/2" do
    test "positive_ms: > 0; ≤ 0 → raise" do
      assert EnvParse.positive_ms("I", "500") == 500
      assert_raise RuntimeError, fn -> EnvParse.positive_ms("I", "0") end
      assert_raise RuntimeError, fn -> EnvParse.positive_ms("I", "-5") end
    end

    test "count: ≥ 0; negative → raise" do
      assert EnvParse.count("C", "0") == 0
      assert EnvParse.count("C", "3") == 3
      assert_raise RuntimeError, fn -> EnvParse.count("C", "-1") end
    end
  end

  describe "bool/3" do
    test "SOC-CONF-002: recognized true/false forms (case-insensitive, trimmed)" do
      for v <- ~w(true 1 yes on TRUE Yes ON), do: assert(EnvParse.bool("B", v, false) == true)
      for v <- ~w(false 0 no off FALSE No OFF), do: assert(EnvParse.bool("B", v, true) == false)
      assert EnvParse.bool("B", " true ", false) == true
    end

    test "nil (env not set) → default" do
      assert EnvParse.bool("B", nil, true) == true
      assert EnvParse.bool("B", nil, false) == false
    end

    test "SOC-CONF-002: UNKNOWN value → default + LOUD warning (never a silence)" do
      log =
        capture_log(fn ->
          assert EnvParse.bool("B", "flase", true) == true
        end)

      assert log =~ "not a recognized boolean"
    end
  end

  describe "bool!/3 — the strict form for safety flags" do
    test "recognized forms and unset behave like bool/3" do
      assert EnvParse.bool!("B", "false", true) == false
      assert EnvParse.bool!("B", "ON", false) == true
      assert EnvParse.bool!("B", nil, true) == true
    end

    test "UNKNOWN value → raise (a typo on a reduction-of-effects switch stops the boot)" do
      # bool/3's warn-and-default is fail-open exactly when the operator asked for FEWER
      # effects: a typo'd `flase` became a FULL boot. The strict form refuses instead.
      assert_raise ArgumentError, ~r/refusing to boot/, fn ->
        EnvParse.bool!("LCARS_BOOT_PERMANENT_AT_START", "flase", true)
      end
    end
  end

  describe "path/2" do
    test "normalizes (~ / relative → absolute)" do
      assert EnvParse.path("PA", "/a/b") == "/a/b"
      assert EnvParse.path("PA", "~/x") == Path.expand("~/x")
    end

    test "SOC-CONF-003: `..` (traversal) / control char → raise (boot refused)" do
      assert_raise RuntimeError, ~r/traversal/, fn -> EnvParse.path("PA", "/a/../etc") end
      assert_raise RuntimeError, ~r/control char/, fn -> EnvParse.path("PA", "/a\0b") end
    end
  end
end
