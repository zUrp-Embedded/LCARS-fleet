defmodule Fleet.MCP.IssueStatusReviewsTest do
  @moduledoc """
  A rubber stamp and a real review had the same signature — in the ARCHITECT'S TOOLS, never in the
  data.

  On the forge the two were always distinguishable: `/pulls/N/reviews` carries a `body` and a
  `submitted_at` per verdict, and a qualifier citing its gate-brief at 59s does not look like an
  approval landed 1s after the request. `pr_review_state` read all of it and kept `login → verdict`.
  The architect's first blind spot was therefore FALSE at the level of the data and TRUE at the
  level of what it could see — three campaigns spent reconstituting from the outside something that
  was in the payload the whole time.

  The other half of this file is about the DEGRADED path, and it is the part that matters more: a
  seam answering without `records` must not be reported as an unreachable forge. Collapsing the two
  is how a stub, or an implementation left behind, hides behind an outage message.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Fleet.MCP.PodTools
  alias Fleet.TestEnv

  @qualifier %{
    "login" => "qualifier",
    "verdict" => "approved",
    "submitted_at" => "2026-08-04T10:00:01Z",
    "body" => ""
  }

  @reviewer %{
    "login" => "reviewer",
    "verdict" => "approved",
    "submitted_at" => "2026-08-04T10:00:59Z",
    "body" => "Gate vert, 3 cas limites verifies, cf. gate-brief @ abc123."
  }

  defmodule Forge do
    @behaviour Fleet.MCP.PodTools.Delegation.ForgeClient

    @impl true
    # Pas d'escalade a rendre dans ce stub : `nil` est un resultat, pas une panne.
    def escalation_verdict(_repo, _n, _opts), do: {:ok, nil}

    @impl true
    def get_issue(_repo, _n, _opts), do: {:ok, %{"state" => "open", "title" => "Brique"}}

    @impl true
    def list_pulls(_repo, _opts),
      do:
        {:ok,
         [
           %{
             "number" => 6,
             "state" => "open",
             "merged" => false,
             "head" => %{"ref" => "lcars/issue-42-eng_sw", "sha" => "deadbeef"}
           }
         ]}

    @impl true
    def parse_feature_branch(ref), do: Fleet.Forge.Protocol.parse_feature_branch(ref)

    @impl true
    def pr_review_state(_repo, _index, _opts), do: Process.get(:review_state)

    @impl true
    def create_issue(_r, _t, _b, _o), do: raise("read-only")
    @impl true
    def add_label(_r, _n, _l, _o), do: raise("read-only")
    @impl true
    def repo_label_id(_r, _n, _o), do: raise("read-only")
    @impl true
    def post_comment(_r, _n, _b, _o), do: raise("read-only")
    @impl true
    def close_issue(_r, _n, _o), do: raise("read-only")
    @impl true
    def close_pr(_r, _n, _o), do: raise("read-only")
    @impl true
    def list_open_issues(_r, _o), do: {:ok, []}
    @impl true
    def merged_pr_of_issue(_r, _n, _o), do: :none
  end

  setup do
    TestEnv.put_env_restoring(:fleet_mcp, :forge_client, Forge)

    TestEnv.put_env_restoring(:fleet_mcp, :pod_resolver, fn _ ->
      {:ok, %{role: "architect", repo: "fleet/demo"}}
    end)

    :ok
  end

  defp status do
    {:ok, %{content: [%{"text" => txt}]}, _} =
      PodTools.handle_tool_call("get_issue_status", %{"number" => 42}, %{pod_id: "pod-arch"})

    Jason.decode!(txt)
  end

  describe "the substance reaches the architect" do
    setup do
      Process.put(:review_state, {
        :ok,
        %{
          verdicts: %{"qualifier" => :approved, "reviewer" => :approved},
          reviewers: ["qualifier", "reviewer"],
          records: [@qualifier, @reviewer],
          outcome: :approved
        }
      })

      :ok
    end

    test "each verdict arrives with its body and its timestamp" do
      pr = status()["pr"]

      assert [q, r] = pr["reviews"]
      assert q["login"] == "qualifier"
      assert q["submitted_at"] == "2026-08-04T10:00:01Z"
      assert r["body"] =~ "gate-brief"
    end

    test "an EMPTY body is kept — 'approved and wrote nothing' is the fact worth seeing" do
      [q, _] = status()["pr"]["reviews"]

      assert q["verdict"] == "approved"
      assert q["body"] == ""
    end

    test "the two approvals are now distinguishable, which is the entire point" do
      [q, r] = status()["pr"]["reviews"]

      assert q["verdict"] == r["verdict"]
      refute q["body"] == r["body"]
      refute q["submitted_at"] == r["submitted_at"]
    end

    test "the routing verdicts are untouched — this ADDS, it does not replace" do
      pr = status()["pr"]

      assert pr["verdicts"] == %{"qualifier" => "approved", "reviewer" => "approved"}
      assert pr["review"] == "approved"
    end
  end

  describe "the signpost travels in the answer" do
    setup do
      Process.put(
        :review_state,
        {:ok, %{verdicts: %{}, reviewers: [], records: [], outcome: :no_jury}}
      )

      :ok
    end

    test "the status names the tool that holds the thread and the timestamps" do
      result = status()

      assert result["voir_aussi"] =~ "get_issue(42)"
      assert result["voir_aussi"] =~ "horodatages"
    end

    test "it says WHY the two are not redundant — one derives, the other restores" do
      # The bench defect was not a missing field: an architect complained about an absent
      # timestamp without inventorying its own toolbox. A pointer that does not say what the
      # other tool IS gets read as a duplicate and ignored again.
      assert status()["voir_aussi"] =~ "DÉRIVE"
    end
  end

  describe "nothing true to say" do
    test "no in-force review → the key is ABSENT, never an empty list" do
      Process.put(
        :review_state,
        {:ok,
         %{
           verdicts: %{},
           reviewers: ["qualifier"],
           records: [],
           outcome: {:pending, ["qualifier"]}
         }}
      )

      pr = status()["pr"]

      refute Map.has_key?(pr, "reviews")
      assert pr["review"] == "pending"
    end
  end

  describe "the two degraded paths must not be confused" do
    test "a seam WITHOUT :records renders the verdicts and says so — it is not an outage" do
      Process.put(
        :review_state,
        {:ok,
         %{verdicts: %{"qualifier" => :approved}, reviewers: ["qualifier"], outcome: :approved}}
      )

      log = capture_log(fn -> send(self(), {:pr, status()["pr"]}) end)
      assert_received {:pr, pr}

      assert pr["verdicts"] == %{"qualifier" => "approved"}
      assert pr["review"] == "approved"
      refute Map.has_key?(pr, "reviews")
      assert log =~ "returned no :records"
      refute log =~ "forge unreachable"
    end

    test "a MUTE forge is the other message, and it does not claim an empty jury" do
      Process.put(:review_state, {:error, :forge_down})

      log = capture_log(fn -> send(self(), {:pr, status()["pr"]}) end)
      assert_received {:pr, pr}

      assert pr["review"] == "unknown"
      assert log =~ "forge unreachable"
      refute log =~ "returned no :records"
    end
  end
end
