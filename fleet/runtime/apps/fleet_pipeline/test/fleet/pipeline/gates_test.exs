defmodule Fleet.Pipeline.GatesTest do
  use ExUnit.Case, async: false

  alias Fleet.Pipeline.Gates

  describe "dispatch/3 — nil / absent gate" do
    test "gate nil → :pass" do
      assert Gates.dispatch(%{"gate" => nil}, %{}, %{}) == :pass
    end

    test "gate absent → :pass" do
      assert Gates.dispatch(%{"role" => "x"}, %{}, %{}) == :pass
    end
  end

  describe "dispatch/3 — hard" do
    test "rule match outputs → :pass" do
      stage = %{"gate" => %{"type" => "hard", "rule" => %{"status" => "ok"}}}
      assert Gates.dispatch(stage, %{"status" => "ok", "extra" => 1}, %{}) == :pass
    end

    test "rule mismatch → {:fail, _}" do
      stage = %{"gate" => %{"type" => "hard", "rule" => %{"status" => "ok"}}}
      assert {:fail, "hard gate rule mismatch"} = Gates.dispatch(stage, %{"status" => "ko"}, %{})
    end

    test "nested rule match" do
      stage = %{
        "gate" => %{
          "type" => "hard",
          "rule" => %{"data" => %{"count" => 3}}
        }
      }

      assert Gates.dispatch(stage, %{"data" => %{"count" => 3, "extra" => true}}, %{}) ==
               :pass
    end
  end

  describe "dispatch/3 — soft" do
    setup do
      Application.put_env(
        :fleet_pipeline,
        :coord_backend,
        Fleet.Pipeline.GatesTest.CoordStub
      )

      on_exit(fn -> Application.delete_env(:fleet_pipeline, :coord_backend) end)
      :ok
    end

    test "délégué CoordBackend" do
      stage = %{"gate" => %{"type" => "soft", "max_rounds" => 5}}
      assert Gates.dispatch(stage, %{}, %{user: "test"}) == :pass
    end
  end

  describe "dispatch/3 — soft (NotWiredYet par défaut)" do
    test "default backend retourne {:fail, _}" do
      stage = %{"gate" => %{"type" => "soft", "max_rounds" => 3}}
      assert {:fail, msg} = Gates.dispatch(stage, %{}, %{})
      assert msg =~ "fleet_coord"
    end
  end

  describe "dispatch/3 — terminal" do
    test "toutes règles match → :pass" do
      stage = %{
        "gate" => %{
          "type" => "terminal",
          "rules" => [
            %{"name" => "r1", "match" => %{"a" => 1}},
            %{"name" => "r2", "match" => %{"b" => 2}}
          ]
        }
      }

      assert Gates.dispatch(stage, %{"a" => 1, "b" => 2}, %{}) == :pass
    end

    test "règle required mismatch → {:fail, _}" do
      stage = %{
        "gate" => %{
          "type" => "terminal",
          "rules" => [
            %{"name" => "must_have_status", "required" => true, "match" => %{"status" => "ok"}}
          ]
        }
      }

      assert {:fail, msg} = Gates.dispatch(stage, %{"status" => "ko"}, %{})
      assert msg =~ "must_have_status"
    end

    test "règle non-required mismatch → :retry (gatekeeper fallback)" do
      Application.put_env(
        :fleet_pipeline,
        :spawner_backend,
        Fleet.Pipeline.GatesTest.SpawnerStub
      )

      Application.put_env(:fleet_pipeline, :gatekeeper_invocations, [])

      stage = %{
        "gate" => %{
          "type" => "terminal",
          "rules" => [
            %{"name" => "soft_check", "required" => false, "match" => %{"clean" => true}}
          ]
        }
      }

      assert :retry = Gates.dispatch(stage, %{"clean" => false}, %{ticket_id: "t#1"})

      invocations = Application.get_env(:fleet_pipeline, :gatekeeper_invocations, [])
      assert Enum.any?(invocations, fn {role, _ctx} -> role == "gatekeeper" end)
    after
      Application.delete_env(:fleet_pipeline, :spawner_backend)
      Application.delete_env(:fleet_pipeline, :gatekeeper_invocations)
    end
  end
end

defmodule Fleet.Pipeline.GatesTest.CoordStub do
  @behaviour Fleet.Pipeline.CoordBackend

  @impl true
  def invoke_soft_gate(_stage, _outputs, _ctx, _opts), do: :pass

  @impl true
  def invoke_hook(_name, _ctx), do: :ok
end

defmodule Fleet.Pipeline.GatesTest.SpawnerStub do
  @behaviour Fleet.Pipeline.SpawnerBackend

  @impl true
  def spawn_stage_pod(role, _profile, ctx) do
    log = Application.get_env(:fleet_pipeline, :gatekeeper_invocations, [])
    Application.put_env(:fleet_pipeline, :gatekeeper_invocations, [{role, ctx} | log])
    {:ok, "stub-#{role}"}
  end
end
