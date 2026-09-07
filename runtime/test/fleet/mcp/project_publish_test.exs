defmodule Fleet.MCP.ProjectPublishTest do
  @moduledoc """
  The `project_publish` tool: gate + async enqueue at the door (PodTools/Delegation), and the worker's
  fail-closed outcome on the Bus (ProjectPublish.run). The full push needs a live forge + git-filter-repo
  and is operator-exercised; here we pin the SURFACE that must never regress — the gate, the argument
  shape, and that a not-linked project fails LOUD on the bus rather than silently or with a crash.
  """
  use ExUnit.Case, async: false

  alias Fleet.EventRouter.Bus
  alias Fleet.MCP.PodTools
  alias Fleet.MCP.PodTools.ProjectPublish
  alias Fleet.TestEnv

  defp call(args, state), do: PodTools.handle_tool_call("project_publish", args, state)

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
      # ⚠ CE TEMOIN NE FABRIQUE PAS SON ETAT : IL LE CONSTATE, ET C'EST LA DIFFERENCE.
      # `read_binding/1` resout sous `System.user_home!()`, que OTP met en cache au demarrage de la
      # VM : un `put_env("HOME", …)` deplace `System.get_env/1` et laisse `user_home!/0` ou il
      # etait (mesure du 2026-08-20). Le decor qui pretendait rediriger la maison a donc ete retire
      # — il ne faisait rien, et sa presence faisait croire le contraire.
      #
      # Reste que ce temoin etait VERT PARCE QUE la maison de l'humain qui joue la suite n'a pas
      # cette liaison. C'est un fait EXTERIEUR au temoin, qui peut cesser d'etre vrai sans que rien
      # ne le dise : la seule chose honnete est de verifier la premisse et de le dire fort si elle
      # tombe, plutot que de la supposer.
      #
      # ⚠ ET RIEN NE PEUT ETRE ECRIT SOUS CETTE MAISON DEPUIS UN TEST. `~/.lcars` est l'etat de
      # l'HUMAIN, pas de la suite ; y poser une liaison pour exercer le chemin nominal empoisonnerait
      # la machine du lecteur. Le chemin « liaison presente » est donc hors de portee d'ici, et c'est
      # ecrit plutot que tu.
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
    # PHASE 1 HAS SWEPT SINCE DAY ONE (`trap 'rm -rf' EXIT` in `lcars approve`); phase 2 never did.
    # Every publish left a COMPLETE rewritten clone in the system temp dir, forever — the size of the
    # repository, once per publication.
    #
    # ⚠ THESE DRIVE `sweep_work/2` DIRECTLY rather than a full `run/2`, and that is not laziness:
    # `read_binding/1` resolves the binding under `System.user_home!()`, which OTP caches at VM start
    # and which `System.put_env("HOME", …)` does NOT move (measured 2026-08-20). A witness that
    # redirected HOME would not be exercising the binding it thinks it wrote — it would pass for a
    # reason of its own. The property at stake is the sweep and its single exception; that is what is
    # pinned, at the seam where it lives.

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
      # The rail leaves it "pour inspection" when the rewrite lost its determinism. Sweeping it would
      # erase the only evidence of a failure that cannot be reproduced from a message.
      d = a_work_dir()
      assert :kept_for_inspection = ProjectPublish.sweep_work(d, 6)
      assert File.dir?(d), "exit 6 must KEEP its clone for inspection"
      File.rm_rf(d)
    end
  end
end
