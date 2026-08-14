defmodule Fleet.MCP.GithubPublishTest do
  @moduledoc """
  The `github_publish` tool: gate + async enqueue at the door (PodTools/Delegation), and the worker's
  fail-closed outcome on the Bus (GithubPublish.run). The full push needs a live forge + git-filter-repo
  and is operator-exercised; here we pin the SURFACE that must never regress — the gate, the argument
  shape, and that a not-linked project fails LOUD on the bus rather than silently or with a crash.
  """
  use ExUnit.Case, async: false

  alias Fleet.MCP.PodTools
  alias Fleet.MCP.PodTools.GithubPublish
  alias Fleet.EventRouter.Bus
  alias Fleet.TestEnv

  defp call(args, state), do: PodTools.handle_tool_call("github_publish", args, state)

  describe "the door: gate + argument shape" do
    test "missing repo -> invalid_arguments (no gate needed)" do
      assert {:error, :invalid_arguments, _} = call(%{}, %{pod_id: "x"})
    end

    test "a non-onboarder role is refused by the gate" do
      # resolve_identity is stubbed to a role that is NOT the onboarder; role_has_capability? then
      # reads the real cap-profile canon and denies :onboarder to the delegate.
      TestEnv.put_env_restoring(:lcars_fleet, :mcp_pod_resolver, fn _ ->
        {:ok, %{role: "architect", repo: "fleet/demo"}}
      end)

      assert {:error, :forbidden_not_onboarder, _} =
               call(%{"repo" => "fleet/demo"}, %{pod_id: "pod-arch"})
    end

    test "no pod_id -> the gate refuses before any work" do
      assert {:error, :pod_id_required, _} = call(%{"repo" => "fleet/demo"}, %{})
    end
  end

  describe "the worker: fail-closed on the bus" do
    test "a project with no publish binding emits github_publish.failed (not_linked), never a crash" do
      tmp = System.tmp_dir!() |> Path.join("gh-pub-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf(tmp) end)

      # Point HOME at an empty home so ~/.lcars/publish/<slug>.json is absent.
      prev_home = System.get_env("HOME")
      System.put_env("HOME", tmp)
      on_exit(fn -> if prev_home, do: System.put_env("HOME", prev_home) end)

      :ok = Bus.subscribe()

      assert :ok = GithubPublish.run("fleet/unlinked-demo", "pod-req")

      assert_receive %Fleet.Event{
                       type: :"github_publish.failed",
                       payload: %{
                         "repo" => "fleet/unlinked-demo",
                         "reason" => "not_linked",
                         "requester_pod_id" => "pod-req"
                       }
                     },
                     2_000
    end
  end
end
