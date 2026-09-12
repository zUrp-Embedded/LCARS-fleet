defmodule Fleet.Spawner.PodSkillsPluginsTest do
  @moduledoc """
  Verify qualified plugin:skill entries become unique LCARS_SKILLS_PLUGINS names.
  Fixtures describe the generic mechanism rather than implying an installed plugin dependency.
  """
  use ExUnit.Case, async: true

  alias Fleet.Spawner.Pod.LaunchSpec

  defp cp(skills),
    do: %Fleet.CapProfile{
      kind: "CapabilityProfile",
      metadata: %{"name" => "engineer"},
      spec: %{"knowledge" => %{"skills" => skills}}
    }

  test "qualified skills → unique plugins, order preserved" do
    assert %{"LCARS_SKILLS_PLUGINS" => "atelier lcars-fleet"} =
             LaunchSpec.skills_plugins_env(
               cp([
                 "atelier:esquisse",
                 "atelier:relecture",
                 "lcars-fleet:audit"
               ])
             )
  end

  test "unqualified skill (no ':') filtered out — not a plugin (anti-M1)" do
    assert %{"LCARS_SKILLS_PLUGINS" => "atelier"} =
             LaunchSpec.skills_plugins_env(cp(["plain-skill", "atelier:x"]))
  end

  test "empty skills → %{} (backward-compatible, no env var)" do
    assert %{} == LaunchSpec.skills_plugins_env(cp([]))
  end

  test "knowledge/skills absent or nil → %{} (defensive)" do
    assert %{} ==
             LaunchSpec.skills_plugins_env(%Fleet.CapProfile{
               kind: "CapabilityProfile",
               metadata: %{"name" => "x"},
               spec: %{}
             })

    assert %{} == LaunchSpec.skills_plugins_env(cp(nil))
  end

  test "split parts:2 — skill with multiple ':' → plugin prefix only" do
    assert %{"LCARS_SKILLS_PLUGINS" => "atelier"} =
             LaunchSpec.skills_plugins_env(cp(["atelier:ns:deep-skill"]))
  end
end
