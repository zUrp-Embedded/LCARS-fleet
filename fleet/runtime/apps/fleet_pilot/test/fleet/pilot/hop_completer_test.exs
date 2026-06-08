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
end
