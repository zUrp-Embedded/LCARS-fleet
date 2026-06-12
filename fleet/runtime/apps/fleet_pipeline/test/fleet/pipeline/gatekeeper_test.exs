defmodule Fleet.Pipeline.GatekeeperTest do
  @moduledoc """
  R4 sous-lot C — boot/registration du gatekeeper permanent (Type 3).
  `async: false` : registry `:persistent_term` + config globale.
  """
  use ExUnit.Case, async: false

  alias Fleet.Pipeline.Gatekeeper

  @pt_key {Fleet.Pipeline.Gatekeeper, :pod_id}

  setup do
    # Baseline : registry vide, pas d'override config, autoboot ON pour ce module
    # (config/test.exs le met OFF globalement — on l'active ici, opt-in).
    :persistent_term.erase(@pt_key)
    Application.delete_env(:fleet_pipeline, :gatekeeper_pod_id)
    Application.put_env(:fleet_pipeline, :gatekeeper_autoboot, true)

    on_exit(fn ->
      :persistent_term.erase(@pt_key)
      Application.delete_env(:fleet_pipeline, :gatekeeper_pod_id)
      Application.put_env(:fleet_pipeline, :gatekeeper_autoboot, false)
    end)

    :ok
  end

  # Stubs seams. Le spawner enregistre ses appels pour vérifier l'idempotence.
  defp ok_loader(_role), do: {:ok, :stub_cp}

  defp recording_spawner do
    fn _cp, ticket, opts ->
      send(self(), {:spawned, ticket, opts[:pod_id]})
      {:ok, :stub_pid}
    end
  end

  describe "pod_id/0" do
    test "nil quand rien n'est booté ni configuré" do
      assert Gatekeeper.pod_id() == nil
    end

    test "override config prioritaire sur le registry" do
      :persistent_term.put(@pt_key, "from-registry")
      Application.put_env(:fleet_pipeline, :gatekeeper_pod_id, "from-config")
      assert Gatekeeper.pod_id() == "from-config"
    end
  end

  describe "ensure_booted/1" do
    test "autoboot off → no-op (:disabled), pas de spawn" do
      Application.put_env(:fleet_pipeline, :gatekeeper_autoboot, false)
      assert {:ok, :disabled} = Gatekeeper.ensure_booted(spawner: recording_spawner())
      refute_received {:spawned, _, _}
      assert Gatekeeper.pod_id() == nil
    end

    test "boot → spawn + registration, pod_id résolvable" do
      assert {:ok, "gatekeeper-permanent"} =
               Gatekeeper.ensure_booted(loader: &ok_loader/1, spawner: recording_spawner())

      assert_received {:spawned, "permanent-gatekeeper", "gatekeeper-permanent"}
      assert Gatekeeper.pod_id() == "gatekeeper-permanent"
    end

    test "idempotent : 2e ensure_booted → pas de re-spawn" do
      {:ok, _} = Gatekeeper.ensure_booted(loader: &ok_loader/1, spawner: recording_spawner())
      assert_received {:spawned, _, _}

      # Déjà registré → no-op, aucun nouveau spawn.
      assert {:ok, "gatekeeper-permanent"} =
               Gatekeeper.ensure_booted(loader: &ok_loader/1, spawner: recording_spawner())

      refute_received {:spawned, _, _}
    end

    test "spawner :already_started → traité comme succès + registré" do
      spawner = fn _cp, _t, _o -> {:error, {:already_started, :some_pid}} end

      assert {:ok, "gatekeeper-permanent"} =
               Gatekeeper.ensure_booted(loader: &ok_loader/1, spawner: spawner)

      assert Gatekeeper.pod_id() == "gatekeeper-permanent"
    end

    test "loader échoue → {:error}, rien registré (fail-loud)" do
      assert {:error, :cap_profile_not_found} =
               Gatekeeper.ensure_booted(loader: fn _ -> {:error, :cap_profile_not_found} end)

      assert Gatekeeper.pod_id() == nil
    end

    test "spawn échoue → {:error}, rien registré" do
      spawner = fn _cp, _t, _o -> {:error, :spawn_refused} end

      assert {:error, :spawn_refused} =
               Gatekeeper.ensure_booted(loader: &ok_loader/1, spawner: spawner)

      assert Gatekeeper.pod_id() == nil
    end
  end
end
