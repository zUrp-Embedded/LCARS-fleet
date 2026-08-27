defmodule Fleet.Forge.ClientCiStateTest do
  use ExUnit.Case, async: true

  alias Fleet.Forge.Client, as: ForgeClient

  # THE CURRENT STATUS PER CONTEXT, AND WHY THE RESPONSE ORDER IS NOT ALLOWED TO DECIDE IT.
  #
  # `commit_ci_state/3` feeds a merge decision. It used to keep the FIRST occurrence of each context
  # under a comment promising "statuses are returned newest-first". Measured on Gitea 1.26.1: the
  # default order is OLDEST-first, and of the five contractual `sort` values only `leastindex`
  # returns newest-first — its name saying the opposite of what it does. Keeping the first therefore
  # kept the OLDEST, and a context posted `success` then `failure` answered `{:ok, :success}`: the
  # merge gate reading green on a red commit, which is the one thing the comment swore could not
  # happen.
  #
  # So the rank is read from the DATA (`id`), and these tests pin that the ORDER OF THE PAYLOAD
  # changes nothing. A forge that reverses its default tomorrow must not move this verdict.

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

  defp st(id, context, status), do: %{"id" => id, "context" => context, "status" => status}

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
      # C'est le defaut exact de la fiche : sur un projet fraichement onboarde, ce vert-la est le
      # seul qui existe, et rien ne le distinguait d'une suite reelle.
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
    # No usable `id` → we do not know which one is current. Returning the best of the set would be
    # the same lie by another route; the merge gate gets the worst.
    unranked = [
      %{"context" => "ci/build", "status" => "success"},
      %{"context" => "ci/build", "status" => "failure"}
    ]

    assert {:ok, :failure} = ci_state(unranked)

    # And the symmetric case: unrankable but uniformly green stays green — fail-closed is not
    # fail-always, or the gate would never open.
    assert {:ok, :success} =
             ci_state([
               %{"context" => "ci/build", "status" => "success"},
               %{"context" => "gate", "status" => "success"}
             ])
  end

  test "a SKIPPED context does not vote — a deliberate skip is not a wait" do
    # `skipped` means the step did not run and was not meant to (its `if:` was false). Counting it
    # as "not yet" made the gate wait 45 minutes and then ESCALATE to a human: a false alarm on a
    # deliberate skip, and false alarms are what teach a human to ignore the channel.
    items = [st(1, "ci/build", "success"), st(2, "ci/lint", "skipped")]
    assert {:ok, :success} = ci_state(items)

    # And it does not hide a red either: not voting is not vetoing.
    assert {:ok, :failure} = ci_state([st(1, "ci/build", "failure"), st(2, "ci/lint", "skipped")])
  end

  test "ALL contexts skipped → :none, the honest answer (nothing ran)" do
    # `:none` is what the gate already treats as a bounded wait then a loud escalation — correct
    # here, because a repo whose every check was skipped has told us nothing.
    assert {:ok, :none} = ci_state([st(1, "ci/build", "skipped"), st(2, "ci/lint", "skipped")])
  end

  test "a WARNING opens the door — the check ran and did not fail" do
    # Blocking forever on a warning is a state no human can leave except by re-running. It is a
    # success that comments.
    assert {:ok, :success} = ci_state([st(1, "ci/build", "warning")])
    assert {:ok, :success} = ci_state([st(1, "ci/build", "success"), st(2, "ci/lint", "warning")])
  end

  test "an UNKNOWN state still closes the door — the catch-all keeps its job" do
    # The reason the catch-all existed stays true for states this code does not know: a forge that
    # grows a new one must not widen the merge door by default.
    assert {:ok, :pending} = ci_state([st(1, "ci/build", "quantum-superposed")])
  end

  test "no status at all is :none, distinct from :success" do
    assert {:ok, :none} = ci_state([])
  end

  # LES ROUGES NOMMES, ET EUX SEULS. Le pod est forge-blind : la cause d'un rework CI ne peut pas
  # etre « va voir », elle doit voyager. Ce qui voyage est le nom du contexte en echec — nommer la
  # liste complete accuserait les verts, qui n'ont rien fait.
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
      # `commit_ci_state` garde tout le groupe pour y lire le PIRE : une porte de merge doit se
      # fermer sur le doute. Ici la lecture DESIGNE un coupable, donc le doute innocente.
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
