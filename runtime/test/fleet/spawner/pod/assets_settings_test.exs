defmodule Fleet.Spawner.Pod.AssetsSettingsTest do
  @moduledoc """
  Verify permission-mode policy at the sole composer of pod settings.
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

    # Marketplace controls belong to the launcher’s .claude.json, not this settings file.
    refute Map.has_key?(settings, "extensions")
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
