defmodule Fleet.MCP.DeleteProjectDisarmedTest do
  @moduledoc """
  The one irreversible act in the tool surface is OFF by default.

  `force: true` already made the gesture deliberate, and deliberate is not the same as available.
  `delete_project` destroys the forge repo AND both worktrees, its target is a free argument, and it
  was permanently reachable by any onboarder pod. Nothing in the fleet's normal life needs it:
  end-of-life teardown is an operator decision.

  Same shape as the bench's `--human-admin` — a real power, off by default, whose cost is written
  next to its switch.

  The switch is checked BEFORE the gate on purpose, and the tests below fix that order: a pod that
  is not an onboarder learns that the tool is disabled, not that it would have been refused. An
  unauthorized caller has no business finding out whether it would have been authorized.
  """
  use ExUnit.Case, async: false

  alias Fleet.MCP.PodTools
  alias Fleet.TestEnv

  defmodule Onboard do
    def delete_project(full_name, _opts) do
      send(self(), {:deleted, full_name})
      {:ok, %{repo: full_name}}
    end

    def onboard(_n, _o), do: {:error, :unused}
    def import(_f, _o), do: {:error, :unused}
    def open(_f, _o), do: {:error, :unused}
    def adopt_project(_n, _o), do: {:error, :unused}
    def import_external(_u, _n, _o), do: {:error, :unused}
    def close_project(_f, _o), do: {:error, :unused}
    def revise_card(_f, _o), do: {:error, :unused}
    def list_projects(_o), do: {:ok, []}
  end

  setup do
    TestEnv.put_env_restoring(:fleet_mcp, :project_onboard, Onboard)
    TestEnv.restore_env_on_exit(:fleet_mcp, :allow_delete_project)

    TestEnv.put_env_restoring(:fleet_mcp, :pod_resolver, fn _ ->
      {:ok, %{role: "starfleet", repo: "fleet/demo"}}
    end)

    :ok
  end

  defp delete(state \\ %{pod_id: "pod-sf"}),
    do:
      PodTools.handle_tool_call(
        "delete_project",
        %{"full_name" => "fleet/demo", "force" => true},
        state
      )

  describe "disarmed by default" do
    test "no flag at all → NAMED refusal, and nothing is destroyed" do
      Application.delete_env(:fleet_mcp, :allow_delete_project)

      assert {:error, :delete_project_disabled, _} = delete()
      refute_received {:deleted, _}
    end

    test "the refusal is named, not silence: an agent told 'disabled' asks its human" do
      Application.delete_env(:fleet_mcp, :allow_delete_project)

      assert {:error, reason, _} = delete()
      refute reason == :unknown_tool
      refute reason == :invalid_arguments
    end

    test "explicitly false is still disarmed" do
      Application.put_env(:fleet_mcp, :allow_delete_project, false)

      assert {:error, :delete_project_disabled, _} = delete()
      refute_received {:deleted, _}
    end

    test "a TRUTHY non-boolean does NOT arm it — only the boolean says yes" do
      for value <- ["true", 1, :yes] do
        Application.put_env(:fleet_mcp, :allow_delete_project, value)

        assert {:error, :delete_project_disabled, _} = delete(),
               "#{inspect(value)} must not arm an irreversible gesture"

        refute_received {:deleted, _}
      end
    end
  end

  describe "the switch comes before the gate" do
    test "a non-onboarder gets the DISABLED answer, never a hint about its own authorization" do
      Application.delete_env(:fleet_mcp, :allow_delete_project)

      TestEnv.put_env_restoring(:fleet_mcp, :pod_resolver, fn _ ->
        {:ok, %{role: "engineer", repo: "fleet/demo"}}
      end)

      assert {:error, :delete_project_disabled, _} = delete()
    end

    test "ARMED, the gate is back in charge and refuses the same pod on its role" do
      Application.put_env(:fleet_mcp, :allow_delete_project, true)

      TestEnv.put_env_restoring(:fleet_mcp, :pod_resolver, fn _ ->
        {:ok, %{role: "engineer", repo: "fleet/demo"}}
      end)

      assert {:error, :forbidden_not_onboarder, _} = delete()
      refute_received {:deleted, _}
    end
  end

  describe "INVERSE TWIN — armed, the tool still works" do
    test "flag true + onboarder + force → the deletion happens" do
      Application.put_env(:fleet_mcp, :allow_delete_project, true)

      assert {:ok, _, _} = delete()
      assert_received {:deleted, "fleet/demo"}
    end
  end
end
