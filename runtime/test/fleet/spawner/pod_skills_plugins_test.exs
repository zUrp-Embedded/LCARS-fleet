defmodule Fleet.Spawner.PodSkillsPluginsTest do
  @moduledoc """
  DN ring1/pod-bootstrap-superpowers — `Fleet.Spawner.Pod.LaunchSpec.skills_plugins_env/1`

  ⚠ Le nom du DN reste tel quel : c'est une RÉFÉRENCE vers un document existant, pas un
  exemple. Les exemples de ce fichier, eux, ne nomment plus superpowers (⚖ user 2026-08-19,
  sortie du corpus) : le mécanisme testé est générique — un préfixe `plugin:skill` — et
  l'illustrer avec un plugin que le dépôt ne charge plus laissait croire à une dépendance.
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
