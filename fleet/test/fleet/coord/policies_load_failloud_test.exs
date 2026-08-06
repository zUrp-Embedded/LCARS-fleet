defmodule Fleet.Coord.PoliciesLoadFailloudTest do
  # async: false — mutates the global :policies_path config.
  use ExUnit.Case, async: false

  alias Fleet.Coord.Policies

  setup do
    prev = Application.get_env(:fleet_coord, :policies_path)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:fleet_coord, :policies_path, prev),
        else: Application.delete_env(:fleet_coord, :policies_path)
    end)

    :ok
  end

  # F-051 (Pattern A crash-boot, F025 revision): a missing/malformed coord-policies.yaml does NOT
  # degrade into an empty table ("coord green but every decision/escalation :not_found"). A broken
  # deploy artifact → raise at boot. The raise precedes the `:persistent_term.put` → the state loaded
  # at boot stays intact (the following tests keep a valid table).
  test "F-051: missing policies → raise (no more DEGRADED empty table)" do
    Application.put_env(:fleet_coord, :policies_path, "/nonexistent/coord-policies-xyz.yaml")

    assert_raise RuntimeError, ~r/missing\/unreadable/, fn ->
      Policies.init_policies!()
    end
  end

  test "F-051: malformed policies (not a map) → raise" do
    tmp = Path.join(System.tmp_dir!(), "coord-pol-#{System.unique_integer([:positive])}.yaml")
    File.write!(tmp, "- just\n- a\n- list\n")
    on_exit(fn -> File.rm(tmp) end)

    Application.put_env(:fleet_coord, :policies_path, tmp)

    assert_raise RuntimeError, ~r/malformed/, fn ->
      Policies.init_policies!()
    end
  end

  # Finding 13: a valid YAML MAP that is structurally INVALID vs `coord-policies-v1.json` (here a
  # mapping without `action`) must FAIL-FAST at boot — a "is a map" check alone lets it through, and
  # the schema validation must run inside `init_policies!/0`, not only in test. The raise precedes the
  # `:persistent_term.put` → the table loaded at boot stays intact (the other tests keep a valid table).
  test "Finding 13: valid map but INVALID vs schema (mapping without action) → fail-loud raise" do
    tmp = Path.join(System.tmp_dir!(), "coord-pol-bad-#{System.unique_integer([:positive])}.yaml")
    File.write!(tmp, "mappings:\n  \"audit.proven\":\n    escalation_path: []\n")
    on_exit(fn -> File.rm(tmp) end)

    Application.put_env(:fleet_coord, :policies_path, tmp)

    assert_raise RuntimeError, ~r/INVALID vs coord-policies-v1\.json/, fn ->
      Policies.init_policies!()
    end
  end
end
