defmodule Fleet.Pilot.IssueIdPropertyTest do
  @moduledoc """
  Property-based proof of the `issue_id` `compose/parse` pair. `issue_id_test.exs`
  enumerates 6 hardwired integers; the property covers the whole domain, NEGATIVES INCLUDED.

  The `issue_id` correlates a pod to its forge issue for the whole step_run (enqueue →
  end of step_run). A broken round-trip is a pod we can no longer attach to its issue:
  the result is never stitched back, and the step_run stays in flight.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Fleet.Pilot.IssueId

  # ORACLE — the CANONICAL shape `compose/1` emits (`Integer.to_string(n)`), which `parse/1` now
  # accepts STRICTLY. No leading zeros, no explicit `+`, a single `-` only before a non-zero magnitude.
  @accepted ~r/\Aissue-(0|-?[1-9][0-9]*)\z/

  # ── P1 — ROUND-TRIP ──

  # INVARIANT: ∀ integer n, `parse(compose(n)) == {:ok, n}` — including n < 0 (`"issue--5"`).
  # WHY: `StepDispatcher` writes, `StepRunConsumer` reads back. This is the ONLY thread linking the
  # pod to its issue. Negatives are not theoretical: they are what the format produces if a forge
  # (or a stub) returns an aberrant `issue["number"]` — the parser must return exactly what the
  # composer wrote, or return `:error`, never a DIFFERENT integer.
  property "P1 ROUND-TRIP — parse(compose(n)) == {:ok, n} for ANY integer (negatives included)" do
    check all(n <- integer()) do
      assert {:ok, ^n} = IssueId.parse(IssueId.compose(n))
    end
  end

  # ── P2 — REJECTION (REAL behavior, frozen) ──

  # INVARIANT: `parse/1` accepts a string IFF it matches `#{inspect(@accepted)}` — everything else
  # returns `:error`. The prefix must be exactly `issue-`, the suffix must be a COMPLETE integer
  # (no residual tail: `"issue-7x"`, `"issue-7 "`, `"issue-"` → `:error`).
  # WHY: a malformed `issue_id` that still parsed would correlate the pod to the WRONG issue — a
  # step's result would be posted on someone else's issue. Fail-closed (`:error`) is the only safe
  # exit.
  #
  # `parse/1` is now the STRICT inverse of `compose/1` (tightened): the non-canonical spellings
  # `Integer.parse/1` alone would tolerate are REFUSED — `parse("issue-007") == :error` and
  # `parse("issue-+7") == :error`, so `compose ∘ parse == id` holds both ways. One issue ⇒ exactly one
  # issue_id spelling (safe even if the issue_id ever becomes a KEY: dedup/mutex/lookup).
  property "P2 REJECTION — parse/1 accepts exactly the CANONICAL `issue-<integer>` shape, nothing else" do
    check all(s <- candidate_gen(), max_runs: 300) do
      if Regex.match?(@accepted, s) do
        "issue-" <> rest = s
        assert IssueId.parse(s) == {:ok, String.to_integer(rest)}
      else
        assert IssueId.parse(s) == :error,
               "parse(#{inspect(s)}) should be :error (outside the canonical shape)"
      end
    end
  end

  # INVARIANT: `parse/1` is TOTAL on non-strings → `:error`, never a FunctionClauseError.
  # WHY: the StepRunConsumer's `parse_issue_number` delegates here on a payload field coming from
  # the bus — a `nil`/integer/map arrives there without ceremony.
  property "totality — a non-string term returns :error (never a raise)" do
    check all(
            term <-
              one_of([constant(nil), integer(), boolean(), atom(:alphanumeric), list_of(integer())])
          ) do
      assert IssueId.parse(term) == :error
    end
  end

  # Candidates: canonical shapes, near-canonical ones (the parser's traps), and printable noise.
  defp candidate_gen do
    one_of([
      map(integer(), &IssueId.compose/1),
      map(string(:printable, max_length: 12), &("issue-" <> &1)),
      string(:printable, max_length: 16),
      member_of([
        "issue-007",
        "issue-+7",
        "issue--7",
        "issue-",
        "issue-7x",
        "issue-7 ",
        "issue- 7",
        "issue-0x10",
        "issue-7_0",
        "issue-١٢",
        "ISSUE-7",
        "issue-7\n",
        "\nissue-7",
        "xissue-7",
        "issue-issue-7",
        "owner/repo#7",
        "nope",
        ""
      ])
    ])
  end
end
