defmodule Fleet.SPBuilder.MonkTest do
  @moduledoc """
  Lot 6 inc3 — `Fleet.SPBuilder.resolve_monk_injection/2` (DN
  ring2/fleet_memory.md L478 : injecter registry persona_hint+corpus_paths
  dans SP monk). Pur, canon réel. La régression compose/3 (additif
  byte-identique non-monk) = suite chantier-2 complète (mix test app).
  `async: true`.
  """
  use ExUnit.Case, async: true

  alias Fleet.SPBuilder

  # beyond_#4 root depuis apps/fleet_spbuilder/test/fleet → 6 remontées
  @b4_root Path.join([__DIR__, "..", "..", "..", "..", "..", ".."])

  defp monk_cp(instance) do
    %Fleet.CapProfile{
      api_version: "lcars/v2.5",
      kind: "CapabilityProfile",
      metadata: %{"name" => "monk-alpha-#{instance}"},
      spec: %{
        "knowledge" => %{
          "monk_registry" => "05_data-canon/cap-profiles/monks/alpha.yaml",
          "monk_instance" => instance
        }
      }
    }
  end

  defp plain_cp do
    %Fleet.CapProfile{
      api_version: "lcars/v2.5",
      kind: "CapabilityProfile",
      metadata: %{"name" => "engineer"},
      spec: %{"knowledge" => %{"skills" => ["x"]}}
    }
  end

  test "monk canon réel (vision-doctrine) → persona_hint + corpus_paths du registry" do
    assert {:ok, %{persona_hint: ph, corpus_paths: cps}} =
             SPBuilder.resolve_monk_injection(monk_cp("vision-doctrine"),
               monk_registry_root: @b4_root
             )

    assert ph =~ "gardien de la doctrine fondatrice"
    assert "00_doctrine/moon-shot-ref/#00_vision/" in cps
    assert length(cps) == 3
  end

  test "monk canon réel (archive) → entrée distincte" do
    assert {:ok, %{persona_hint: ph, corpus_paths: [cp]}} =
             SPBuilder.resolve_monk_injection(monk_cp("archive"),
               monk_registry_root: @b4_root
             )

    assert ph =~ "archives moon-shot"
    assert cp == "00_doctrine/moon-shot-ref/#99_archive/"
  end

  test "cap-profile non-monk → :not_a_monk (compose reste byte-identique chantier-2)" do
    assert :not_a_monk = SPBuilder.resolve_monk_injection(plain_cp(), [])
  end

  test "monk_instance absent du registry → {:error,{:monk_instance_not_found,_}}" do
    assert {:error, {:monk_instance_not_found, "ghost"}} =
             SPBuilder.resolve_monk_injection(monk_cp("ghost"), monk_registry_root: @b4_root)
  end

  test "registry path illisible → {:error,{:registry_unreadable,_,_}}" do
    cp = monk_cp("vision-doctrine")

    assert {:error, {:registry_unreadable, _, _}} =
             SPBuilder.resolve_monk_injection(cp, monk_registry_root: "/nonexistent")
  end
end
