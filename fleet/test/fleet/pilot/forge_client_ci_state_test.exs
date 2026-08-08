defmodule Fleet.Pilot.ForgeClientCiStateTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.ForgeClient

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

  test "no status at all is :none, distinct from :success" do
    assert {:ok, :none} = ci_state([])
  end
end
