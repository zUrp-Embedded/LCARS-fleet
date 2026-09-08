defmodule Fleet.Spawner.CanonProofTest do
  @moduledoc """
  The boot-time spawn-readiness proof: the SHIPPED canon must prove entirely (defaults
  and every optional modop of every role), and a broken deploy must refuse loud with
  the role and the failing composition named — before readiness, never at the first
  post-ready spawn.
  """
  # async: false — proves against the REAL priv catalogue through the global env
  # (other suites swap :lcars_fleet, :cap_profile_root_dir globally).
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Fleet.Spawner.CanonProof
  alias Fleet.Test.CatalogueIsolation

  test "the shipped canon proves spawn-ready — every role, defaults + each optional" do
    log = capture_log(fn -> assert :ok = CanonProof.prove_all!() end)

    # The COUNT matters: "proven" over zero roles would be the vacuous pass this module
    # exists to refuse. The shipped canon carries 7 roles — pin the floor, not the exact
    # number (a new canon role must not break this test).
    assert [_, count] = Regex.run(~r/CanonProof: (\d+) canon roles proven/, log)
    assert String.to_integer(count) >= 7
  end

  @tag :tmp_dir
  test "an EMPTY catalogue is a refusal — nothing to prove means nothing can spawn", %{
    tmp_dir: tmp
  } do
    CatalogueIsolation.isolate!(tmp)

    assert_raise RuntimeError, ~r/EMPTY/, fn -> CanonProof.prove_all!() end
  end

  @tag :tmp_dir
  test "a canon role composed onto a missing modop bundle is refused BEFORE readiness", %{
    tmp_dir: tmp
  } do
    # A schema-valid profile whose default modop has no bundle: resolve accepts the
    # STRUCTURE, the SP composition is what breaks — exactly the class of fault the old
    # boot never exercised (first seen at spawn, post-ready).
    File.write!(Path.join(tmp, "ghostly.yaml"), """
    kind: CapabilityProfile
    metadata:
      name: ghostly
      containment: bwrap
    spec:
      invocation:
        lifetime_scope: pipe
      modop_set:
        default: [ghost-modop]
        optional: []
        incompatible: []
    """)

    CatalogueIsolation.isolate!(tmp)

    assert_raise RuntimeError, ~r/"ghostly".*NOT.*spawn-ready/s, fn ->
      CanonProof.prove_all!()
    end
  end

  @tag :tmp_dir
  test "an unenumerable catalogue is a refusal, never a vacuous pass", %{tmp_dir: tmp} do
    missing = Path.join(tmp, "nowhere")
    CatalogueIsolation.isolate!(missing)

    assert_raise RuntimeError, ~r/not enumerable/, fn ->
      CanonProof.prove_all!()
    end
  end
end
