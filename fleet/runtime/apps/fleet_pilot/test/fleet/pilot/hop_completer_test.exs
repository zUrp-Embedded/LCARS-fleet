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

  # Forge stub PR-natif (Corr.3) : enregistre les appels PR (send au test).
  defmodule PrForge do
    def open_pr(_repo, head, base, _title, opts) do
      send(self(), {:open_pr, head, base, opts[:body]})
      {:ok, 7}
    end

    def post_review(_repo, pr, event, body, _opts) do
      send(self(), {:review, pr, event, body})
      {:ok, :reviewed}
    end

    def merge_pr(_repo, pr, _opts) do
      send(self(), {:merge, pr})
      {:ok, :merged}
    end
  end

  defmodule PrFailForge do
    def open_pr(_r, _h, _b, _t, _o), do: {:error, {:http, 422, "no commits between"}}
    def post_review(_r, _pr, _e, _b, _o), do: {:error, {:http, 500, "boom"}}
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
end
