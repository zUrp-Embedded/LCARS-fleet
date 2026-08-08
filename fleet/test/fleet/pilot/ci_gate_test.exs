defmodule Fleet.Pilot.StepDispatcher.ReviewLifecycle.CiGateTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.CiGate
  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.Ctx

  # The forge seam, reduced to the two reads the gate makes. Both answers are driven by `forge_opts`
  # so a test states its world in one place instead of defining a module per case.
  defmodule Forge do
    def get_pull(_repo, n, opts) do
      case Keyword.get(opts, :_pull, :default) do
        :default ->
          {:ok,
           %{
             "number" => n,
             "head" => %{"sha" => "cafebabe1234567890"},
             "updated_at" => Keyword.get(opts, :_updated_at, iso_now(0))
           }}

        other ->
          other
      end
    end

    def commit_ci_state(_repo, _sha, opts), do: Keyword.get(opts, :_ci, {:ok, :none})

    defp iso_now(age_sec) do
      DateTime.utc_now() |> DateTime.add(-age_sec, :second) |> DateTime.to_iso8601()
    end

    def iso_ago(age_sec), do: iso_now(age_sec)
  end

  # A forge that must NEVER be called: the `ignore` policy has to short-circuit BEFORE any network
  # read, otherwise "the card does not require the CI" would still cost two forge calls per tick.
  defmodule ForbiddenForge do
    def get_pull(_repo, _n, _opts), do: raise("get_pull called under an :ignore policy")
    def commit_ci_state(_repo, _sha, _opts), do: raise("commit_ci_state called under :ignore")
  end

  defp ctx(forge, forge_opts) do
    %Ctx{
      forge: forge,
      loader: nil,
      workflow_map_loader: fn _ -> {:ok, %{}} end,
      spawner: nil,
      task_queue: nil,
      resolver: fn _, _ -> {:ok, %{}} end,
      repo: "fleet/demo",
      forge_opts: forge_opts,
      wake_recovery: fn _, f, _ -> f.() end,
      opts: []
    }
  end

  defp decide(forge_opts, policy \\ :required, forge \\ Forge),
    do: CiGate.decide(42, "lcars/issue-7-engineer", ctx(forge, forge_opts), fn -> policy end)

  describe "the card governs" do
    test ":ignore short-circuits before touching the forge" do
      assert {:proceed, nil} = decide([], :ignore, ForbiddenForge)
    end
  end

  describe "the three states" do
    test "success -> proceed, and the FACT carries the sha the gate measured" do
      assert {:proceed, %{state: :success, sha: "cafebabe1234567890"}} =
               decide(_ci: {:ok, :success})
    end

    test "failure -> refuse, and the message names the sha (the marker keys on it)" do
      assert {:refuse, :ci_red, message} = decide(_ci: {:ok, :failure})
      assert message =~ "cafebabe"
      assert message =~ "ROUGE"
    end

    test "pending on a fresh head -> bounded wait, no judge" do
      assert {:wait, :ci_pending} = decide(_ci: {:ok, :pending})
    end

    test "NO status at all is NOT success — it waits like pending" do
      assert {:wait, :ci_pending} = decide(_ci: {:ok, :none})
    end
  end

  describe "the deadline is the point" do
    test "pending past the deadline escalates instead of waiting one more tick forever" do
      stale = Forge.iso_ago(CiGate.pending_deadline_sec() + 60)

      assert {:escalate, {:ci_stalled, :pending}, message} =
               decide(_ci: {:ok, :pending}, _updated_at: stale)

      assert message =~ "runner"
    end

    test "an absent rail past the deadline escalates under its OWN name (:none, not :pending)" do
      stale = Forge.iso_ago(CiGate.pending_deadline_sec() + 60)

      assert {:escalate, {:ci_stalled, :none}, _} = decide(_ci: {:ok, :none}, _updated_at: stale)
    end

    test "just under the deadline still waits — the bound is a threshold, not a mood" do
      fresh = Forge.iso_ago(CiGate.pending_deadline_sec() - 60)
      assert {:wait, :ci_pending} = decide(_ci: {:ok, :pending}, _updated_at: fresh)
    end

    test "an unreadable date waits rather than escalating on a date it could not read" do
      assert {:wait, :ci_pending} = decide(_ci: {:ok, :pending}, _updated_at: "pas-une-date")
    end
  end

  describe "unknown is never green" do
    test "an unreadable PR defers, it does not guess a state" do
      assert {:wait, {:ci_head_unreadable, :boom}} = decide(_pull: {:error, :boom})
    end

    test "a PR without a head sha defers under its own name" do
      assert {:wait, {:ci_head_unreadable, {:no_head_sha, _}}} =
               decide(_pull: {:ok, %{"number" => 42}})
    end

    test "an unreadable CI status defers — assuming green would spend a jury on unmeasured code" do
      assert {:wait, {:ci_unreadable, :timeout}} = decide(_ci: {:error, :timeout})
    end
  end

  # LA JOINTURE, ET ELLE N'ETAIT TENUE PAR PERSONNE. Les tests ci-dessus bouchent la policy
  # (`fn -> :required end`) : ils prouvent que la porte GATE sur `:required`, pas qu'une carte le
  # produise. `LoaderV25Test` prouve l'autre bout — `spec.ci` traverse `normalize/1`. Entre les
  # deux, `issue_card_ci/2` compare a un LITTERAL, et remplacer `"required"` par `"requis"` laissait
  # les 2443 tests verts (mesure 2026-08-08).
  #
  # C'est la classe « ecrivain et lecteur en desaccord d'identite » : la carte ECRIT un token, le
  # lecteur en attend un autre, et la porte se desarme sans que rien ne rougisse.
  describe "issue_card_ci/2 — la carte arme reellement la porte" do
    defmodule RoutingForge do
      @moduledoc false
      def get_route(_repo, 7, _opts), do: {:ok, {"standard-qa", "review"}}
      def get_route(_repo, _n, _opts), do: :none
    end

    defp card_ctx(loader) do
      %Ctx{
        forge: RoutingForge,
        loader: nil,
        workflow_map_loader: loader,
        spawner: nil,
        task_queue: nil,
        resolver: fn _, _ -> {:ok, %{}} end,
        repo: "fleet/demo",
        forge_opts: [],
        wake_recovery: fn _, f, _ -> f.() end,
        opts: []
      }
    end

    test "une carte canon qui declare `ci: required` rend :required — bout en bout" do
      # Le loader CANON, pas un litteral recopie : si la carte cesse de declarer `ci`, ou si le
      # loader cesse de le porter, ce test tombe.
      canon =
        Application.app_dir(:lcars_fleet, "priv/catalogue/workflow/canon/workflow_maps")

      # `safe_load/2` enveloppe DEJA le retour du loader : rendre `{:ok, map}` ici produirait
      # `{:ok, {:ok, map}}` et la clause `when is_map(map)` echouerait — un `:ignore` par forme,
      # pas par contenu.
      loader = fn name -> Fleet.Workflow.Loader.load!(name, workflow_maps_root: canon) end

      assert Fleet.Pilot.StepDispatcher.ReviewLifecycle.issue_card_ci(
               "lcars/issue-7-engineer",
               card_ctx(loader)
             ) == :required
    end

    test "une carte qui ne declare RIEN garde le rail d'avant la porte" do
      loader = fn _ -> %{"name" => "muette", "steps" => %{}} end

      assert Fleet.Pilot.StepDispatcher.ReviewLifecycle.issue_card_ci(
               "lcars/issue-7-engineer",
               card_ctx(loader)
             ) == :ignore
    end
  end
end
