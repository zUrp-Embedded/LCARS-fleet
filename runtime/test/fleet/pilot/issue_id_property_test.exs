defmodule Fleet.Pilot.IssueIdPropertyTest do
  @moduledoc """
  Samples compose/parse round-trips, including negative integers, canonical spelling
  and rejection of generated non-string terms. Issue identity must survive the
  dispatcher-to-consumer handoff without changing its number.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Fleet.Pilot.IssueId

  # Canonical decimal spelling permits negatives, but no leading zero or explicit +.
  @accepted ~r/\Aissue-(0|-?[1-9][0-9]*)\z/

  # Negative numbers are part of the composer's domain even if invalid on a forge.
  property "P1 ROUND-TRIP — parse(compose(n)) == {:ok, n} for ANY integer (negatives included)" do
    check all(n <- integer()) do
      assert {:ok, ^n} = IssueId.parse(IssueId.compose(n))
    end
  end

  # Accept one spelling per integer so identity remains stable for dedup and lookup.
  # Generated malformed suffixes must not silently correlate to another issue.
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

  # Bus payloads can contain non-string values; sample their rejection.
  property "totality — a non-string term returns :error (never a raise)" do
    check all(
            term <-
              one_of([
                constant(nil),
                integer(),
                boolean(),
                atom(:alphanumeric),
                list_of(integer())
              ])
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
