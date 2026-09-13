defmodule Fleet.Forge.ClientCiStateTest do
  use ExUnit.Case, async: true

  alias Fleet.Forge.Client, as: ForgeClient

  # Gitea 1.26.1's captured default order was oldest-first (leastindex reversed it).
  # Distinct integer ids must choose the newest per context regardless of payload order.

  defmodule Statuses do
    @moduledoc false
    @behaviour Plug

    @impl Plug
    def init(items), do: items

    @impl Plug
    def call(conn, items) do
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.send_resp(200, JSON.encode!(items))
    end
  end

  # Override decisive fields on a captured CommitStatus, preserving its other fields.
  @statuses_file Path.join([__DIR__, "..", "..", "fixtures", "forge", "statuses.json"])
  @external_resource @statuses_file
  @capture @statuses_file |> File.read!() |> Jason.decode!()

  defp st(id, context, status),
    do: Map.merge(hd(@capture), %{"id" => id, "context" => context, "status" => status})

  defp ci_state(items) do
    opts = [
      base_url: "http://fake.test",
      token: "t",
      req_options: [plug: {Statuses, items}]
    ]

    ForgeClient.commit_ci_state("fleet/p", "deadbeef", opts)
  end

  defp ci_failures(items) do
    opts = [
      base_url: "http://fake.test",
      token: "t",
      req_options: [plug: {Statuses, items}]
    ]

    ForgeClient.commit_ci_failures("fleet/p", "deadbeef", opts)
  end

  defp ci_report(items) do
    opts = [
      base_url: "http://fake.test",
      token: "t",
      req_options: [plug: {Statuses, items}]
    ]

    ForgeClient.commit_ci_report("fleet/p", "deadbeef", opts)
  end

  describe "6-140 — le verdict ne dit pas QUI l'a produit, et c'est ce qui manquait au juge" do
    test "les contextes voyagent avec le verdict, dedupliques et tries" do
      items = [
        st(2, "CI / test (pull_request)", "success"),
        st(1, "CI / test (push)", "success"),
        st(3, "CI / test (pull_request)", "success")
      ]

      assert {:ok, {:success, ["CI / test (pull_request)", "CI / test (push)"]}} =
               ci_report(items)
    end

    test "le rail placeholder du template est VERT, et desormais NOMME" do
      # Le nom permet de distinguer un placeholder vert d'une suite de tests.
      assert {:ok, {:success, ["CI / no-harness-yet (pull_request)"]}} =
               ci_report([st(1, "CI / no-harness-yet (pull_request)", "success")])
    end

    test "aucun statut : verdict `:none` et AUCUN contexte fabrique" do
      assert {:ok, {:none, []}} = ci_report([])
    end

    test "`commit_ci_state/3` garde son contrat exactement — l'ajout n'est pas un changement" do
      items = [st(1, "ci/build", "success"), st(2, "ci/build", "failure")]
      assert {:ok, :failure} = ci_state(items)
      assert {:ok, {:failure, ["ci/build"]}} = ci_report(items)
    end
  end

  test "a context that went green THEN red is red — the case that made the gate lie" do
    assert {:ok, :failure} =
             ci_state([st(1, "ci/build", "success"), st(2, "ci/build", "failure")])
  end

  test "a context that went red THEN green is green — a recovery must be seen too" do
    assert {:ok, :success} =
             ci_state([st(1, "ci/build", "failure"), st(2, "ci/build", "success")])
  end

  # Verifie le fichier capture, pas une forge en direct. Le test suivant exerce notre verdict
  # sur ce fichier et son inverse ; ni l'un ni l'autre ne mesure l'ordre actuel du serveur.
  test "la capture reelle est OLDEST-first, et porte `status` — jamais `state`" do
    ids = Enum.map(@capture, & &1["id"])

    assert length(ids) > 1, "une capture d'un seul element ne dit rien d'un ORDRE"
    assert ids == Enum.sort(ids), "la capture n'est plus oldest-first : le fait externe a bouge"

    Enum.each(@capture, fn statut ->
      assert is_integer(statut["id"])
      assert is_binary(statut["context"])

      # CommitStatus porte status ; CombinedStatus porte state.
      assert is_binary(statut["status"])
      refute Map.has_key?(statut, "state")
    end)
  end

  test "sur la capture reelle, le verdict est celui du statut le PLUS RECENT du contexte" do
    # La capture passe de failure (id 1) a success (id 2).
    assert {:ok, :success} = ci_state(@capture)
    assert {:ok, :success} = ci_state(Enum.reverse(@capture))
  end

  test "the ORDER of the payload does not move the verdict" do
    oldest_first = [st(1, "ci/build", "success"), st(2, "ci/build", "failure")]
    newest_first = Enum.reverse(oldest_first)
    shuffled = [st(2, "ci/build", "failure"), st(1, "ci/build", "success")]

    assert {:ok, :failure} = ci_state(oldest_first)
    assert {:ok, :failure} = ci_state(newest_first)
    assert {:ok, :failure} = ci_state(shuffled)
  end

  test "several contexts: each one's CURRENT status counts, and one red sinks the merge" do
    items = [
      st(1, "ci/build", "failure"),
      st(2, "ci/build", "success"),
      st(3, "gate", "success"),
      st(4, "gate", "failure")
    ]

    # `ci/build` recovered (current success), `gate` broke (current failure) → failure.
    assert {:ok, :failure} = ci_state(items)
  end

  test "several contexts, all green at their latest → green" do
    items = [
      st(1, "ci/build", "failure"),
      st(2, "ci/build", "success"),
      st(3, "gate", "pending"),
      st(4, "gate", "success")
    ]

    assert {:ok, :success} = ci_state(items)
  end

  test "a group we cannot ORDER falls back to its WORST, never its best" do
    # Unranked groups contribute their worst state to the merge gate.
    unranked = [
      %{"context" => "ci/build", "status" => "success"},
      %{"context" => "ci/build", "status" => "failure"}
    ]

    assert {:ok, :failure} = ci_state(unranked)

    # These two singleton contexts are both green despite missing ids.
    assert {:ok, :success} =
             ci_state([
               %{"context" => "ci/build", "status" => "success"},
               %{"context" => "gate", "status" => "success"}
             ])
  end

  test "a SKIPPED context does not vote — a deliberate skip is not a wait" do
    # Skipped does not vote, avoiding the former timeout/escalation on skipped checks.
    # The status alone does not tell this test why execution was skipped.
    items = [st(1, "ci/build", "success"), st(2, "ci/lint", "skipped")]
    assert {:ok, :success} = ci_state(items)

    # And it does not hide a red either: not voting is not vetoing.
    assert {:ok, :failure} = ci_state([st(1, "ci/build", "failure"), st(2, "ci/lint", "skipped")])
  end

  test "ALL contexts skipped → :none, the honest answer (nothing ran)" do
    # No voting status remains; this test does not exercise downstream waiting/escalation.
    assert {:ok, :none} = ci_state([st(1, "ci/build", "skipped"), st(2, "ci/lint", "skipped")])
  end

  test "a WARNING opens the door — the check ran and did not fail" do
    # Policy maps warning to success; these synthetic statuses do not prove a check executed.
    assert {:ok, :success} = ci_state([st(1, "ci/build", "warning")])
    assert {:ok, :success} = ci_state([st(1, "ci/build", "success"), st(2, "ci/lint", "warning")])
  end

  test "an UNKNOWN state still closes the door — the catch-all keeps its job" do
    # A new status must not open the merge gate by default.
    assert {:ok, :pending} = ci_state([st(1, "ci/build", "quantum-superposed")])
  end

  test "no status at all is :none, distinct from :success" do
    assert {:ok, :none} = ci_state([])
  end

  # Le pod sans acces forge recoit les contextes rouges pour cibler le rework.
  describe "commit_ci_failures — la cause voyage, l'accusation reste juste" do
    test "un contexte VERT n'est jamais nomme" do
      items = [
        st(1, "CI / lint (pull_request)", "success"),
        st(2, "CI / test (pull_request)", "failure")
      ]

      assert {:ok, [%{context: "CI / test (pull_request)"}]} = ci_failures(items)
    end

    test "`error` compte comme un echec, `skipped` et `warning` non" do
      items = [
        st(1, "CI / a", "error"),
        st(2, "CI / b", "skipped"),
        st(3, "CI / c", "warning")
      ]

      assert {:ok, [%{context: "CI / a"}]} = ci_failures(items)
    end

    test "le DERNIER statut du contexte decide, pas l'ordre de la reponse" do
      # Rouge puis vert : le contexte est repare, il ne doit accuser personne.
      assert {:ok, []} = ci_failures([st(2, "CI / t", "success"), st(1, "CI / t", "failure")])
      # Vert puis rouge : il est rouge, quel que soit l'ordre du payload.
      assert {:ok, [%{context: "CI / t"}]} =
               ci_failures([st(2, "CI / t", "failure"), st(1, "CI / t", "success")])
    end

    test "ORDRE INDETERMINABLE : on n'accuse PERSONNE — l'inverse de la porte de merge" do
      # Le verdict garde le pire ; le rapport n'attribue pas un echec sans statut courant connu.
      items = [
        %{"id" => nil, "context" => "CI / t", "status" => "failure"},
        %{"id" => nil, "context" => "CI / t", "status" => "success"}
      ]

      assert {:ok, :failure} = ci_state(items)
      assert {:ok, []} = ci_failures(items)
    end

    test "description et target_url voyagent quand ils existent, `nil` quand ils sont vides" do
      full =
        Map.merge(st(1, "CI / t", "failure"), %{
          "description" => "checkout failed",
          "target_url" => "http://forge/run/7"
        })

      assert {:ok, [%{description: "checkout failed", target_url: "http://forge/run/7"}]} =
               ci_failures([full])

      blank = Map.merge(st(1, "CI / t", "failure"), %{"description" => "  ", "target_url" => ""})
      assert {:ok, [%{description: nil, target_url: nil}]} = ci_failures([blank])
    end
  end
end
