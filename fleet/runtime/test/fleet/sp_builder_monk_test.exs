defmodule Fleet.SPBuilder.MonkTest do
  @moduledoc """
  `Fleet.SPBuilder.resolve_monk_injection/2` (DN ring2/fleet_memory.md L478:
  inject registry persona_hint+corpus_paths into the monk SP). Pure, real canon.
  The compose/3 regression (byte-identical additive for non-monk) is covered by
  the full suite (mix test). `async: true`.
  """
  use ExUnit.Case, async: true

  # FROZEN (BL — Memory-X frozen): this test's fixtures = the real monk cap-profiles
  # (`cap-profiles/monks/alpha.yaml`…), ARCHIVED in `priv/cap_profile/canon/_frozen-monks/` (Memory-X out
  # of the boot loop: must be per-project + system-wide under lcars, not per-fleet). The
  # `resolve_monk_injection/2` code stays in place; re-enable these tests (and re-point the
  # fixtures) when Memory-X is re-homed. cf. work/backlog.md.
  @moduletag skip:
               "Memory-X frozen (BL) — monk cap-profiles archived; re-enable at the per-project re-home"

  alias Fleet.SPBuilder

  # R0.8-brick1: canon root in-repo (R0.7 reabsorption), not the doctrine path
  # 05_data-canon/... (nonexistent in a standard install).
  @monks_dir Application.app_dir(:lcars_fleet, "priv/cap_profile/canon/cap-profiles/monks")

  defp monk_cp(instance) do
    %Fleet.CapProfile{
      kind: "CapabilityProfile",
      metadata: %{"name" => "monk-alpha-#{instance}"},
      spec: %{
        "knowledge" => %{
          "monk_registry" => "alpha.yaml",
          "monk_instance" => instance
        }
      }
    }
  end

  defp plain_cp do
    %Fleet.CapProfile{
      kind: "CapabilityProfile",
      metadata: %{"name" => "engineer"},
      spec: %{"knowledge" => %{"skills" => ["x"]}}
    }
  end

  test "real canon monk (vision-doctrine) → persona_hint + corpus_paths from the registry" do
    assert {:ok, %{persona_hint: ph, corpus_paths: cps}} =
             SPBuilder.resolve_monk_injection(monk_cp("vision-doctrine"),
               monk_registry_root: @monks_dir
             )

    assert ph =~ "gardien de la doctrine fondatrice"
    assert "00_doctrine/moon-shot-ref/#00_vision/" in cps
    assert length(cps) == 3
  end

  test "real canon monk (archive) → distinct entry" do
    assert {:ok, %{persona_hint: ph, corpus_paths: [cp]}} =
             SPBuilder.resolve_monk_injection(monk_cp("archive"),
               monk_registry_root: @monks_dir
             )

    assert ph =~ "archives moon-shot"
    assert cp == "00_doctrine/moon-shot-ref/#99_archive/"
  end

  test "non-monk cap-profile → :not_a_monk (compose stays byte-identical)" do
    assert :not_a_monk = SPBuilder.resolve_monk_injection(plain_cp(), [])
  end

  test "monk_instance absent from the registry → {:error,{:monk_instance_not_found,_}}" do
    assert {:error, {:monk_instance_not_found, "ghost"}} =
             SPBuilder.resolve_monk_injection(monk_cp("ghost"), monk_registry_root: @monks_dir)
  end

  test "unreadable registry path → {:error,{:registry_unreadable,_,_}}" do
    cp = monk_cp("vision-doctrine")

    assert {:error, {:registry_unreadable, _, _}} =
             SPBuilder.resolve_monk_injection(cp, monk_registry_root: "/nonexistent")
  end
end
