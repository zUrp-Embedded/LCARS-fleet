defmodule Fleet.Workflow.GatekeeperTest do
  @moduledoc """
  R4 — boot/registration of the permanent gatekeeper (Type 3).
  `async: false`: `:persistent_term` registry + global config.
  """
  use ExUnit.Case, async: false

  alias Fleet.Workflow.Gatekeeper

  @pt_key {Fleet.Workflow.Gatekeeper, :pod_id}

  setup do
    # Baseline: empty registry, no config override, autoboot ON for this module
    # (config/test.exs turns it OFF globally — enabled here, opt-in).
    :persistent_term.erase(@pt_key)
    Application.delete_env(:fleet_workflow, :gatekeeper_pod_id)
    Application.put_env(:fleet_workflow, :gatekeeper_autoboot, true)

    on_exit(fn ->
      :persistent_term.erase(@pt_key)
      Application.delete_env(:fleet_workflow, :gatekeeper_pod_id)
      Application.put_env(:fleet_workflow, :gatekeeper_autoboot, false)
    end)

    :ok
  end

  # Seam stubs. The spawner records its calls so idempotence can be verified.
  defp ok_loader(_role), do: {:ok, :stub_cp}

  defp recording_spawner do
    fn _cp, issue, opts ->
      send(self(), {:spawned, issue, opts[:pod_id]})
      {:ok, :stub_pid}
    end
  end

  describe "pod_id/0" do
    test "nil when nothing is booted nor configured" do
      assert Gatekeeper.pod_id() == nil
    end

    test "config override takes priority over the registry" do
      :persistent_term.put(@pt_key, "from-registry")
      Application.put_env(:fleet_workflow, :gatekeeper_pod_id, "from-config")
      assert Gatekeeper.pod_id() == "from-config"
    end
  end

  describe "ensure_booted/1" do
    test "autoboot off → no-op (:disabled), no spawn" do
      Application.put_env(:fleet_workflow, :gatekeeper_autoboot, false)
      assert {:ok, :disabled} = Gatekeeper.ensure_booted(spawner: recording_spawner())
      refute_received {:spawned, _, _}
      assert Gatekeeper.pod_id() == nil
    end

    test "boot → spawn + registration, pod_id resolvable" do
      assert {:ok, "gatekeeper"} =
               Gatekeeper.ensure_booted(loader: &ok_loader/1, spawner: recording_spawner())

      assert_received {:spawned, "permanent-gatekeeper", "gatekeeper"}
      assert Gatekeeper.pod_id() == "gatekeeper"
    end

    test "idempotent: 2nd ensure_booted → no re-spawn" do
      {:ok, _} = Gatekeeper.ensure_booted(loader: &ok_loader/1, spawner: recording_spawner())
      assert_received {:spawned, _, _}

      # Already registered → no-op, no new spawn.
      assert {:ok, "gatekeeper"} =
               Gatekeeper.ensure_booted(loader: &ok_loader/1, spawner: recording_spawner())

      refute_received {:spawned, _, _}
    end

    test "spawner :already_started → treated as success + registered" do
      spawner = fn _cp, _t, _o -> {:error, {:already_started, :some_pid}} end

      assert {:ok, "gatekeeper"} =
               Gatekeeper.ensure_booted(loader: &ok_loader/1, spawner: spawner)

      assert Gatekeeper.pod_id() == "gatekeeper"
    end

    test "loader fails → {:error}, nothing registered (fail-loud)" do
      assert {:error, :cap_profile_not_found} =
               Gatekeeper.ensure_booted(loader: fn _ -> {:error, :cap_profile_not_found} end)

      assert Gatekeeper.pod_id() == nil
    end

    test "spawn fails → {:error}, nothing registered" do
      spawner = fn _cp, _t, _o -> {:error, :spawn_refused} end

      assert {:error, :spawn_refused} =
               Gatekeeper.ensure_booted(loader: &ok_loader/1, spawner: spawner)

      assert Gatekeeper.pod_id() == nil
    end
  end

  describe "reboot/1" do
    test "FORCES the re-spawn even when already registered (≠ idempotent ensure_booted): reaps + de-registers + re-boots" do
      {:ok, "gatekeeper"} =
        Gatekeeper.ensure_booted(loader: &ok_loader/1, spawner: recording_spawner())

      assert_received {:spawned, _, _}

      # ensure_booted alone would be a no-op (already registered, cf. idempotent test); reboot de-registers → re-spawn.
      assert {:ok, "gatekeeper"} =
               Gatekeeper.reboot(
                 loader: &ok_loader/1,
                 spawner: recording_spawner(),
                 killer: fn _pod_id -> :ok end
               )

      assert_received {:spawned, _, _}
    end
  end
end
