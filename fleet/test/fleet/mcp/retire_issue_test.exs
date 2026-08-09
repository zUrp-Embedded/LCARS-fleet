defmodule Fleet.MCP.RetireIssueTest do
  @moduledoc """
  Retiring a ticket is a GESTURE, not a side effect of creating another one.

  Everything this tool does already existed inside `create_issue(supersedes:)`. The cost, measured
  on the bench 2026-08-04: to retire a ticket the architect had to create one, which then went out
  to dispatch and landed on a producer with nothing to produce.

  What is genuinely new is the edges. A supersede MOVES them onto the replacement; a retirement has
  no replacement and must LIFT them. Leaving them is the silent failure: a closed blocker counts as
  satisfied on the forge, so every dependent becomes closable as if the work had landed.

  The order assertions are the point of most of these tests. `assert_received` reads the mailbox in
  arrival order, so the sequence of writes IS observable — and the sequence is the contract.
  """
  use ExUnit.Case, async: false

  alias Fleet.MCP.PodTools
  alias Fleet.TestEnv

  # ONE stub, scripted from the test process dictionary, rather than seven modules differing by a
  # single clause. The delegation runs in the calling process, so `Process.put` in a test reaches
  # the stub. Seven near-identical modules would hide which clause each case actually turns on.
  defmodule Forge do
    @behaviour Fleet.MCP.PodTools.Delegation.ForgeClient

    @impl true
    # Pas d'escalade a rendre dans ce stub : `nil` est un resultat, pas une panne.
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
      {:ok, :posted}
    end

    @impl true
    def close_issue(_repo, n, opts) do
      send(self(), {:close_issue, n, Keyword.get(opts, :closure)})
      {:ok, :closed}
    end

    def issue_blocks(_repo, _n, _opts), do: {:ok, Process.get(:blocks, [])}
    def issue_dependencies(_repo, _n, _opts), do: {:ok, []}
    def add_issue_dependency(_repo, _n, _b, _opts), do: {:ok, %{}}

    def remove_issue_dependency(_repo, n, b, _opts) do
      send(self(), {:lift, n, b})
      Process.get(:lift_result, {:ok, %{}})
    end

    # Unused by the retirement path — present because the seam guard demands the whole surface.
    @impl true
    def create_issue(_repo, _t, _b, _opts), do: {:ok, 99}
    @impl true
    def add_label(_repo, _n, _l, _opts), do: {:ok, :added}
    @impl true
    def repo_label_id(_repo, _name, _opts), do: {:ok, 1}
    @impl true
    def list_open_issues(_repo, _opts), do: {:ok, []}
    @impl true
    def merged_pr_of_issue(_repo, _n, _opts), do: :none
    @impl true
    def pr_review_state(_repo, _n, _opts), do: {:ok, %{}}
  end

  setup do
    TestEnv.put_env_restoring(:fleet_mcp, :forge_client, Forge)

    TestEnv.put_env_restoring(:fleet_mcp, :pod_resolver, fn _pod_id ->
      {:ok, %{role: "architect", repo: "fleet/demo"}}
    end)

    :ok
  end

  defp retire(number \\ 42, reason \\ "hors périmètre depuis la refonte"),
    do:
      PodTools.handle_tool_call(
        "retire_issue",
        %{"number" => number, "reason" => reason},
        %{pod_id: "pod-arch-#{System.unique_integer([:positive])}"}
      )

  defp decoded({:ok, %{content: [%{"text" => txt}]}, _state}), do: Jason.decode!(txt)

  describe "the nominal retirement" do
    test "the reason is posted, then the ticket is closed as RETIRED — not delivered" do
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
        %{"state" => "open", "number" => 21, "head" => %{"ref" => "lcars/issue-42-eng_sw"}}
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

      assert {:error, {:retire_aborted, 42, _}, _} = retire()
      refute_received {:close_issue, 42, _}
    end
  end

  describe "the dependents" do
    setup do
      Process.put(:blocks, [%{"number" => 8}, %{"number" => 9}])
      :ok
    end

    test "each is TOLD before its edge is lifted — a silent unblock is the defect" do
      # CE TEST PORTAIT LE NOM DE L'ORDRE ET NE TESTAIT QUE LA PRESENCE. `assert_received` balaie la
      # boite aux lettres pour CHAQUE motif independamment : sur deux motifs disjoints
      # (`{:comment, 8, _}` et `{:lift, 8, 42}`) il reussit quel que soit l'ordre d'arrivee. Mesure
      # du 2026-08-08 : intervertir les deux appels dans `release_dependents/4` laissait la suite
      # entiere verte — 2440 tests — alors que le contrat d'ordre de `retire_issue/3` nomme le
      # defaut correspondant : « l'ordre inverse debloquerait silencieusement un ticket sans rien
      # dire ».
      #
      # La boite aux lettres EST la trace de l'ordre d'appel (meme processus, envois synchrones) :
      # on la vide et on compare des POSITIONS.
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

    test "every edge is lifted BEFORE the close — closing RELEASES, so the order is the contract" do
      # Meme correction que ci-dessus, meme raison : la sequence se lit sur des POSITIONS, pas sur
      # une suite d'`assert_received` que l'ordre d'arrivee n'engage pas.
      retire()
      trace = drain_mailbox()

      close = Enum.find_index(trace, &match?({:close_issue, 42, :retired}, &1))
      assert is_integer(close), "le ticket retire doit etre ferme"

      for dep <- [8, 9] do
        lift = Enum.find_index(trace, &match?({:lift, ^dep, 42}, &1))

        assert is_integer(lift) and lift < close,
               "arete du dependant #{dep} levee APRES la fermeture : fermer RELEASE, donc la " <>
                 "fenetre entre les deux debloque sans rien dire"
      end

      own = Enum.find_index(trace, &match?({:comment, 42, _}, &1))
      assert is_integer(own) and own < close, "le motif se poste avant la fermeture"
    end

    test "an edge that cannot be lifted ABORTS — a dependent left hanging is worse than no retirement" do
      Process.put(:lift_result, {:error, {:http, 500, "boom"}})

      assert {:error, {:retire_aborted, 42, {:dependent_not_released, 8, _}}, _} = retire()
      refute_received {:close_issue, 42, _}
    end

    test "a dependent with no addressable number HALTS — an edge we cannot address we cannot lift" do
      Process.put(:blocks, [%{"id" => 8}])

      assert {:error, {:retire_aborted, 42, {:edge_without_number, _}}, _} = retire()
      refute_received {:close_issue, 42, _}
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
                 "retire_issue",
                 %{"number" => 42, "reason" => ""},
                 %{pod_id: "pod-arch"}
               )
    end

    test "a non-architect pod is refused by the gate, and nothing is read on the forge" do
      TestEnv.put_env_restoring(:fleet_mcp, :pod_resolver, fn _ ->
        {:ok, %{role: "engineer", repo: "fleet/demo"}}
      end)

      assert {:error, :forbidden_not_architect, _} = retire()
      refute_received {:close_issue, _, _}
    end
  end

  # Vide la boite aux lettres du test dans une LISTE ordonnee. Le stub `Forge` s'envoie ses appels a
  # lui-meme, donc l'ordre d'arrivee est l'ordre d'appel — mais `assert_received` ne le lit pas :
  # il cherche un motif n'importe ou dans la file. Comparer des index le lit.
  defp drain_mailbox(acc \\ []) do
    receive do
      msg -> drain_mailbox([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
