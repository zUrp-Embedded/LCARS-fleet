defmodule Fleet.SPBuilder.MonkTest do
  @moduledoc """
  Skipped legacy registry-resolution cases. No tests in this module currently execute;
  the non-monk case checks the resolver result, not byte-identical prompt composition.
  """
  use ExUnit.Case, async: true

  # Memory-X fixtures moved to priv/memory-x/monks. Repoint these legacy paths and revisit
  # per-project ownership before enabling the cases; the resolver implementation remains.
  @moduletag skip:
               "Memory-X frozen (BL) — monk cap-profiles archived; re-enable at the per-project re-home"

  alias Fleet.SPBuilder

  # Historical location, retained with the skipped fixtures.
  @monks_dir Application.app_dir(
               :lcars_fleet,
               "priv/catalogue/cap_profile/cap-profiles/monks"
             )

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
