defmodule Fleet.Spawner.CanonProofTest do
  @moduledoc """
  Checks the shipped catalogue and refusal of empty or broken catalogue fixtures.
  """
  # Serial because catalogue selection uses global application configuration.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Fleet.Spawner.CanonProof
  alias Fleet.Test.CatalogueIsolation

  test "the shipped canon proves spawn-ready — every role, defaults + each optional" do
    log = capture_log(fn -> assert :ok = CanonProof.prove_all!() end)

    # Use a floor so adding a shipped role does not invalidate this assertion.
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
    # The fixture names a default modop whose bundle is absent.
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
