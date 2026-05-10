defmodule Fleet.Coord.SoftGateTest do
  use ExUnit.Case, async: false

  alias Fleet.Coord.SoftGate

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

  describe "invoke_soft_gate/4" do
    test "decision pass → :pass au 1er round" do
      Application.put_env(:fleet_coord, :stub_response, {:ok, %{decision: "pass"}})

      assert :pass = SoftGate.invoke_soft_gate(%{}, %{}, %{}, max_rounds: 3)

      assert [{:soft_gate_evaluator, _, args}] =
               Application.get_env(:fleet_coord, :stub_invocations)

      assert args.round == 1
    end

    test "decision fail + reason → {:fail, reason}" do
      Application.put_env(
        :fleet_coord,
        :stub_response,
        {:ok, %{decision: "fail", reason: "test reason"}}
      )

      assert {:fail, "test reason"} = SoftGate.invoke_soft_gate(%{}, %{}, %{}, max_rounds: 3)
    end

    test "decision retry x N puis pass → :pass au N+1ème round" do
      Application.put_env(:fleet_coord, :stub_response, [
        {:ok, %{decision: "retry"}},
        {:ok, %{decision: "retry"}},
        {:ok, %{decision: "pass"}}
      ])

      assert :pass = SoftGate.invoke_soft_gate(%{}, %{}, %{}, max_rounds: 5)

      invocations = Application.get_env(:fleet_coord, :stub_invocations)
      assert length(invocations) == 3
    end

    test "retry epuise max_rounds → {:fail, max_rounds reached}" do
      Application.put_env(:fleet_coord, :stub_response, [
        {:ok, %{decision: "retry"}},
        {:ok, %{decision: "retry"}}
      ])

      assert {:fail, msg} = SoftGate.invoke_soft_gate(%{}, %{}, %{}, max_rounds: 2)
      assert msg =~ "max_rounds 2 reached"
    end

    test "spawn error → {:fail, spawn error}" do
      Application.put_env(:fleet_coord, :stub_response, {:error, :pod_crash})

      assert {:fail, msg} = SoftGate.invoke_soft_gate(%{}, %{}, %{}, max_rounds: 3)
      assert msg =~ "spawn error"
      assert msg =~ "pod_crash"
    end

    test "decision inconnue → {:fail, unknown}" do
      Application.put_env(:fleet_coord, :stub_response, {:ok, %{decision: "weird"}})

      assert {:fail, msg} = SoftGate.invoke_soft_gate(%{}, %{}, %{}, max_rounds: 3)
      assert msg =~ "unknown decision"
    end

    test "max_rounds default = 3" do
      Application.put_env(:fleet_coord, :stub_response, [
        {:ok, %{decision: "retry"}},
        {:ok, %{decision: "retry"}},
        {:ok, %{decision: "retry"}},
        {:ok, %{decision: "pass"}}
      ])

      assert {:fail, msg} = SoftGate.invoke_soft_gate(%{}, %{}, %{}, [])
      assert msg =~ "max_rounds 3"
    end
  end
end
