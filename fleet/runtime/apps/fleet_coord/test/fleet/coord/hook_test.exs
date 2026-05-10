defmodule Fleet.Coord.HookTest do
  use ExUnit.Case, async: false

  alias Fleet.Coord.Hook

  setup do
    Application.put_env(
      :fleet_coord,
      :spawner_backend,
      Fleet.Coord.SpawnerBackendStub
    )

    Application.put_env(:fleet_coord, :stub_invocations, [])

    on_exit(fn ->
      Application.delete_env(:fleet_coord, :spawner_backend)
      Application.delete_env(:fleet_coord, :stub_invocations)
      Application.delete_env(:fleet_coord, :stub_response)
    end)

    :ok
  end

  describe "invoke_hook/2 :before_next" do
    test "decision continue → :continue" do
      Application.put_env(:fleet_coord, :stub_response, {:ok, %{decision: "continue"}})

      assert :continue = Hook.invoke_hook(:before_next, %{stage: "s1"})
    end

    test "decision halt + reason → {:halt, reason}" do
      Application.put_env(
        :fleet_coord,
        :stub_response,
        {:ok, %{decision: "halt", reason: "user_close"}}
      )

      assert {:halt, "user_close"} = Hook.invoke_hook(:before_next, %{})
    end

    test "decision halt sans reason → {:halt, default}" do
      Application.put_env(:fleet_coord, :stub_response, {:ok, %{decision: "halt"}})

      assert {:halt, msg} = Hook.invoke_hook(:before_next, %{})
      assert msg =~ "no reason"
    end

    test "spawn error → {:halt, spawn error}" do
      Application.put_env(:fleet_coord, :stub_response, {:error, :pod_failure})

      assert {:halt, msg} = Hook.invoke_hook(:before_next, %{})
      assert msg =~ "spawn error"
      assert msg =~ "pod_failure"
    end

    test "decision inconnue → {:halt, unknown}" do
      Application.put_env(:fleet_coord, :stub_response, {:ok, %{decision: "weird"}})

      assert {:halt, msg} = Hook.invoke_hook(:before_next, %{})
      assert msg =~ "unknown decision"
    end
  end

  describe "invoke_hook/2 unknown type" do
    test "hook type non-supporté → {:halt, unknown hook}" do
      assert {:halt, msg} = Hook.invoke_hook(:after_stage, %{})
      assert msg =~ "unknown hook type"
      assert msg =~ "after_stage"
    end
  end
end
