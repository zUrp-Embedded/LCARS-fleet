defmodule Fleet.MCP.ProjectPublishTest do
  @moduledoc """
  Direct handler gate/argument tests, missing-binding failure events and work-directory
  sweeping. No successful enqueue, full rail execution or external push is exercised here.
  """
  use ExUnit.Case, async: false

  alias Fleet.EventRouter.Bus
  alias Fleet.MCP.PodTools
  alias Fleet.MCP.PodTools.ProjectPublish
  alias Fleet.TestEnv

  defp call(args, state), do: PodTools.handle_tool_call("project_publish", args, state)

  describe "publish_identity/1 — the public identity travels with the binding" do
    test "a binding that declares it hands it to the rail" do
      assert ProjectPublish.publish_identity(%{
               "publish_name" => "Lord Zurp",
               "publish_email" => "lord@zurp.example"
             }) == ["--publish-name", "Lord Zurp", "--publish-email", "lord@zurp.example"]
    end

    test "no declared identity → nothing passed: the transform refuses, it never guesses" do
      assert ProjectPublish.publish_identity(%{"host" => "github"}) == []
    end
  end

  describe "binding_key/1 — org-qualified, homonyms do not collide (defect #2)" do
    test "owner/name -> owner__name, and two orgs of the same name stay apart" do
      assert ProjectPublish.binding_key("fleet/demo") == "fleet__demo"

      # the name alone (`demo`) would collide across orgs; the org-qualified key keeps them separate.
      assert ProjectPublish.binding_key("fleet/demo") !=
               ProjectPublish.binding_key("archives/demo")
    end
  end

  describe "the door: gate + argument shape" do
    test "missing full_name -> invalid_arguments (no gate needed)" do
      assert {:error, :invalid_arguments, _} = call(%{}, %{pod_id: "x"})
    end

    test "a non-onboarder role is refused by the gate" do
      # resolve_identity is stubbed to a role that is NOT the onboarder; role_has_capability? then
      # reads the real cap-profile canon and denies :onboarder to the delegate.
      TestEnv.put_env_restoring(:lcars_fleet, :mcp_pod_resolver, fn _ ->
        {:ok, %{role: "architect", repo: "fleet/demo"}}
      end)

      assert {:error, :forbidden_not_onboarder, _} =
               call(%{"full_name" => "fleet/demo"}, %{pod_id: "pod-arch"})
    end

    test "no pod_id -> the gate refuses before any work" do
      assert {:error, :pod_id_required, _} = call(%{"full_name" => "fleet/demo"}, %{})
    end
  end

  describe "the worker: fail-closed on the bus" do
    test "a project with no publish binding emits project_publish.failed (not_linked), never a crash" do
      # Assert the real binding is absent before exercising that branch. OTP caches
      # user_home at VM start, so changing HOME in this process would not redirect it.
      # This test must not remove an existing human binding to establish its premise.
      binding_path =
        Path.join([System.user_home!(), ".lcars", "publish", "fleet__unlinked-demo.json"])

      refute File.exists?(binding_path),
             "PREMISSE FAUSSE : #{binding_path} existe. Ce temoin exerce l'ABSENCE de liaison et " <>
               "ne peut pas la fabriquer (`user_home!/0` est fige au demarrage de la VM). Retirer " <>
               "ce fichier, ou changer le slug du temoin pour un nom qui n'existera jamais."

      :ok = Bus.subscribe()

      assert :ok = ProjectPublish.run("fleet/unlinked-demo", "pod-req")

      assert_receive %Fleet.Event{
                       type: :"project_publish.failed",
                       payload: %{
                         "repo" => "fleet/unlinked-demo",
                         "reason" => "not_linked",
                         "requester_pod_id" => "pod-req"
                       }
                     },
                     2_000
    end
  end

  describe "the work directory: swept on every outcome but the one that must be inspected" do
    # Test sweep_work directly; these cases do not exercise run's token cleanup or
    # exception paths. A successful publication would need a binding under user_home.

    defp a_work_dir do
      d =
        System.tmp_dir!()
        |> Path.join("lcars-publish-witness-#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(d, ".git"))
      File.write!(Path.join(d, "README.md"), "x")
      d
    end

    test "a normal outcome sweeps the clone" do
      d = a_work_dir()
      assert File.dir?(d)
      assert {:ok, _} = ProjectPublish.sweep_work(d, 0)
      refute File.exists?(d)
    end

    test "any non-zero exit sweeps it too — a failed publish is not a reason to fill /tmp" do
      for code <- [1, 2, 3, 4, 5] do
        d = a_work_dir()
        assert {:ok, _} = ProjectPublish.sweep_work(d, code)
        refute File.exists?(d), "exit #{code} left its clone behind"
      end
    end

    test "exit 6 KEEPS the clone — the only failure nobody can diagnose afterwards" do
      # Exit 6 preserves the clone for inspection of a nondeterministic rewrite.
      d = a_work_dir()
      assert :kept_for_inspection = ProjectPublish.sweep_work(d, 6)
      assert File.dir?(d), "exit 6 must KEEP its clone for inspection"
      File.rm_rf(d)
    end
  end
end
