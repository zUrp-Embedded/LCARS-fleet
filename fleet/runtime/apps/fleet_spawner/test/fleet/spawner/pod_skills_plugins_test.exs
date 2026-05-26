defmodule Fleet.Spawner.PodSkillsPluginsTest do
  @moduledoc """
  DN ring1/pod-bootstrap-superpowers — `Fleet.Spawner.Pod.skills_plugins_env/1`
  pur : skills qualifiés `plugin:skill` → env LCARS_SKILLS_PLUGINS
  (noms plugins uniques). Consommé par bin/bwrap_launch.sh. async.
  """
  use ExUnit.Case, async: true

  alias Fleet.Spawner.Pod

  defp cp(skills),
    do: %Fleet.CapProfile{
      kind: "CapabilityProfile",
      metadata: %{"name" => "engineer"},
      spec: %{"knowledge" => %{"skills" => skills}}
    }

  test "skills qualifiés → plugins uniques, ordre préservé" do
    assert %{"LCARS_SKILLS_PLUGINS" => "superpowers lcars-fleet"} =
             Pod.skills_plugins_env(
               cp([
                 "superpowers:brainstorming",
                 "superpowers:using-superpowers",
                 "lcars-fleet:audit"
               ])
             )
  end

  test "skill non-qualifié (sans ':') filtré — pas un plugin (anti-M1)" do
    assert %{"LCARS_SKILLS_PLUGINS" => "superpowers"} =
             Pod.skills_plugins_env(cp(["plain-skill", "superpowers:x"]))
  end

  test "skills vide → %{} (rétro-compatible, pas d'env var)" do
    assert %{} == Pod.skills_plugins_env(cp([]))
  end

  test "knowledge/skills absent ou nil → %{} (défensif)" do
    assert %{} ==
             Pod.skills_plugins_env(%Fleet.CapProfile{
               kind: "CapabilityProfile",
               metadata: %{"name" => "x"},
               spec: %{}
             })

    assert %{} == Pod.skills_plugins_env(cp(nil))
  end

  test "split parts:2 — skill avec ':' multiple → préfixe plugin seul" do
    assert %{"LCARS_SKILLS_PLUGINS" => "superpowers"} =
             Pod.skills_plugins_env(cp(["superpowers:ns:deep-skill"]))
  end
end
