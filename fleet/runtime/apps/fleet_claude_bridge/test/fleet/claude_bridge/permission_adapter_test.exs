defmodule Fleet.ClaudeBridge.PermissionAdapterTest do
  use ExUnit.Case, async: false

  alias Fleet.ClaudeBridge.PermissionAdapter
  alias Fleet.ClaudeBridge.StubBackends

  setup do
    original = Application.get_env(:fleet_claude_bridge, :permission_router_backend)

    on_exit(fn ->
      if original do
        Application.put_env(:fleet_claude_bridge, :permission_router_backend, original)
      else
        Application.delete_env(:fleet_claude_bridge, :permission_router_backend)
      end
    end)

    :ok
  end

  describe "default backend (vestigial ADR-D rev2 — permission routing retiré, bwrap = guard)" do
    test "DefaultDeny renvoie %{behavior: deny} fail-safe (§0 #1 axiome préservé)" do
      Application.delete_env(:fleet_claude_bridge, :permission_router_backend)

      assert %{"behavior" => "deny", "reason" => reason} =
               PermissionAdapter.can_use_tool("Read", %{}, %{})

      assert reason =~ "default-deny"
      assert reason =~ "vestigial ADR-D rev2"
    end
  end

  describe "mapping verdicts → SDK shape" do
    test ":allow → %{behavior: allow}" do
      Application.put_env(
        :fleet_claude_bridge,
        :permission_router_backend,
        StubBackends.PermissionAlwaysAllow
      )

      assert %{"behavior" => "allow"} = PermissionAdapter.can_use_tool("Read", %{}, %{})
    end

    test "{:allow, augmented} → %{behavior: allow, input: augmented}" do
      Application.put_env(
        :fleet_claude_bridge,
        :permission_router_backend,
        StubBackends.PermissionAllowAugmented
      )

      assert %{"behavior" => "allow", "input" => %{"augmented" => true}} =
               PermissionAdapter.can_use_tool("Read", %{}, %{})
    end

    test "{:deny, reason} → %{behavior: deny, reason: reason}" do
      Application.put_env(
        :fleet_claude_bridge,
        :permission_router_backend,
        StubBackends.PermissionDeny
      )

      assert %{"behavior" => "deny", "reason" => "stub-deny"} =
               PermissionAdapter.can_use_tool("Read", %{}, %{})
    end

    test ":ask → deny avec reason \"relay pending (ask deprecated MVP)\"" do
      Application.put_env(
        :fleet_claude_bridge,
        :permission_router_backend,
        StubBackends.PermissionAsk
      )

      assert %{"behavior" => "deny", "reason" => "relay pending (ask deprecated MVP)"} =
               PermissionAdapter.can_use_tool("Read", %{}, %{})
    end
  end
end
