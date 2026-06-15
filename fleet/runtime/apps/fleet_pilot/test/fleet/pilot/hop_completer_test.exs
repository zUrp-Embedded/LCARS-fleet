defmodule Fleet.Pilot.HopCompleterTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.HopCompleter

  # Forge stub qui ENREGISTRE l'ordre des appels (send au test) pour vérifier
  # la séquence canonique §5 : comment → state → (close|assignee) → unlock.
  defmodule OrderForge do
    def post_comment(_repo, _n, body, opts) do
      send(self(), {:call, :comment, body, opts[:dedup_signature]})
      {:ok, :posted}
    end

    def set_state_label(_repo, _n, label, _opts) do
      send(self(), {:call, :state, label})
      {:ok, :set}
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

    def post_route(_repo, _n, pipeline, stage, _opts) do
      send(self(), {:call, :route, pipeline, stage})
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

    def merge_pr(_repo, pr, _opts) do
      send(self(), {:merge, pr})
      :ok
    end
  end

  defmodule PrFailForge do
    def open_pr(_r, _h, _b, _t, _o), do: {:error, {:http, 422, "no commits between"}}
    def post_review(_r, _pr, _e, _b, _o), do: {:error, {:http, 500, "boom"}}
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
  end

  # PR introuvable (le juge tombe avant tout review) ; merge FF impossible (open ok, merge 409).
  defmodule NoPrForge do
    def get_pr_for_branch(_r, _h, _b, _o), do: {:error, :pr_not_found}
  end

  defmodule MergeFailForge do
    def open_pr(_r, _h, _b, _t, _o), do: {:ok, 7}
    def merge_pr(_r, _pr, _o), do: {:error, {:http, 409, "not fast-forward"}}
  end

  defp base_hop(extra \\ %{}) do
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

  defp pr_hop(extra \\ %{}) do
    base_hop(
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

  describe "complete/2 — 1-stage terminal (next_assignee nil)" do
    test "publie, comment signé, state, CLOSE, unlock — dans l'ordre §5" do
      assert {:ok, :completed} = HopCompleter.complete(base_hop(), seams())

      # Étape 1 : publish appelé avec les opts du livrable
      assert_received {:published, %{mode: :git_native, base_sha: "cafe"}}

      # Étapes 2→5 dans l'ordre canonique (mailbox FIFO)
      assert_received {:call, :comment, body, sig}
      assert sig == "[hop:engineer:deadbeef]"
      assert body =~ "[hop:engineer:deadbeef]"

      assert_received {:call, :state, "state:delivered"}
      assert_received {:call, :close}
      assert_received {:call, :unlock, "lcars-in-flight"}

      # Pas de réassignation en terminal
      refute_received {:call, :assignee, _}
    end

    test "comment signé porte la signature en dedup_signature (replay-safe)" do
      HopCompleter.complete(base_hop(), seams())
      assert_received {:call, :comment, _body, "[hop:engineer:deadbeef]"}
    end

    test "state_label override respecté" do
      HopCompleter.complete(base_hop(%{state_label: "state:done"}), seams())
      assert_received {:call, :state, "state:done"}
    end
  end

  describe "complete/2 — multi-stage (next_assignee présent, branche A2)" do
    test "publie, comment, state, REASSIGN (pas de close), unlock" do
      hop = base_hop(%{next_assignee: "qualifier"})
      assert {:ok, :reassigned} = HopCompleter.complete(hop, seams())

      assert_received {:call, :comment, _, _}
      assert_received {:call, :state, _}
      assert_received {:call, :assignee, "qualifier"}
      assert_received {:call, :unlock, "lcars-in-flight"}
      refute_received {:call, :close}
    end

    test "reassign avec contexte carte → grave la ROUTE du stage suivant AVANT le reassign (A2.1)" do
      hop =
        base_hop(%{next_assignee: "qualifier", pipeline: "poc-cycle", next_stage: "spec-review"})

      assert {:ok, :reassigned} = HopCompleter.complete(hop, seams())

      # ordre §5 : route gravée AVANT l'assignee (le poller voit le next assignee déjà positionné)
      assert_received {:call, :route, "poc-cycle", "spec-review"}
      assert_received {:call, :assignee, "qualifier"}
    end

    test "reassign sans contexte carte → pas de post_route (defensif)" do
      hop = base_hop(%{next_assignee: "qualifier"})
      assert {:ok, :reassigned} = HopCompleter.complete(hop, seams())
      refute_received {:call, :route, _, _}
    end
  end

  describe "complete/2 — sans livrable git (juge en payload, hop_sha fourni)" do
    test "utilise hop_sha comme signature, pas d'appel publish" do
      hop =
        base_hop(%{deliverable_opts: nil, hop_sha: "verdict-001"})

      assert {:ok, :completed} = HopCompleter.complete(hop, seams())
      refute_received {:published, _}
      assert_received {:call, :comment, _body, "[hop:engineer:verdict-001]"}
    end

    test "erreur si ni livrable ni hop_sha" do
      hop = base_hop(%{deliverable_opts: nil})

      assert {:error, {:publish, :no_deliverable_no_hop_sha}} =
               HopCompleter.complete(hop, seams())
    end
  end

  describe "complete/2 — propagation d'erreur (arrêt avant les étapes suivantes)" do
    test "publish échoue → {:error, {:publish, _}}, aucune écriture forge" do
      opts = Keyword.put(seams(), :deliverable, FailDeliverable)

      assert {:error, {:publish, :base_not_ancestor}} = HopCompleter.complete(base_hop(), opts)

      refute_received {:call, :comment, _, _}
      refute_received {:call, :state, _}
      refute_received {:call, :unlock, _}
    end

    test "comment échoue → {:error, {:comment, _}}, pas de state/close/unlock" do
      defmodule CommentFailForge do
        def post_comment(_r, _n, _b, _o), do: {:error, {:http, 500, "boom"}}
      end

      opts = Keyword.put(seams(), :forge_client, CommentFailForge)

      assert {:error, {:comment, {:http, 500, "boom"}}} = HopCompleter.complete(base_hop(), opts)
    end
  end

  describe "open_deliverable_pr/2 — engineer → PR (Corr.3 PR-natif)" do
    test "push la feature-branch + ouvre la PR feature→base avec Closes #N" do
      opts = [deliverable: StubDeliverable, forge_client: PrForge, forge_opts: []]

      assert {:ok, %{commit_sha: "deadbeef", pr_number: 7}} =
               HopCompleter.open_deliverable_pr(pr_hop(), opts)

      assert_received {:published, %{target_branch: "feature/issue-42"}}
      assert_received {:open_pr, "feature/issue-42", "main", body}
      assert body =~ "Closes #42"
    end

    test "base_branch override" do
      opts = [deliverable: StubDeliverable, forge_client: PrForge, forge_opts: []]
      assert {:ok, _} = HopCompleter.open_deliverable_pr(pr_hop(%{base_branch: "develop"}), opts)
      assert_received {:open_pr, "feature/issue-42", "develop", _}
    end

    test "publish échoue → {:error, {:publish, _}}, PAS de PR ouverte" do
      opts = [deliverable: FailDeliverable, forge_client: PrForge, forge_opts: []]

      assert {:error, {:publish, :base_not_ancestor}} =
               HopCompleter.open_deliverable_pr(pr_hop(), opts)

      refute_received {:open_pr, _, _, _}
    end

    test "open_pr échoue → {:error, {:open_pr, _}}" do
      opts = [deliverable: StubDeliverable, forge_client: PrFailForge, forge_opts: []]

      assert {:error, {:open_pr, {:http, 422, _}}} =
               HopCompleter.open_deliverable_pr(pr_hop(), opts)
    end
  end

  describe "record_review/2 + promote/2 (Corr.3 PR-natif)" do
    test "verdict :approve → review native APPROVED (corps généré du rôle)" do
      hop = %{repo: "fleet/proj", pr_number: 7, role: "qualifier", review_event: :approve}

      assert {:ok, :reviewed} =
               HopCompleter.record_review(hop, forge_client: PrForge, forge_opts: [])

      assert_received {:review, 7, :approve, body}
      assert body =~ "qualifier"
      assert body =~ "PASS"
    end

    test "verdict :request_changes avec corps explicite" do
      hop = %{
        repo: "fleet/proj",
        pr_number: 7,
        role: "reviewer",
        review_event: :request_changes,
        review_body: "il manque un test de la branche d'erreur"
      }

      assert {:ok, :reviewed} =
               HopCompleter.record_review(hop, forge_client: PrForge, forge_opts: [])

      assert_received {:review, 7, :request_changes, "il manque un test de la branche d'erreur"}
    end

    test "record_review propage l'erreur forge" do
      hop = %{repo: "fleet/proj", pr_number: 7, role: "qualifier", review_event: :approve}

      assert {:error, {:review, {:http, 500, _}}} =
               HopCompleter.record_review(hop, forge_client: PrFailForge, forge_opts: [])
    end

    test "promote → merge FF, {:ok, :promoted}" do
      hop = %{repo: "fleet/proj", pr_number: 7}
      assert {:ok, :promoted} = HopCompleter.promote(hop, forge_client: PrForge, forge_opts: [])
      assert_received {:merge, 7}
    end

    test "promote : FF impossible (409) = invariant serial violé → {:merge, _} fail-loud" do
      hop = %{repo: "fleet/proj", pr_number: 7}

      assert {:error, {:merge, {:http, 409, _}}} =
               HopCompleter.promote(hop, forge_client: PrFailForge, forge_opts: [])
    end
  end

  describe "complete_pr/2 — orchestrateur PR-natif (Corr.3)" do
    defp producer_hop(intent, extra \\ %{}) do
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

    defp judge_hop(intent, extra \\ %{}) do
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
      hop = producer_hop(:advance, %{next_assignee: "qualifier"})

      assert {:ok, :review_requested} = HopCompleter.complete_pr(hop, orch_opts())

      assert_received {:open_pr, "lcars/issue-42-engineer", "main", body}
      assert body =~ "Closes #42"
      assert_received {:request_review, 7, ["qualifier"]}
      # producteur : le verrou est sur l'ISSUE (dispatch_issue) ; plus de set_assignee (PR-driven)
      refute_received {:assignee, _, _}
      assert_received {:unlock, 42, "lcars-in-flight"}
    end

    test "producteur :promote (terminal 1-stage) → ouvre la PR, merge FF, unlock, pas de reassign" do
      assert {:ok, :promoted} = HopCompleter.complete_pr(producer_hop(:promote), orch_opts())

      assert_received {:open_pr, "lcars/issue-42-engineer", "main", _}
      assert_received {:merge, 7}
      assert_received {:unlock, 42, _}
      refute_received {:assignee, _, _}
    end

    test "producteur :rework (son propre gate fail) → PAS de PR, unlock l'ISSUE (re-spawn via assignee)" do
      hop = producer_hop(:rework, %{next_assignee: "engineer"})

      assert {:ok, :rework_requested} = HopCompleter.complete_pr(hop, orch_opts())

      refute_received {:open_pr, _, _, _}

      # pas de PR encore -> l'engineer reste assigne (Entry) et re-spawn au prochain tick ; unlock l'issue
      refute_received {:assignee, _, _}
      assert_received {:unlock, 42, _}
    end

    test "juge :advance → retrouve la PR, review APPROVED, request_review(next), unlock la PR" do
      hop = judge_hop(:advance, %{role: "qualifier", next_assignee: "reviewer"})

      assert {:ok, :review_requested} = HopCompleter.complete_pr(hop, forge_client: OrchForge)

      assert_received {:get_pr, "lcars/issue-42-engineer", "main"}
      assert_received {:review, 7, :approve, _}
      assert_received {:request_review, 7, ["reviewer"]}
      refute_received {:assignee, _, _}
      # juge : le verrou est sur la PR (dispatch_review), pas l'issue
      assert_received {:unlock, 7, "lcars-in-flight"}
    end

    test "juge :promote (terminal) → review APPROVED puis merge FF, unlock la PR" do
      hop = judge_hop(:promote, %{role: "reviewer"})

      assert {:ok, :promoted} = HopCompleter.complete_pr(hop, forge_client: OrchForge)

      assert_received {:get_pr, "lcars/issue-42-engineer", "main"}
      assert_received {:review, 7, :approve, _}
      assert_received {:merge, 7}
      assert_received {:unlock, 7, _}
    end

    test "juge :rework (gate fail) → review REQUEST_CHANGES, unlock la PR, PAS de merge" do
      hop = judge_hop(:rework, %{role: "reviewer", next_assignee: "engineer"})

      assert {:ok, :rework_requested} = HopCompleter.complete_pr(hop, forge_client: OrchForge)

      assert_received {:get_pr, "lcars/issue-42-engineer", "main"}
      assert_received {:review, 7, :request_changes, _}
      refute_received {:assignee, _, _}
      assert_received {:unlock, 7, _}
      refute_received {:merge, _}
    end

    test "producteur : open_pr echoue → {:open_pr, _}, pas de route" do
      assert {:error, {:open_pr, {:http, 422, _}}} =
               HopCompleter.complete_pr(
                 producer_hop(:promote),
                 deliverable: StubDeliverable,
                 forge_client: PrFailForge
               )

      refute_received {:merge, _}
    end

    test "juge : PR introuvable → {:pr_lookup, :pr_not_found} fail-loud" do
      assert {:error, {:pr_lookup, :pr_not_found}} =
               HopCompleter.complete_pr(judge_hop(:promote), forge_client: NoPrForge)
    end

    test "juge : producer_branch absent → {:pr_lookup, :no_producer_branch}" do
      hop = judge_hop(:promote, %{producer_branch: nil})

      assert {:error, {:pr_lookup, :no_producer_branch}} =
               HopCompleter.complete_pr(hop, forge_client: OrchForge)
    end

    test "producteur :promote : merge FF impossible (409) → {:merge, _} fail-loud" do
      assert {:error, {:merge, {:http, 409, _}}} =
               HopCompleter.complete_pr(
                 producer_hop(:promote),
                 deliverable: StubDeliverable,
                 forge_client: MergeFailForge
               )
    end
  end
end
