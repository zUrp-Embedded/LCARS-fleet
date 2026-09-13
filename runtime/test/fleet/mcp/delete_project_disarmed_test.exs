defmodule Fleet.MCP.DeleteProjectDisarmedTest do
  @moduledoc """
  Project deletion requires an explicit boolean deployment switch before the onboarder
  gate. force does not arm that switch. Direct handler tests record the stub call;
  they do not delete repositories or worktrees. Disabled calls return the same refusal
  before resolving whether the role would be authorized.
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
    def deposit_candidates(_h, _o), do: {:error, :unused}
    def import_deposit(_s, _c, _o), do: {:error, :unused}
    def close_project(_f, _o), do: {:error, :unused}
    def revise_card(_f, _o), do: {:error, :unused}
    def reset_ci_rail(_f, _o), do: {:error, :unused}
    def list_projects(_o), do: {:ok, []}
    def list_stoppable_issues(_r, _o), do: {:ok, []}
  end

  setup do
    TestEnv.put_env_restoring(:lcars_fleet, :mcp_project_onboard, Onboard)
    TestEnv.restore_env_on_exit(:lcars_fleet, :mcp_allow_delete_project)

    TestEnv.put_env_restoring(:lcars_fleet, :mcp_pod_resolver, fn _ ->
      {:ok, %{role: "starfleet", repo: "fleet/demo"}}
    end)

    :ok
  end

  defp delete(state \\ %{pod_id: "pod-sf"}),
    do:
      PodTools.handle_tool_call(
        "project_delete",
        %{"full_name" => "fleet/demo", "force" => true},
        state
      )

  describe "disarmed by default" do
    test "no flag at all → NAMED refusal, and nothing is destroyed" do
      Application.delete_env(:lcars_fleet, :mcp_allow_delete_project)

      assert {:error, :delete_project_disabled, _} = delete()
      refute_received {:deleted, _}
    end

    test "the refusal is named, not silence: an agent told 'disabled' asks its human" do
      Application.delete_env(:lcars_fleet, :mcp_allow_delete_project)

      assert {:error, reason, _} = delete()
      refute reason == :unknown_tool
      refute reason == :invalid_arguments
    end

    test "explicitly false is still disarmed" do
      Application.put_env(:lcars_fleet, :mcp_allow_delete_project, false)

      assert {:error, :delete_project_disabled, _} = delete()
      refute_received {:deleted, _}
    end

    test "a TRUTHY non-boolean does NOT arm it — only the boolean says yes" do
      for value <- ["true", 1, :yes] do
        Application.put_env(:lcars_fleet, :mcp_allow_delete_project, value)

        assert {:error, :delete_project_disabled, _} = delete(),
               "#{inspect(value)} must not arm an irreversible gesture"

        refute_received {:deleted, _}
      end
    end
  end

  describe "the switch comes before the gate" do
    test "a non-onboarder gets the DISABLED answer, never a hint about its own authorization" do
      Application.delete_env(:lcars_fleet, :mcp_allow_delete_project)

      TestEnv.put_env_restoring(:lcars_fleet, :mcp_pod_resolver, fn _ ->
        {:ok, %{role: "engineer", repo: "fleet/demo"}}
      end)

      assert {:error, :delete_project_disabled, _} = delete()
    end

    test "ARMED, the gate is back in charge and refuses the same pod on its role" do
      Application.put_env(:lcars_fleet, :mcp_allow_delete_project, true)

      TestEnv.put_env_restoring(:lcars_fleet, :mcp_pod_resolver, fn _ ->
        {:ok, %{role: "engineer", repo: "fleet/demo"}}
      end)

      assert {:error, :forbidden_not_onboarder, _} = delete()
      refute_received {:deleted, _}
    end
  end

  describe "INVERSE TWIN — armed, the tool still works" do
    test "flag true + onboarder + force → the deletion happens" do
      Application.put_env(:lcars_fleet, :mcp_allow_delete_project, true)

      assert {:ok, _, _} = delete()
      assert_received {:deleted, "fleet/demo"}
    end
  end
end
