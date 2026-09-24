defmodule Fleet.MCP.RetireIssueTest do
  @moduledoc """
  Direct retirement keeps the reason and refuses to invent a replacement ticket.
  Dependency cases check announcements, closure and cleanup using a recorded call
  trace. Selective assert_received patterns elsewhere establish presence, not order.
  Stubs simulate returned failures; no live forge, pod shutdown or ambiguous write is tested.
  """
  use ExUnit.Case, async: false

  alias Fleet.Forge.PayloadFixture
  alias Fleet.MCP.PodTools
  alias Fleet.TestEnv

  # Synchronous calls share the test process dictionary for configured outcomes.
  defmodule Forge do
    @behaviour Fleet.MCP.PodTools.Delegation.ForgeClient

    def escalation_verdict(_repo, _n, _opts), do: {:ok, nil}

    @impl true
    def get_issue(_repo, _n, _opts), do: {:ok, %{"state" => Process.get(:issue_state, "open")}}

    @impl true
    def list_pulls(_repo, _opts), do: {:ok, Process.get(:pulls, [])}

    @impl true
    def parse_feature_branch(ref), do: Fleet.Forge.Protocol.parse_feature_branch(ref)

    @impl true
    def close_pr(_repo, pr, _opts) do
      send(self(), {:close_pr, pr})
      Process.get(:close_pr_result, {:ok, :closed})
    end

    @impl true
    def post_comment(_repo, n, body, _opts) do
      send(self(), {:comment, n, body})
      # Configure announcement failure before closure.
      Process.get(:comment_result, {:ok, :posted})
    end

    @impl true
    def close_issue(_repo, n, opts) do
      send(self(), {:close_issue, n, Keyword.get(opts, :closure)})
      {:ok, :closed}
    end

    def issue_blocks(_repo, _n, _opts), do: {:ok, Process.get(:blocks, [])}
    def issue_dependencies(_repo, _n, _opts), do: {:ok, Process.get(:deps, [])}
    def add_issue_dependency(_repo, _n, _b, _opts), do: {:ok, %{}}

    def remove_issue_dependency(_repo, n, b, _opts) do
      send(self(), {:lift, n, b})
      Process.get(:lift_result, {:ok, %{}})
    end

    # Unused by the retirement path — present because the seam guard demands the whole surface.
    @impl true
    def create_issue(_repo, _t, _b, _opts), do: {:ok, 99}
    @impl true
    def add_label(_repo, n, label, _opts) do
      send(self(), {:stamp, n, label})
      {:ok, :added}
    end

    @impl true
    def repo_label_id(_repo, _name, _opts), do: {:ok, 1}
    @impl true
    def list_open_issues(_repo, _opts), do: {:ok, []}
    @impl true
    def merged_pr_of_issue(_repo, _n, _opts), do: :none
    @impl true
    def get_route(_r, _n, _o), do: :none

    @impl true
    def pr_review_state(_repo, _n, _opts), do: {:ok, %{}}
  end

  setup do
    TestEnv.put_env_restoring(:lcars_fleet, :mcp_forge_client, Forge)

    TestEnv.put_env_restoring(:lcars_fleet, :mcp_pod_resolver, fn _pod_id ->
      {:ok, %{role: "architect", repo: "fleet/demo"}}
    end)

    :ok
  end

  defp retire(number \\ 42, reason \\ "hors périmètre depuis la refonte"),
    do:
      PodTools.handle_tool_call(
        "issue_retire",
        %{"number" => number, "reason" => reason},
        %{pod_id: "pod-arch-#{System.unique_integer([:positive])}"}
      )

  defp decoded({:ok, %{content: [%{"text" => txt}]}, _state}), do: Jason.decode!(txt)

  describe "the nominal retirement" do
    test "the ticket is closed as RETIRED, then the reason is posted — not delivered" do
      result = retire() |> decoded()

      assert_received {:comment, 42, body}
      assert body =~ "hors périmètre"
      assert body =~ "rien n'a été livré"
      assert_received {:close_issue, 42, :retired}

      assert result["retired"] == true
      assert result["released"] == []
    end

    test "no live PR → nothing is closed on the pulls side" do
      retire()
      refute_received {:close_pr, _}
    end
  end

  describe "a live pull request" do
    setup do
      Process.put(:pulls, [
        PayloadFixture.pull(number: 21, state: "open", head_ref: "lcars/issue-42-eng_sw")
      ])

      :ok
    end

    test "dies FIRST — the pulls rail never reads the issue state" do
      result = retire() |> decoded()

      assert_received {:close_pr, 21}
      assert_received {:comment, 42, _}
      assert_received {:close_issue, 42, :retired}
      assert result["pr_closed"] == 21
    end

    test "unclosable PR ABORTS: the ticket stays open rather than half-retired" do
      Process.put(:close_pr_result, {:error, {:http, 500, "boom"}})

      assert {:error, {:retire_incomplete, 42, :pull_request, _}, _} = retire()
      refute_received {:close_issue, 42, _}
      # Stamped before anything else: the unclosed ticket can never be dispatched again.
      assert_received {:stamp, 42, "stage/retired"}
    end
  end

  describe "the dependents" do
    setup do
      Process.put(:blocks, [%{"number" => 8}, %{"number" => 9}])
      :ok
    end

    test "each is TOLD before its edge is lifted — a silent unblock is the defect" do
      # Drain the mailbox and compare positions: selective receives alone accept either call order.
      result = retire() |> decoded()
      trace = drain_mailbox()

      assert {:comment, 8, told} = Enum.find(trace, &match?({:comment, 8, _}, &1))
      assert told =~ "bloqueur #42"
      assert told =~ "redemandé"

      for dep <- [8, 9] do
        c = Enum.find_index(trace, &match?({:comment, ^dep, _}, &1))
        l = Enum.find_index(trace, &match?({:lift, ^dep, 42}, &1))

        assert is_integer(c) and is_integer(l),
               "le dependant #{dep} doit recevoir un commentaire ET une levee"

        assert c < l,
               "dependant #{dep} : arete levee AVANT le commentaire — un ticket debloque en " <>
                 "silence est exactement le defaut que cet ordre existe pour empecher"
      end

      assert result["released"] == [8, 9]
    end

    # Closing releases admission blockers; announcements must precede it and removals
    # follow it, so a failed pre-close step cannot leave edges removed under an open blocker.
    test "personne n'est LIBERE avant d'avoir ete prevenu, et rien n'est libere avant le close" do
      retire()
      trace = drain_mailbox()

      close = Enum.find_index(trace, &match?({:close_issue, 42, :retired}, &1))
      assert is_integer(close), "le ticket retire doit etre ferme"

      for dep <- [8, 9] do
        told = Enum.find_index(trace, &match?({:comment, ^dep, _}, &1))
        lift = Enum.find_index(trace, &match?({:lift, ^dep, 42}, &1))

        assert is_integer(told) and told < close,
               "dependant #{dep} : le close LIBERE, et il n'avait pas ete prevenu — c'est le " <>
                 "deblocage silencieux que cet ordre existe pour empecher"

        assert is_integer(lift) and lift > close,
               "dependant #{dep} : arete levee AVANT le close, donc AVANT le point de non-retour — " <>
                 "un abandon a cet instant laisse un dependant libere sous un bloqueur vivant"
      end

      own = Enum.find_index(trace, &match?({:comment, 42, _}, &1))

      assert is_integer(own) and own > close,
             "le motif se poste APRES la fermeture : un commentaire ne dit que ce qui a eu lieu"

      stamp = Enum.find_index(trace, &match?({:stamp, 42, "stage/retired"}, &1))
      assert stamp == 0, "le tampon est le PREMIER geste : #{inspect(trace)}"
    end

    test "l'ANNONCE qui echoue ABANDONNE : rien n'est ferme, rien n'est leve, rien n'est libere" do
      # This fixture fails the first announcement; no closure or edge removal should follow.
      Process.put(:comment_result, {:error, {:http, 500, "boom"}})

      assert {:error, {:retire_incomplete, 42, :announce, {8, _}}, _} = retire()
      refute_received {:close_issue, 42, _}
      refute_received {:lift, _, _}
    end

    test "une levee qui echoue APRES le close est SIGNALEE, pas transformee en abandon" do
      # The closed ticket is retired despite removal failures, which must remain visible in the result.
      Process.put(:lift_result, {:error, {:http, 500, "boom"}})

      result = retire() |> decoded()

      assert_received {:close_issue, 42, :retired}
      assert result["retired"] == true
      assert result["released"] == []
      assert result["edges_not_lifted"] == [8, 9]
    end

    test "TEMOIN — une levee qui REUSSIT ne porte aucune trace d'incomplet" do
      # Sans ce temoin, poser `edges_not_lifted` en permanence passerait le test ci-dessus.
      result = retire() |> decoded()
      refute Map.has_key?(result, "edges_not_lifted")
      assert result["released"] == [8, 9]
    end

    test "a dependent with no addressable number HALTS — an edge we cannot address we cannot lift" do
      Process.put(:blocks, [%{"id" => 8}])

      assert {:error, {:retire_incomplete, 42, :graph, {:edge_without_number, _}}, _} = retire()
      refute_received {:close_issue, 42, _}
    end
  end

  describe "its own blockers" do
    test "a blocker that cannot be lifted STOPS before the close, and the ticket says so" do
      # Gitea refuses to close an issue with open dependencies: an unlifted blocker means no close.
      Process.put(:deps, [%{"number" => 13}])
      Process.put(:lift_result, {:error, {:http, 500, "boom"}})

      assert {:error, {:retire_incomplete, 42, :lift, {:blockers_not_lifted, [13]}}, _} = retire()
      assert_received {:stamp, 42, "stage/retired"}
      refute_received {:close_issue, 42, _}
      assert_received {:comment, 42, body}
      assert body =~ "INTERROMPU"
      assert body =~ "ne sera plus jamais dispatché"
    end

    test "INVERSE TWIN — a liftable blocker is lifted, then the ticket closes" do
      Process.put(:deps, [%{"number" => 13}])

      assert %{"retired" => true} = retire() |> decoded()
      assert_received {:lift, 42, 13}
      assert_received {:close_issue, 42, :retired}
    end
  end

  describe "idempotency and refusals" do
    test "an already-closed ticket is a no-op success — the bridge times out and the agent re-emits" do
      Process.put(:issue_state, "closed")
      result = retire() |> decoded()

      assert result["retired"] == false
      refute_received {:close_issue, _, _}
      refute_received {:comment, _, _}
    end

    test "an empty reason is refused: the motive IS the only trace of the decision" do
      assert {:error, :invalid_arguments, _} =
               PodTools.handle_tool_call(
                 "issue_retire",
                 %{"number" => 42, "reason" => ""},
                 %{pod_id: "pod-arch"}
               )
    end

    test "a non-architect pod is refused by the gate, and nothing is read on the forge" do
      TestEnv.put_env_restoring(:lcars_fleet, :mcp_pod_resolver, fn _ ->
        {:ok, %{role: "engineer", repo: "fleet/demo"}}
      end)

      assert {:error, :forbidden_not_architect, _} = retire()
      refute_received {:close_issue, _, _}
    end
  end

  # Same-process sends form the call trace; draining preserves order unlike selective receives.
  defp drain_mailbox(acc \\ []) do
    receive do
      msg -> drain_mailbox([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
