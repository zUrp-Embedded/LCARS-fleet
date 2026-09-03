defmodule Fleet.Spawner.Pod.AssetsSettingsTest do
  @moduledoc """
  `Assets.pod_settings_json/1` (BL-6-07) — the pod settings have ONE composer and one policy.
  Before: this module shipped `skipDangerousModePermissionPrompt: true` unconditionally
  (pre-kill-yolo) while the launcher jq-merged the opposite policy — and the unconditional side
  won, handing every restricted pod a pre-accepted danger dialog. These tests pin the unified
  kill-yolo policy at the single owner.
  """
  use ExUnit.Case, async: true

  alias Fleet.Spawner.Pod.Assets

  defp profile(invocation) do
    %Fleet.CapProfile{
      kind: "CapabilityProfile",
      metadata: %{"name" => "engineer"},
      spec: %{"invocation" => invocation}
    }
  end

  test "default mode: autoMemory OFF, onboarding skipped, NO pre-accepted danger dialog" do
    settings = profile(%{}) |> Assets.pod_settings_json() |> Jason.decode!()

    assert settings["autoMemoryEnabled"] == false
    assert settings["hasCompletedOnboarding"] == true

    # The marketplace key is NOT here, and its absence is the finding. It shipped in this file for
    # a chantier and did nothing: measured on a bench 2026-08-09, two pods carrying it installed
    # 7.2 MB of plugins anyway. The lever that works is in claude_launch.sh's .claude.json, and
    # this assertion holds the settings file to what it can actually enforce.
    refute Map.has_key?(settings, "extensions")
    # The kill-yolo policy holds at the owner: a default pod ships NO pre-acceptance.
    refute Map.has_key?(settings, "skipDangerousModePermissionPrompt")
  end

  test "a RESTRICTED mode (plan) ships no pre-accepted dialog either" do
    settings =
      profile(%{"permission_mode" => "plan"}) |> Assets.pod_settings_json() |> Jason.decode!()

    refute Map.has_key?(settings, "skipDangerousModePermissionPrompt")
    assert settings["autoMemoryEnabled"] == false
  end

  test "bypassPermissions: the skip-dialog IS pre-accepted (a headless pod must not hang)" do
    settings =
      profile(%{"permission_mode" => "bypassPermissions"})
      |> Assets.pod_settings_json()
      |> Jason.decode!()

    assert settings["skipDangerousModePermissionPrompt"] == true
    assert settings["autoMemoryEnabled"] == false
  end
end
