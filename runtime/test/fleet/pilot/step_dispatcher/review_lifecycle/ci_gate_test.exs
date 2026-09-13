defmodule Fleet.Pilot.StepDispatcher.ReviewLifecycle.CiGateTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle
  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.CiGate
  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.Ctx

  # Configure PR and CI reads together; additional probes use separate injected callbacks.
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

  # Ignore must avoid both PR and CI reads.
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

  defp decide_with_lister(forge_opts, lister) do
    c = %{ctx(Forge, forge_opts) | opts: [list_dir_fun: lister]}
    CiGate.decide(42, "lcars/issue-7-engineer", c, fn -> :required end)
  end

  # Inject job state independently from PR age and status.
  defp decide_unclaimed(forge_opts, jobs, lister \\ nil) do
    lister = lister || fn "fleet/demo", ".gitea/workflows", _ -> {:ok, ["ci.yml"]} end

    c = %{
      ctx(Forge, forge_opts)
      | opts: [
          list_dir_fun: lister,
          runs_for_sha_fun: fn _repo, _sha, _f, _o -> {:ok, [%{"id" => 7}]} end,
          run_jobs_fun: fn _repo, 7, _o -> {:ok, jobs} end
        ]
    }

    CiGate.decide(42, "lcars/issue-7-engineer", c, fn -> :required end)
  end

  describe "un job que personne ne reclame" do
    # Bench responses used queued; waiting is a compatibility fixture, not an observed API guarantee.
    @queued [%{"status" => "queued", "runner_id" => 0, "labels" => ["ubuntu-latest"]}]
    @waiting [%{"status" => "waiting", "runner_id" => 0, "labels" => ["ubuntu-latest"]}]

    test "au-dela du delai court: escalade en NOMMANT le label, sans attendre 45 min" do
      # A ten-minute-old PR crosses the short deadline but not the generic deadline.
      stale = Forge.iso_ago(10 * 60)

      assert {:escalate, {:ci_stalled, :unclaimed}, msg} =
               decide_unclaimed([_ci: {:ok, :none}, _updated_at: stale], @queued)

      # Include the requested runner label so the escalation identifies what to investigate.
      assert msg =~ "ubuntu-latest"
      assert msg =~ "AUCUN RUNNER"
    end

    test "sous le delai court: on attend, un runner met des secondes a reclamer" do
      fresh = Forge.iso_ago(30)

      assert {:wait, :ci_pending} =
               decide_unclaimed([_ci: {:ok, :none}, _updated_at: fresh], @queued)
    end

    test "le nom INTERNE `waiting` est accepte aussi — une conversion n'est pas un contrat" do
      stale = Forge.iso_ago(10 * 60)

      assert {:escalate, {:ci_stalled, :unclaimed}, _msg} =
               decide_unclaimed([_ci: {:ok, :none}, _updated_at: stale], @waiting)
    end

    test "job ASSIGNE: c'est du travail, pas une impasse — meme vieux" do
      # Queued status alone does not mean unclaimed when runner_id is present.
      stale = Forge.iso_ago(10 * 60)
      assigned = [%{"status" => "queued", "runner_id" => 3, "labels" => ["shell"]}]

      assert {:wait, :ci_pending} =
               decide_unclaimed([_ci: {:ok, :none}, _updated_at: stale], assigned)
    end

    test "aucun run lisible: on ne fabrique pas d'impasse, l'attente bornee reprend" do
      # Unreadable runs retain the generic wait, which can still expire later.
      stale = Forge.iso_ago(10 * 60)

      c = %{
        ctx(Forge, _ci: {:ok, :none}, _updated_at: stale)
        | opts: [
            list_dir_fun: fn "fleet/demo", ".gitea/workflows", _ -> {:ok, ["ci.yml"]} end,
            runs_for_sha_fun: fn _r, _s, _f, _o -> {:error, {:http, 500, "boom"}} end
          ]
      }

      assert {:wait, :ci_pending} =
               CiGate.decide(42, "lcars/issue-7-engineer", c, fn -> :required end)
    end

    test "AUCUN workflow: l'impasse d'origine passe AVANT — elle est plus precise" do
      # Missing workflow takes precedence over probing unclaimed jobs.
      lister = fn "fleet/demo", _dir, _ -> {:error, :not_found} end
      stale = Forge.iso_ago(10 * 60)

      assert {:escalate, {:ci_impossible, :no_workflow}, _} =
               decide_unclaimed([_ci: {:ok, :none}, _updated_at: stale], @waiting, lister)
    end
  end

  describe "the card governs" do
    test ":ignore short-circuits before touching the forge" do
      assert {:proceed, nil} = decide([], :ignore, ForbiddenForge)
    end
  end

  # Separate clients exercise report-capability presence and status-only compatibility.
  defmodule ForgeWithContexts do
    defdelegate get_pull(repo, n, opts),
      to: Fleet.Pilot.StepDispatcher.ReviewLifecycle.CiGateTest.Forge

    defdelegate iso_ago(age_sec), to: Fleet.Pilot.StepDispatcher.ReviewLifecycle.CiGateTest.Forge
    def commit_ci_state(_repo, _sha, opts), do: Keyword.get(opts, :_ci, {:ok, :none})

    def commit_ci_report(_repo, _sha, opts) do
      case Keyword.get(opts, :_ci, {:ok, :none}) do
        {:ok, state} -> {:ok, {state, Keyword.get(opts, :_contexts, [])}}
        other -> other
      end
    end
  end

  describe "6-140 — le vert ne dit pas QUI l'a produit" do
    test "les contextes remontent dans le FAIT remis au juge" do
      assert {:proceed, %{state: :success, contexts: ["CI / no-harness-yet (pull_request)"]}} =
               decide(
                 [_ci: {:ok, :success}, _contexts: ["CI / no-harness-yet (pull_request)"]],
                 :required,
                 ForgeWithContexts
               )
    end

    test "un seam qui ignore la lecture des contextes garde son contrat, contextes VIDES" do
      assert {:proceed, %{state: :success, contexts: []}} = decide(_ci: {:ok, :success})
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
    # Keep this expected threshold independent from production so changing the constant fails the test.
    @deadline_sec 45 * 60

    test "l'echeance EST de 45 minutes — le seul endroit qui nomme le nombre" do
      assert CiGate.pending_deadline_sec() == @deadline_sec,
             "l'echeance a bouge : si c'est voulu, ce temoin est l'endroit ou on le dit"
    end

    test "pending past the deadline escalates instead of waiting one more tick forever" do
      stale = Forge.iso_ago(@deadline_sec + 60)

      assert {:escalate, {:ci_stalled, :pending}, message} =
               decide(_ci: {:ok, :pending}, _updated_at: stale)

      assert message =~ "runner"
    end

    test "an absent rail past the deadline escalates under its OWN name (:none, not :pending)" do
      stale = Forge.iso_ago(@deadline_sec + 60)

      assert {:escalate, {:ci_stalled, :none}, _} = decide(_ci: {:ok, :none}, _updated_at: stale)
    end

    test "AUCUN workflow dans le depot → impasse nommee AU PREMIER TICK, pas au bout de 45 min" do
      # A readable absence of workflow names must not spend the full runner-wait interval.
      lister = fn "fleet/demo", _dir, _opts -> {:error, :not_found} end

      assert {:escalate, {:ci_impossible, :no_workflow}, msg} =
               decide_with_lister([_ci: {:ok, :none}], lister)

      # Mention both adding a workflow and choosing an explicit ignore policy.
      assert msg =~ "AUCUN WORKFLOW"
      assert msg =~ ".gitea/workflows"
      assert msg =~ "ignore"
    end

    test "un workflow declare → l'attente bornee reprend ses droits (rien ne change)" do
      lister = fn
        "fleet/demo", ".gitea/workflows", _ -> {:ok, ["ci.yml"]}
        "fleet/demo", _, _ -> {:error, :not_found}
      end

      assert {:wait, :ci_pending} = decide_with_lister([_ci: {:ok, :none}], lister)
    end

    test "`.github/workflows` compte aussi — Gitea sert les deux" do
      lister = fn
        "fleet/demo", ".github/workflows", _ -> {:ok, ["build.yaml"]}
        "fleet/demo", _, _ -> {:error, :not_found}
      end

      assert {:wait, :ci_pending} = decide_with_lister([_ci: {:ok, :none}], lister)
    end

    test "un repertoire sans fichier de workflow n'est pas un rail" do
      # Directory presence alone is insufficient; the gate looks for YAML filenames.
      lister = fn "fleet/demo", _dir, _ -> {:ok, ["README.md", ".keep"]} end

      assert {:escalate, {:ci_impossible, :no_workflow}, _} =
               decide_with_lister([_ci: {:ok, :none}], lister)
    end

    test "listing ILLISIBLE → on attend : inconnu n'est pas absent" do
      # An unreadable listing is not evidence of missing workflows; this fixture is below the deadline.
      lister = fn "fleet/demo", _dir, _ -> {:error, {:http, 500, "boom"}} end

      assert {:wait, :ci_pending} = decide_with_lister([_ci: {:ok, :none}], lister)
    end

    test "just under the deadline still waits — the bound is a threshold, not a mood" do
      fresh = Forge.iso_ago(@deadline_sec - 60)
      assert {:wait, :ci_pending} = decide(_ci: {:ok, :pending}, _updated_at: fresh)
    end

    test "an unreadable date waits rather than escalating on a date it could not read" do
      # Preserve the choice not to escalate on an unreadable date, while naming the unbounded wait.
      assert {:wait, {:ci_deadline_unreachable, :no_pull_date}} =
               decide(_ci: {:ok, :pending}, _updated_at: "pas-une-date")
    end

    test "TEMOIN — une date LISIBLE et fraiche rend le motif ordinaire, pas celui-la" do
      # Fresh readable dates distinguish the ordinary wait from the missing-clock case.
      fresh = Forge.iso_ago(60)
      assert {:wait, :ci_pending} = decide(_ci: {:ok, :pending}, _updated_at: fresh)
    end

    test "le motif hors-d'atteinte porte l'etiquette de sa porte — il n'invente pas un mur" do
      # Distinct reasons share the existing CI wait label.
      assert Fleet.Labels.wait_for({:ci_deadline_unreachable, :no_pull_date}) ==
               Fleet.Labels.wait_for({:ci_unreadable, :timeout})
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

  # Exercise authored card → loader → policy reader, beyond tests that inject a policy atom.
  describe "issue_card_ci/2 — la carte arme reellement la porte" do
    defmodule RoutingForge do
      @moduledoc false
      def get_route(_repo, 7, _opts), do: {:ok, {"standard-qa", "review"}}
      def get_route(_repo, 9, _opts), do: {:ok, {"workshop-direct", "build"}}
      def get_route(_repo, _n, _opts), do: :none
    end

    defp card_ctx(loader, opts \\ []) do
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
        opts: opts
      }
    end

    defp canon_loader do
      canon = Application.app_dir(:lcars_fleet, "priv/catalogue/workflow/workflow_maps")
      fn name -> Fleet.Workflow.Loader.load!(name, workflow_maps_root: canon) end
    end

    test "une carte canon qui declare `ci: required` rend :required — bout en bout" do
      # Use the real card loader's map, not an already-wrapped result.
      # Assert no warning: the malformed-policy fallback also returns required and could mask a bad read.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert ReviewLifecycle.issue_card_ci(
                   "lcars/issue-7-engineer",
                   card_ctx(canon_loader())
                 ) == :required
        end)

      refute log =~ "no readable `ci` policy",
             "standard-qa declare `ci: required` : ce :required doit venir de la LECTURE de la " <>
               "carte, pas de la clause de garde qui rend la meme valeur quand elle ne comprend pas"
    end

    test "une carte canon qui declare `ci: ignore` rend :ignore — la derogation traverse aussi" do
      # An explicit ignore card must take the permissive path, unlike an undeclared policy.
      assert ReviewLifecycle.issue_card_ci(
               "lcars/issue-9-scribe",
               card_ctx(canon_loader())
             ) == :ignore
    end

    test "une carte qui ne declare RIEN ne prend PAS la branche permissive" do
      # A malformed injected card bypasses schema validation; runtime must require CI and warn.
      loader = fn _ -> %{"name" => "muette", "steps" => %{}} end

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert ReviewLifecycle.issue_card_ci(
                   "lcars/issue-7-engineer",
                   card_ctx(loader)
                 ) == :required
        end)

      assert log =~ "no readable `ci` policy",
             "l'alarme doit etre DITE : une carte qui contourne le schema est un defaut, pas un cas"
    end

    @tag :tmp_dir
    test "sans route gravee, la policy suit la carte du PROJET — comme le jury, enfin", %{
      tmp_dir: tmp
    } do
      # No engraved route must use the project's CI policy, as jury lookup does.
      proj = Path.join(tmp, "demo")
      File.mkdir_p!(proj)

      # Write the card before declaring it: declaration validates that an explicit card is loadable.
      maps = Path.join(tmp, "maps")
      File.mkdir_p!(maps)

      File.write!(Path.join(maps, "gated.yaml"), """
      kind: WorkflowMap
      metadata:
        name: gated
      spec:
        max_rework_rounds: 1
        jury: [qualifier]
        ci: required
        steps:
          only:
            role: engineer
      """)

      :ok =
        Fleet.Project.Declaration.write(proj,
          justification: "x",
          workflow_map: "gated",
          workflow_maps_root: maps
        )

      ctx = card_ctx(canon_loader(), code_root: tmp, workflow_maps_root: maps)

      assert ReviewLifecycle.issue_card_ci(
               "lcars/issue-8-engineer",
               ctx
             ) == :required
    end
  end
end
