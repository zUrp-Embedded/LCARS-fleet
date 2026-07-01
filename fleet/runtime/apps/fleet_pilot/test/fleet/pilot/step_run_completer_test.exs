defmodule Fleet.Pilot.StepRunCompleterTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.StepRunCompleter

  # Forge stub qui ENREGISTRE l'ordre des appels (send au test) pour vérifier
  # la séquence canonique §5 : comment → state → (close|assignee) → unlock.
  defmodule OrderForge do
    def post_comment(_repo, _n, body, opts) do
      send(self(), {:call, :comment, body, opts[:dedup_signature]})
      {:ok, :posted}
    end

    def set_assignee(_repo, _n, login, _opts) do
      send(self(), {:call, :assignee, login})
      {:ok, :set}
    end

    def close_issue(_repo, _n, _opts) do
      send(self(), {:call, :close})
      {:ok, :closed}
    end

    def remove_label(_repo, _n, label, _opts) do
      send(self(), {:call, :unlock, label})
      {:ok, :removed}
    end

    def post_route(_repo, _n, pipeline, step, _opts) do
      send(self(), {:call, :route, pipeline, step})
      {:ok, :posted}
    end
  end

  defmodule StubDeliverable do
    def publish(opts) do
      send(self(), {:published, opts})
      {:ok, %{commit_sha: "deadbeef", pushed?: true, mode: :git_native}}
    end
  end

  defmodule FailDeliverable do
    def publish(_opts), do: {:error, :base_not_ancestor}
  end

  # Forge stub PR-natif (Corr.3) : enregistre les appels PR (send au test). Rend le contrat REEL
  # de `ForgeClient` : `post_review`/`merge_pr`/`request_review` → `:ok` (pas `{:ok, _}`).
  defmodule PrForge do
    def open_pr(_repo, head, base, _title, opts) do
      send(self(), {:open_pr, head, base, opts[:body]})
      {:ok, 7}
    end

    def post_review(_repo, pr, event, body, _opts) do
      send(self(), {:review, pr, event, body})
      :ok
    end

    # Sceau gatekeeper (F-arch-MCP) : promote poste le commentaire de fin avant le merge.
    def post_comment(_repo, n, body, opts) do
      send(self(), {:comment, n, body, opts})
      {:ok, 1}
    end

    def merge_pr(_repo, pr, _opts) do
      send(self(), {:merge, pr})
      :ok
    end
  end

  defmodule PrFailForge do
    def open_pr(_r, _h, _b, _t, _o), do: {:error, {:http, 422, "no commits between"}}
    def post_review(_r, _pr, _e, _b, _o), do: {:error, {:http, 500, "boom"}}
    # Le sceau commente OK puis le merge échoue (409) → {:error, {:merge, _}} fail-loud.
    def post_comment(_r, _n, _b, _o), do: {:ok, 1}
    def merge_pr(_r, _pr, _o), do: {:error, {:http, 409, "not fast-forward"}}
  end

  # Forge stub COMPLET pour l'orchestrateur `complete_pr/2` (toutes les primitives PR + pont issue).
  defmodule OrchForge do
    def open_pr(_repo, head, base, _title, opts) do
      send(self(), {:open_pr, head, base, opts[:body]})
      {:ok, 7}
    end

    def get_pr_for_branch(_repo, head, base, _opts) do
      send(self(), {:get_pr, head, base})
      {:ok, 7}
    end

    def post_review(_repo, pr, event, body, _opts) do
      send(self(), {:review, pr, event, body})
      :ok
    end

    def request_review(_repo, pr, reviewers, _opts) do
      send(self(), {:request_review, pr, reviewers})
      :ok
    end

    def merge_pr(_repo, pr, _opts) do
      send(self(), {:merge, pr})
      :ok
    end

    def set_assignee(_repo, n, login, _opts) do
      send(self(), {:assignee, n, login})
      {:ok, :set}
    end

    def remove_label(_repo, n, label, _opts) do
      send(self(), {:unlock, n, label})
      {:ok, :removed}
    end

    # Voix de l'eng (info sortante) : le summary du producteur posté en commentaire PR.
    def post_comment(_repo, pr, body, _opts) do
      send(self(), {:comment, pr, body})
      {:ok, :posted}
    end
  end

  # PR introuvable (le juge tombe avant tout review) ; merge FF impossible (open ok, merge 409).
  defmodule NoPrForge do
    def get_pr_for_branch(_r, _h, _b, _o), do: {:error, :pr_not_found}
  end

  defmodule MergeFailForge do
    def open_pr(_r, _h, _b, _t, _o), do: {:ok, 7}
    # Sceau : commente OK puis merge 409 → {:error, {:merge, _}} fail-loud.
    def post_comment(_r, _n, _b, _o), do: {:ok, 1}
    def merge_pr(_r, _pr, _o), do: {:error, {:http, 409, "not fast-forward"}}
  end

  defp base_step_run(extra \\ %{}) do
    Map.merge(
      %{
        repo: "lordzurp/lcars-test",
        issue_number: 42,
        role: "engineer",
        deliverable_opts: %{mode: :git_native, workspace: "/tmp/ws", base_sha: "cafe"}
      },
      extra
    )
  end

  defp seams do
    [deliverable: StubDeliverable, forge_client: OrderForge, forge_opts: []]
  end

  defp pr_step_run(extra \\ %{}) do
    base_step_run(
      Map.merge(
        %{
          deliverable_opts: %{
            mode: :git_native,
            workspace: "/tmp/ws",
            base_sha: "cafe",
            target_branch: "feature/issue-42"
          }
        },
        extra
      )
    )
  end

  describe "complete/2 — 1-step terminal (next_assignee nil)" do
    test "publie, comment signé, CLOSE, unlock — dans l'ordre §5" do
      assert {:ok, :completed} = StepRunCompleter.complete(base_step_run(), seams())

      # Étape 1 : publish appelé avec les opts du livrable
      assert_received {:published, %{mode: :git_native, base_sha: "cafe"}}

      # Étapes 2→4 dans l'ordre canonique (mailbox FIFO ; étape 3 state:* retirée — #5.2 D4)
      assert_received {:call, :comment, body, sig}
      assert sig == "[step_run:engineer:deadbeef]"
      assert body =~ "[step_run:engineer:deadbeef]"

      assert_received {:call, :close}
      assert_received {:call, :unlock, "lcars-in-flight"}

      # Pas de réassignation en terminal
      refute_received {:call, :assignee, _}
    end

    test "comment signé porte la signature en dedup_signature (replay-safe)" do
      StepRunCompleter.complete(base_step_run(), seams())
      assert_received {:call, :comment, _body, "[step_run:engineer:deadbeef]"}
    end
  end

  describe "complete/2 — multi-step (next_assignee présent, branche A2)" do
    test "publie, comment, AVANCE (pas de close ni set_assignee, #8.A), unlock" do
      step_run = base_step_run(%{next_assignee: "qualifier"})
      assert {:ok, :reassigned} = StepRunCompleter.complete(step_run, seams())

      assert_received {:call, :comment, _, _}

      # #8.A : l'avance N'écrase PLUS l'assignee (= humain) ; le next-rôle est dérivé de la route au
      # dispatch. (Ici pas de contexte carte → pas de route non plus, cf. cas défensif ci-dessous.)
      refute_received {:call, :assignee, _}
      assert_received {:call, :unlock, "lcars-in-flight"}
      refute_received {:call, :close}
    end

    test "avance avec contexte carte → grave la ROUTE du step suivant (sans set_assignee, #8.A)" do
      step_run =
        base_step_run(%{
          next_assignee: "qualifier",
          pipeline: "poc-cycle",
          next_step: "spec-review"
        })

      assert {:ok, :reassigned} = StepRunCompleter.complete(step_run, seams())

      # #8.A : l'avance grave la ROUTE du step suivant ; l'assignee (humain) N'est PLUS touché.
      assert_received {:call, :route, "poc-cycle", "spec-review"}
      refute_received {:call, :assignee, _}
    end

    test "reassign sans contexte carte → pas de post_route (defensif)" do
      step_run = base_step_run(%{next_assignee: "qualifier"})
      assert {:ok, :reassigned} = StepRunCompleter.complete(step_run, seams())
      refute_received {:call, :route, _, _}
    end
  end

  describe "complete/2 — sans livrable git (juge en payload, step_run_sha fourni)" do
    test "utilise step_run_sha comme signature, pas d'appel publish" do
      step_run =
        base_step_run(%{deliverable_opts: nil, step_run_sha: "verdict-001"})

      assert {:ok, :completed} = StepRunCompleter.complete(step_run, seams())
      refute_received {:published, _}
      assert_received {:call, :comment, _body, "[step_run:engineer:verdict-001]"}
    end

    test "erreur si ni livrable ni step_run_sha" do
      step_run = base_step_run(%{deliverable_opts: nil})

      assert {:error, {:publish, :no_deliverable_no_step_run_sha}} =
               StepRunCompleter.complete(step_run, seams())
    end
  end

  describe "complete/2 — propagation d'erreur (arrêt avant les étapes suivantes)" do
    test "publish échoue → {:error, {:publish, _}}, aucune écriture forge" do
      opts = Keyword.put(seams(), :deliverable, FailDeliverable)

      assert {:error, {:publish, :base_not_ancestor}} =
               StepRunCompleter.complete(base_step_run(), opts)

      refute_received {:call, :comment, _, _}
      refute_received {:call, :unlock, _}
    end

    test "comment échoue → {:error, {:comment, _}}, pas de state/close/unlock" do
      defmodule CommentFailForge do
        def post_comment(_r, _n, _b, _o), do: {:error, {:http, 500, "boom"}}
      end

      opts = Keyword.put(seams(), :forge_client, CommentFailForge)

      assert {:error, {:comment, {:http, 500, "boom"}}} =
               StepRunCompleter.complete(base_step_run(), opts)
    end
  end

  describe "open_deliverable_pr/2 — engineer → PR (Corr.3 PR-natif)" do
    test "push la feature-branch + ouvre la PR feature→base avec Closes #N" do
      opts = [deliverable: StubDeliverable, forge_client: PrForge, forge_opts: []]

      assert {:ok, %{commit_sha: "deadbeef", pr_number: 7}} =
               StepRunCompleter.open_deliverable_pr(pr_step_run(), opts)

      assert_received {:published, %{target_branch: "feature/issue-42"}}
      assert_received {:open_pr, "feature/issue-42", "main", body}
      assert body =~ "Closes #42"
    end

    test "base_branch override" do
      opts = [deliverable: StubDeliverable, forge_client: PrForge, forge_opts: []]

      assert {:ok, _} =
               StepRunCompleter.open_deliverable_pr(pr_step_run(%{base_branch: "develop"}), opts)

      assert_received {:open_pr, "feature/issue-42", "develop", _}
    end

    test "publish échoue → {:error, {:publish, _}}, PAS de PR ouverte" do
      opts = [deliverable: FailDeliverable, forge_client: PrForge, forge_opts: []]

      assert {:error, {:publish, :base_not_ancestor}} =
               StepRunCompleter.open_deliverable_pr(pr_step_run(), opts)

      refute_received {:open_pr, _, _, _}
    end

    test "open_pr échoue → {:error, {:open_pr, _}}" do
      opts = [deliverable: StubDeliverable, forge_client: PrFailForge, forge_opts: []]

      assert {:error, {:open_pr, {:http, 422, _}}} =
               StepRunCompleter.open_deliverable_pr(pr_step_run(), opts)
    end
  end

  describe "record_review/2 + promote/2 (Corr.3 PR-natif)" do
    test "verdict :approve → review native APPROVED (corps généré du rôle)" do
      step_run = %{repo: "fleet/proj", pr_number: 7, role: "qualifier", review_event: :approve}

      assert {:ok, :reviewed} =
               StepRunCompleter.record_review(step_run, forge_client: PrForge, forge_opts: [])

      assert_received {:review, 7, :approve, body}
      assert body =~ "qualifier"
      assert body =~ "APPROUVÉ"
    end

    test "verdict :request_changes avec corps explicite" do
      step_run = %{
        repo: "fleet/proj",
        pr_number: 7,
        role: "reviewer",
        review_event: :request_changes,
        review_body: "il manque un test de la branche d'erreur"
      }

      assert {:ok, :reviewed} =
               StepRunCompleter.record_review(step_run, forge_client: PrForge, forge_opts: [])

      assert_received {:review, 7, :request_changes, "il manque un test de la branche d'erreur"}
    end

    test "record_review propage l'erreur forge" do
      step_run = %{repo: "fleet/proj", pr_number: 7, role: "qualifier", review_event: :approve}

      assert {:error, {:review, {:http, 500, _}}} =
               StepRunCompleter.record_review(step_run, forge_client: PrFailForge, forge_opts: [])
    end

    test "promote → comment gatekeeper + merge FF, {:ok, :promoted}" do
      step_run = %{
        repo: "fleet/proj",
        pr_number: 7,
        issue_number: 42,
        producer_branch: "lcars/issue-42-engineer"
      }

      assert {:ok, :promoted} =
               StepRunCompleter.promote(step_run, forge_client: PrForge, forge_opts: [])

      # Sceau (F-arch-MCP) : commentaire gatekeeper sur l'issue PUIS merge.
      assert_received {:comment, 42, _body, _opts}
      assert_received {:merge, 7}
    end

    test "promote : FF impossible (409) = invariant serial violé → {:merge, _} fail-loud" do
      step_run = %{
        repo: "fleet/proj",
        pr_number: 7,
        issue_number: 42,
        producer_branch: "lcars/issue-42-engineer"
      }

      assert {:error, {:merge, {:http, 409, _}}} =
               StepRunCompleter.promote(step_run, forge_client: PrFailForge, forge_opts: [])
    end
  end

  describe "complete_pr/2 — orchestrateur PR-natif (Corr.3)" do
    defp producer_step_run(intent, extra \\ %{}) do
      Map.merge(
        %{
          repo: "fleet/proj",
          issue_number: 42,
          role: "engineer",
          pr_role: :producer,
          intent: intent,
          next_assignee: nil,
          producer_branch: "lcars/issue-42-engineer",
          deliverable_opts: %{
            mode: :git_native,
            workspace: "/tmp/ws",
            base_sha: "cafe",
            target_branch: "lcars/issue-42-engineer"
          }
        },
        extra
      )
    end

    defp judge_step_run(intent, extra \\ %{}) do
      Map.merge(
        %{
          repo: "fleet/proj",
          issue_number: 42,
          role: "reviewer",
          pr_role: :judge,
          intent: intent,
          next_assignee: nil,
          producer_branch: "lcars/issue-42-engineer"
        },
        extra
      )
    end

    defp orch_opts(extra \\ []) do
      Keyword.merge(
        [deliverable: StubDeliverable, forge_client: OrchForge, forge_opts: []],
        extra
      )
    end

    test "producteur :advance → ouvre la PR, request_review(next), unlock l'ISSUE (pas de set_assignee)" do
      step_run = producer_step_run(:advance, %{next_assignee: "qualifier"})

      assert {:ok, :review_requested} = StepRunCompleter.complete_pr(step_run, orch_opts())

      assert_received {:open_pr, "lcars/issue-42-engineer", "main", body}
      assert body =~ "Closes #42"
      assert_received {:request_review, 7, ["qualifier"]}
      # producteur : le verrou est sur l'ISSUE (dispatch_issue) ; plus de set_assignee (PR-driven)
      refute_received {:assignee, _, _}
      assert_received {:unlock, 42, "lcars-in-flight"}
    end

    test "producteur avec :eng_summary → poste la VOIX de l'eng en commentaire PR (fin du « eng muet »)" do
      step_run =
        producer_step_run(:advance, %{
          next_assignee: "qualifier",
          eng_summary: "j'ai implémenté le décodeur, choisi un buffer circulaire"
        })

      assert {:ok, :review_requested} = StepRunCompleter.complete_pr(step_run, orch_opts())

      assert_received {:comment, 7, body}
      assert body =~ "j'ai implémenté le décodeur, choisi un buffer circulaire"
      assert body =~ "Note de l'engineer"
    end

    test "producteur SANS :eng_summary → AUCUN commentaire (pas de voix vide)" do
      assert {:ok, :review_requested} =
               StepRunCompleter.complete_pr(
                 producer_step_run(:advance, %{next_assignee: "qualifier"}),
                 orch_opts()
               )

      refute_received {:comment, _, _}
    end

    test "producteur :promote (terminal 1-step) → ouvre la PR, merge FF, unlock, pas de reassign" do
      assert {:ok, :promoted} =
               StepRunCompleter.complete_pr(producer_step_run(:promote), orch_opts())

      assert_received {:open_pr, "lcars/issue-42-engineer", "main", _}
      assert_received {:merge, 7}
      assert_received {:unlock, 42, _}
      refute_received {:assignee, _, _}
    end

    test "producteur :rework (son propre gate fail) → PAS de PR, unlock l'ISSUE (re-spawn via assignee)" do
      step_run = producer_step_run(:rework, %{next_assignee: "engineer"})

      assert {:ok, :rework_requested} = StepRunCompleter.complete_pr(step_run, orch_opts())

      refute_received {:open_pr, _, _, _}

      # pas de PR encore -> l'engineer reste assigne (Entry) et re-spawn au prochain tick ; unlock l'issue
      refute_received {:assignee, _, _}
      assert_received {:unlock, 42, _}
    end

    test "juge :advance → retrouve la PR, review APPROVED, request_review(next), unlock la PR" do
      step_run = judge_step_run(:advance, %{role: "qualifier", next_assignee: "reviewer"})

      assert {:ok, :review_requested} =
               StepRunCompleter.complete_pr(step_run, forge_client: OrchForge)

      assert_received {:get_pr, "lcars/issue-42-engineer", "main"}
      assert_received {:review, 7, :approve, _}
      assert_received {:request_review, 7, ["reviewer"]}
      refute_received {:assignee, _, _}
      # juge : le verrou est sur la PR (dispatch_review), pas l'issue
      assert_received {:unlock, 7, "lcars-in-flight"}
    end

    test "juge :promote (terminal) → review APPROVED puis merge FF, unlock la PR" do
      step_run = judge_step_run(:promote, %{role: "reviewer"})

      assert {:ok, :promoted} = StepRunCompleter.complete_pr(step_run, forge_client: OrchForge)

      assert_received {:get_pr, "lcars/issue-42-engineer", "main"}
      assert_received {:review, 7, :approve, _}
      assert_received {:merge, 7}
      assert_received {:unlock, 7, _}
    end

    test "juge :rework (gate fail) → review REQUEST_CHANGES, unlock la PR, PAS de merge" do
      step_run = judge_step_run(:rework, %{role: "reviewer", next_assignee: "engineer"})

      assert {:ok, :rework_requested} =
               StepRunCompleter.complete_pr(step_run, forge_client: OrchForge)

      assert_received {:get_pr, "lcars/issue-42-engineer", "main"}
      assert_received {:review, 7, :request_changes, _}
      refute_received {:assignee, _, _}
      assert_received {:unlock, 7, _}
      refute_received {:merge, _}
    end

    test "juge intent inattendu sans :review_event → review FAIL-CLOSED (REQUEST_CHANGES, jamais approve par omission)" do
      # Dérivation par intent (`:review_event` absent) : un intent qui n'est PAS un gate-pass explicite
      # (`:advance`/`:promote`) ne doit JAMAIS s'auto-approuver. Ici `:reviewed` (un juge no-carte qui
      # aurait perdu son verdict) tombe sur le catch-all fail-closed → REQUEST_CHANGES, pas APPROVED.
      # Sous l'ancien `_ -> :approve`, ce step_run validait par omission (le pire défaut pour un verdict).
      step_run = judge_step_run(:reviewed, %{role: "qualifier"})

      assert {:ok, :reviewed} = StepRunCompleter.complete_pr(step_run, forge_client: OrchForge)

      assert_received {:review, 7, :request_changes, _}
      refute_received {:merge, _}
    end

    test "②.1d producteur :review (no-carte) → ouvre PR, request_review(qualifier+reviewer), assigne l'humain, unlock issue+PR, PAS de merge" do
      step_run = producer_step_run(:review)

      assert {:ok, :review_requested} =
               StepRunCompleter.complete_pr(
                 step_run,
                 orch_opts(reviewer_roles: ["qualifier", "reviewer"])
               )

      assert_received {:open_pr, "lcars/issue-42-engineer", "main", body}
      assert body =~ "Closes #42"
      # DN §1.4 : qualifier + reviewer demandés d'un coup
      assert_received {:request_review, 7, ["qualifier", "reviewer"]}
      # ②.1e : l'humain commanditaire (id -un) est assigné à la PR (#7)
      assert_received {:assignee, 7, _human}
      # unlock DES DEUX : issue (1re livraison, verrou dispatch_issue) ET PR (re-livraison rework,
      # verrou dispatch_review) — idempotent, ne stuck ni l'un ni l'autre.
      assert_received {:unlock, 42, "lcars-in-flight"}
      assert_received {:unlock, 7, "lcars-in-flight"}
      # pas de merge ici : le merge est piloté par l'état-PR (dispatch_review)
      refute_received {:merge, _}
    end

    test "②.1d juge :reviewed (no-carte) → review native (event explicite :approve), unlock la PR, PAS de merge ni request_review" do
      step_run = judge_step_run(:reviewed, %{role: "qualifier", review_event: :approve})

      assert {:ok, :reviewed} = StepRunCompleter.complete_pr(step_run, forge_client: OrchForge)

      assert_received {:get_pr, "lcars/issue-42-engineer", "main"}
      assert_received {:review, 7, :approve, _}
      # juge : verrou sur la PR (dispatch_review)
      assert_received {:unlock, 7, "lcars-in-flight"}

      # le juge ne merge pas et ne re-demande pas de review : c'est le poller (reviews-driven) qui décide.
      # Pas d'action sur requested_reviewers (Gitea ne vide pas ; on lit la liste des reviews).
      refute_received {:merge, _}
      refute_received {:request_review, _, _}
    end

    test "②.1d juge :reviewed REQUEST_CHANGES → review request_changes, unlock la PR, pas de merge" do
      step_run = judge_step_run(:reviewed, %{role: "qualifier", review_event: :request_changes})

      assert {:ok, :reviewed} = StepRunCompleter.complete_pr(step_run, forge_client: OrchForge)

      assert_received {:review, 7, :request_changes, _}
      assert_received {:unlock, 7, _}
      refute_received {:merge, _}
    end

    test "producteur : open_pr echoue → {:open_pr, _}, pas de route" do
      assert {:error, {:open_pr, {:http, 422, _}}} =
               StepRunCompleter.complete_pr(
                 producer_step_run(:promote),
                 deliverable: StubDeliverable,
                 forge_client: PrFailForge
               )

      refute_received {:merge, _}
    end

    test "juge : PR introuvable → {:pr_lookup, :pr_not_found} fail-loud" do
      assert {:error, {:pr_lookup, :pr_not_found}} =
               StepRunCompleter.complete_pr(judge_step_run(:promote), forge_client: NoPrForge)
    end

    test "juge : producer_branch absent → {:pr_lookup, :no_producer_branch}" do
      step_run = judge_step_run(:promote, %{producer_branch: nil})

      assert {:error, {:pr_lookup, :no_producer_branch}} =
               StepRunCompleter.complete_pr(step_run, forge_client: OrchForge)
    end

    test "producteur :promote : merge FF impossible (409) → {:merge, _} fail-loud" do
      assert {:error, {:merge, {:http, 409, _}}} =
               StepRunCompleter.complete_pr(
                 producer_step_run(:promote),
                 deliverable: StubDeliverable,
                 forge_client: MergeFailForge
               )
    end
  end
end
