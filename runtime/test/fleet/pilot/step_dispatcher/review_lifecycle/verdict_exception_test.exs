defmodule Fleet.Pilot.StepDispatcher.ReviewLifecycle.VerdictExceptionTest do
  use ExUnit.Case, async: false

  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.Ctx
  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.VerdictException
  alias Fleet.TestEnv

  defmodule Forge do
    def count_comments_marked(_repo, _pr, _marker, opts),
      do: Keyword.get(opts, :_test_markers, {:ok, 0})

    def post_comment(_repo, pr, body, opts) do
      send(self(), {:comment, pr, body, Keyword.get(opts, :dedup_signature)})
      Keyword.get(opts, :_test_comment, {:ok, %{"id" => 1}})
    end

    def add_label(_repo, _n, label, _opts) do
      send(self(), {:label, label})
      {:ok, %{}}
    end

    def remove_label(_repo, _n, label, _opts) do
      send(self(), {:label_removed, label})
      {:ok, %{}}
    end

    def get_issue(_repo, _n, _opts), do: {:ok, %{"state" => "open"}}

    # Enough forge methods to reach marker publication; later judge execution is not proved.
    def get_route(_repo, _n, _opts), do: :none
    def get_pull(_repo, _n, _opts), do: {:ok, %{"number" => 7}}
  end

  defp ctx(opts \\ []) do
    %Ctx{
      forge: Forge,
      loader: Fleet.CapProfile,
      workflow_map_loader: &Fleet.Workflow.Loader.load!/2,
      spawner: Fleet.Spawner,
      task_queue: Fleet.TaskQueue,
      resolver: fn _, _ -> {:ok, nil} end,
      repo: "fleet/demo",
      forge_opts: opts,
      wake_recovery: fn _, _, _ -> :ok end,
      opts: [repo: "fleet/demo", pr_base_branch: "main"]
    }
  end

  defp findings, do: %{"qualifier" => %{"findings" => [%{"severity" => "critical"}]}}
  defp policy, do: %{"block_at" => "critical"}

  describe "le drapeau — une passe non armée s'annonce comme telle" do
    test "le DÉFAUT est désormais ARMÉ — la condition de bascule est remplie" do
      # Only checks that the loaded config value is not false (nil also passes).
      # This neither proves dispatch nor tests the code-level default.
      refute Application.get_env(:lcars_fleet, :pilot_verdict_exception_pass?) == false,
             "le défaut est repassé à OFF — si c'est voulu, la condition écrite dans config.exs " <>
               "doit être réécrite avec"
    end

    test "OFF (explicite) : aucune convocation, escalade qui NOMME le barreau non armé" do
      # Disabled and failed passes need distinct escalation messages.
      TestEnv.put_env_restoring(:lcars_fleet, :pilot_verdict_exception_pass?, false)

      assert {:skipped, {:merge_blocked_escalated, 7}} =
               VerdictException.dispatch(7, "lcars/issue-4-engineer", findings(), policy(), ctx())

      refute_received {:comment, _, _, "[verdict-gatekeeper:pr-7:round-1]"}
      assert_received {:label, "lcars-awaits-arch"}

      assert_received {:comment, 4, body, "[merge-blocked-escalation:pr-7]"}
      assert body =~ "n'est PAS armée"
    end

    test "ON : le marqueur de budget porte la bonne signature, le bon seuil, et dit que PERSONNE ne s'oppose" do
      TestEnv.put_env_restoring(:lcars_fleet, :pilot_verdict_exception_pass?, true)

      # Checks marker signature/content after the call; selective receive does not prove ordering.
      # Downstream exceptions are deliberately rescued, so successful judge dispatch is unproved.
      # The failed-post case below checks the return, without a separate dispatch spy.
      try do
        VerdictException.dispatch(7, "lcars/issue-4-engineer", findings(), policy(), ctx())
      rescue
        _ -> :ok
      end

      assert_received {:comment, 7, body, "[verdict-gatekeeper:pr-7:round-1]"}
      assert body =~ "Zone grise"
      assert body =~ "`critical`"
      assert body =~ "Aucun juge", "le commentaire dit que PERSONNE ne s'oppose — c'est le fait"
    end
  end

  describe "le budget — une passe, puis l'humain" do
    setup do
      TestEnv.put_env_restoring(:lcars_fleet, :pilot_verdict_exception_pass?, true)
      :ok
    end

    test "marqueur déjà présent → escalade, pas une seconde passe" do
      assert {:skipped, {:merge_blocked_escalated, 7}} =
               VerdictException.dispatch(
                 7,
                 "lcars/issue-4-engineer",
                 findings(),
                 policy(),
                 ctx(_test_markers: {:ok, 1})
               )

      refute_received {:comment, _, _, "[verdict-gatekeeper:pr-7:round-1]"}

      assert_received {:comment, 4, body, "[merge-blocked-escalation:pr-7]"}
      assert body =~ "déjà été dépensée"
      assert body =~ "Aucun conflit git"
    end

    test "compte ILLISIBLE → escalade (ne pas savoir n'achète jamais une passe)" do
      assert {:skipped, {:merge_blocked_escalated, 7}} =
               VerdictException.dispatch(
                 7,
                 "lcars/issue-4-engineer",
                 findings(),
                 policy(),
                 ctx(_test_markers: {:error, :forge_down})
               )

      refute_received {:comment, _, _, "[verdict-gatekeeper:pr-7:round-1]"}
    end

    test "la décision pure est épinglée aux bornes" do
      assert :dispatch = VerdictException.decision({:ok, 0})
      assert :escalate = VerdictException.decision({:ok, 1})
      assert :escalate = VerdictException.decision({:ok, 9})
      assert :escalate = VerdictException.decision({:error, :whatever})
    end

    test "marqueur NON posté → aucune convocation" do
      # Checks the failed-post result. It does not observe a subsequent poll or spy on dispatch.
      assert {:skipped, {:verdict_marker_unposted, :boom}} =
               VerdictException.dispatch(
                 7,
                 "lcars/issue-4-engineer",
                 findings(),
                 policy(),
                 ctx(_test_comment: {:error, :boom})
               )
    end
  end
end
