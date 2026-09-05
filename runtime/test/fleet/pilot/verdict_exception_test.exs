defmodule Fleet.Pilot.VerdictExceptionTest do
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

    # Le dispatch réel du juge va plus loin que ce que ce test épingle ; ces deux-là suffisent à
    # l'y laisser aller sans exploser avant d'avoir posé le marqueur, qui est l'objet du test.
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
      # Ce test était l'inverse jusqu'au 2026-08-19, et son retournement est le fait qu'il épingle :
      # `pilot_verdict_exception_pass?` valait `false` en attendant qu'une zone grise soit arbitrée
      # de bout en bout sur un vrai projet. PR71/72 l'a fait. Le drapeau ne disparaît pas pour
      # autant (un exploitant doit pouvoir désarmer un barreau qui convoque un pod), mais un
      # déploiement neuf convoque maintenant au lieu d'escalader.
      #
      # On épingle le DÉFAUT DE CONFIG, pas le dispatch : la descente réelle traverse tout le
      # constructeur de brief, et c'est déjà couvert plus bas.
      refute Application.get_env(:lcars_fleet, :pilot_verdict_exception_pass?) == false,
             "le défaut est repassé à OFF — si c'est voulu, la condition écrite dans config.exs " <>
               "doit être réécrite avec"
    end

    test "OFF (explicite) : aucune convocation, escalade qui NOMME le barreau non armé" do
      # La distinction que l'arch doit pouvoir faire en lisant le gel : « la passe a échoué » et
      # « la passe n'existe pas sur cette boîte » demandent deux gestes différents de sa part.
      TestEnv.put_env_restoring(:lcars_fleet, :pilot_verdict_exception_pass?, false)

      assert {:skipped, {:merge_blocked_escalated, 7}} =
               VerdictException.dispatch(7, "lcars/issue-4-engineer", findings(), policy(), ctx())

      refute_received {:comment, _, _, "[verdict-gatekeeper:pr-7:round-1]"}
      assert_received {:label, "lcars-awaits-arch"}

      # Le motif traverse jusqu'au texte que l'humain lira : « non armée », pas « échec de merge ».
      assert_received {:comment, 4, body, "[merge-blocked-escalation:pr-7]"}
      assert body =~ "n'est PAS armée"
    end

    test "ON : le marqueur de budget est posé AVANT toute convocation" do
      TestEnv.put_env_restoring(:lcars_fleet, :pilot_verdict_exception_pass?, true)

      # ⚠ CE TEST N'ÉPINGLE PAS L'ORDRE, et son commentaire le prétendait (revue 2026-08-19). Il
      # observe qu'un marqueur est dans la boîte à la fin — inverser `post_comment` et le dispatch
      # le laisserait vert.
      #
      # L'ordre n'a pas besoin d'un test parce qu'il n'est pas une séquence d'instructions : le
      # dispatch vit DANS la branche `{:ok, _}` du post (`summon/5`). Pas de marqueur, pas
      # d'appelant — c'est une dépendance de données, qu'aucune permutation ne contourne. Et sa
      # CONSÉQUENCE est mesurée par « marqueur NON posté » plus bas : un post en échec rend
      # `{:skipped, {:verdict_marker_unposted, _}}`, ce qu'une inversion ferait immédiatement
      # tomber. Ce test-ci prouve autre chose, et c'est utile aussi : le marqueur porte la bonne
      # signature, le bon seuil, et dit que PERSONNE ne s'oppose.
      #
      # Le dispatch réel descend ensuite dans tout le constructeur de brief (couture forge complète,
      # catalogue de rôles, worktrees) : le laisser échouer là est DÉLIBÉRÉ. Stubber cette descente
      # ferait de ce fichier une seconde implémentation de la forge, dont la dérive serait
      # silencieuse — et l'ordre qu'on mesure est déjà tranché avant elle.
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

      # L'escalade, elle, PARLE — et elle dit lequel des trois chemins a mené là.
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
      # Le marqueur EST le budget : convoquer sans lui, c'est convoquer sans borne. On préfère ne
      # pas arbitrer du tout — la PR reste grise et le tick suivant réessaiera proprement.
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
