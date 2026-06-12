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

  # R0.8-brick1 : root canon in-repo (R0.7 réabsorption), pas path doctrine
  # 05_data-canon/... (inexistant en standard install).
  @monks_dir Application.app_dir(:fleet_cap_profile, "priv/canon/cap-profiles/monks")

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

  test "monk canon réel (vision-doctrine) → persona_hint + corpus_paths du registry" do
    assert {:ok, %{persona_hint: ph, corpus_paths: cps}} =
             SPBuilder.resolve_monk_injection(monk_cp("vision-doctrine"),
               monk_registry_root: @monks_dir
             )

    assert ph =~ "gardien de la doctrine fondatrice"
    assert "00_doctrine/moon-shot-ref/#00_vision/" in cps
    assert length(cps) == 3
  end

  test "monk canon réel (archive) → entrée distincte" do
    assert {:ok, %{persona_hint: ph, corpus_paths: [cp]}} =
             SPBuilder.resolve_monk_injection(monk_cp("archive"),
               monk_registry_root: @monks_dir
             )

    assert ph =~ "archives moon-shot"
    assert cp == "00_doctrine/moon-shot-ref/#99_archive/"
  end

  test "cap-profile non-monk → :not_a_monk (compose reste byte-identique chantier-2)" do
    assert :not_a_monk = SPBuilder.resolve_monk_injection(plain_cp(), [])
  end

  test "monk_instance absent du registry → {:error,{:monk_instance_not_found,_}}" do
    assert {:error, {:monk_instance_not_found, "ghost"}} =
             SPBuilder.resolve_monk_injection(monk_cp("ghost"), monk_registry_root: @monks_dir)
  end

  test "registry path illisible → {:error,{:registry_unreadable,_,_}}" do
    cp = monk_cp("vision-doctrine")

    assert {:error, {:registry_unreadable, _, _}} =
             SPBuilder.resolve_monk_injection(cp, monk_registry_root: "/nonexistent")
  end
end
