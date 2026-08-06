defmodule Fleet.Spawner.PodSkillsPluginsTest do
  @moduledoc """
  DN ring1/pod-bootstrap-superpowers — `Fleet.Spawner.Pod.LaunchSpec.skills_plugins_env/1`
  is pure: qualified `plugin:skill` skills → LCARS_SKILLS_PLUGINS env
  (unique plugin names). Consumed by bin/bwrap_launch.sh. async.
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
    assert %{"LCARS_SKILLS_PLUGINS" => "superpowers lcars-fleet"} =
             LaunchSpec.skills_plugins_env(
               cp([
                 "superpowers:brainstorming",
                 "superpowers:using-superpowers",
                 "lcars-fleet:audit"
               ])
             )
  end

  test "unqualified skill (no ':') filtered out — not a plugin (anti-M1)" do
    assert %{"LCARS_SKILLS_PLUGINS" => "superpowers"} =
             LaunchSpec.skills_plugins_env(cp(["plain-skill", "superpowers:x"]))
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
    assert %{"LCARS_SKILLS_PLUGINS" => "superpowers"} =
             LaunchSpec.skills_plugins_env(cp(["superpowers:ns:deep-skill"]))
  end
end
