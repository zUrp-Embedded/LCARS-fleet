defmodule Fleet.FindingsWire do
  use Boundary, deps: [], exports: []

  @moduledoc """
  The judge's MACHINE verdict on the wire: render it into a review body, read it back out.

  Pure text -> map (+ back). No git, no HTTP, no process -- a `foundation` primitive like
  `Fleet.Conflict`, and for the same reason: the two ends of this wire live in domains that cannot
  see each other. `Fleet.Pilot.StepRunCompleter` WRITES the block when it posts a review;
  `Fleet.Forge.Client.Jury` READS it back when the gate reads that PR's reviews.

  ## Why the review body, and not a fetch

  C1 engraved `findings_v1` as an ops object (`verdicts/issue-N-<role>.json`) -- the durable
  archive. It is the wrong TRANSPORT for a gate: `Fleet.Workflow.OpsObjectSync` is write-only, so
  consuming it at gate time meant building a read path and paying a git read per tick.

  The forge already carries it for free. `Jury.pr_review_state/3` fetches every review of a PR in
  ONE call and keeps each `body` VERBATIM -- so a block appended to that body arrives at the gate
  with zero extra request, scoped to the exact review that carried it (a stale review's findings go
  stale WITH it, which a side-channel could never guarantee), and visible to a human reading the PR.
  One object, one commit-scope, two readers.

  ## The block

      [findings-v1]
      ```json
      {"findings":[...]}
      ```

  Folded in a `<details>` so a human scanning the PR sees a title, not a wall of JSON.

  APPENDED OUTSIDE `Pinning.render`, always. A long verdict is summarized onto the forge surface
  with a pointer to the committed object -- so a machine block rendered INSIDE the prose would be
  the first thing the summary drops, and the wire would work on short verdicts only, which is
  precisely the class where nobody would notice it missing. Same reason, same shape as the conflict
  rail's `[conflict-engine:pr-N:...]` marker.

  ## What this module does NOT do

  It does not validate. `parse/1` decodes and hands over a map; the schema (`findings-v1.json`)
  lives with the consumer, and a body is EDITABLE by a human on the forge -- so the payload is
  re-checked where it is used, never trusted because it was valid when written.
  """

  @marker "[findings-v1]"
  @unreadable_key "findings_unreadable"
  @fence "```json"

  @doc "The stable marker -- exported so a reader/test names it once."
  @spec marker() :: String.t()
  def marker, do: @marker

  @doc """
  Renders the block appended to a review body. `nil` renders nothing (a judge that emitted no
  machine verdict posts exactly the body it posts today, byte-for-byte).
  """
  @spec render(map() | nil) :: String.t()
  def render(nil), do: ""

  def render(findings) when is_map(findings) do
    "\n\n<details>\n<summary>#{@marker} — verdict machine du juge (données, pas prose)</summary>\n\n" <>
      @fence <> "\n" <> Jason.encode!(findings) <> "\n```\n</details>"
  end

  @doc """
  Reads the block back out of a review body.

  `:none` when there is no block -- the ordinary answer for a judge that emitted prose only, and
  NOT an error: the caller decides what an absence means.

  `{:error, :undecodable}` when a block is there but its JSON does not decode. Distinguished from
  `:none` on purpose: "nobody wrote one" and "someone wrote one and it is broken" are different
  facts, and only the second one accuses something.

  The LAST marker wins: the system appends its block after the judge's prose, so a judge that
  quoted the marker in its own text cannot shadow the real one.
  """
  @spec parse(String.t() | nil) :: {:ok, map()} | :none | {:error, :undecodable}
  def parse(body) when is_binary(body) do
    case block(body) do
      {:ok, map} -> {:ok, map}
      :absent -> :none
      :undecodable -> {:error, :undecodable}
    end
  end

  def parse(_), do: :none

  @doc """
  The severities the findings-v1 scale defines, weakest first. The ONLY place this order is
  written: a card's `block_at` is compared against it, and a second copy would be a second scale.
  """
  @spec severities() :: [String.t()]
  def severities, do: ["minor", "important", "critical"]

  @doc """
  The value a reader stores for a judge whose block is PRESENT AND UNREADABLE.

  Not a finding, and deliberately not shaped like one -- fabricating a `critical` to make the gate
  behave would put a defect in the record that nobody measured. It carries one fact: a measurement
  was made and cannot be read. `blocks?/2` treats it as blocking whenever a card declares a floor,
  because the honest answer to "is there a finding above the line?" is then *unknown*, and unknown
  must not be spent as *no*.
  """
  @spec unreadable() :: map()
  def unreadable, do: %{@unreadable_key => true}

  @doc """
  Does this judge's payload carry a finding at or above `block_at`?

  UNKNOWN SEVERITIES DO NOT BLOCK, and that is a decision rather than an oversight: the schema
  constrains the enum at ingestion, so a value outside it means the payload is off-spec — and
  refusing a delivery on the strength of a string nobody can rank would be inventing a verdict out
  of garbage. They are not silently equal to `minor` either; they simply carry no measure. The
  binary verdict of the judge is untouched by any of this: it is the floor, this is a ceiling.

  A payload with no findings, or shaped unexpectedly, answers `false` — an absence of measurement
  is never evidence of a defect.
  """
  @spec blocks?(map() | nil, String.t() | nil) :: boolean()
  def blocks?(nil, _block_at), do: false
  def blocks?(_findings, nil), do: false
  def blocks?(%{@unreadable_key => true}, _block_at), do: true

  def blocks?(%{"findings" => findings}, block_at) when is_list(findings) do
    case rank(block_at) do
      nil ->
        false

      floor ->
        Enum.any?(findings, fn
          %{"severity" => s} -> (rank(s) || -1) >= floor
          _ -> false
        end)
    end
  end

  def blocks?(_findings, _block_at), do: false

  defp rank(severity) when is_binary(severity) do
    Enum.find_index(severities(), &(&1 == severity))
  end

  defp rank(_), do: nil

  # Cut at the last marker, then read the fenced block after it. String primitives rather than a
  # regex: the payload is arbitrary JSON (braces, quotes, newlines), and a regex that has to be
  # right about all three is harder to read than two splits.
  #
  # THREE OUTCOMES, NOT TWO, and collapsing any pair of them costs something real: `:absent` (no
  # block -- a judge that wrote prose only), `{:ok, map}`, and `:undecodable` (a block is there and
  # nothing in it reads). The first version of the hardened parser returned `:absent` when no
  # candidate decoded, which erased the very distinction this module exists to keep -- caught by
  # its own tests, one commit after the distinction had been argued for.
  defp block(body) do
    case String.split(body, @marker) do
      [_only] -> :absent
      parts -> parts |> List.last() |> after_fence()
    end
  end

  # WHICH FENCE CLOSES THE BLOCK CANNOT BE DECIDED BY POSITION -- neither the first nor the last is
  # reliably ours, and each wrong guess fails on a case the other handles:
  #
  #   * the FIRST fence is wrong because a finding QUOTES CODE. "assertion creuse --
  #     `parse_duration \"90s\" >/dev/null`" is the normal shape of a payload, so ```-fenced
  #     snippets live INSIDE the JSON as a matter of course; cutting at the first fence truncated
  #     the substantial findings mid-object and reported them as garbage.
  #   * the LAST fence is wrong because THE BODY IS EDITABLE. It is ours only until a human replies
  #     inside that same body with a code block of their own: ONE appended ```bash snippet turns a
  #     readable payload into `{:error, :undecodable}`, and one layer up that ERASES a card's block
  #     instead of raising it. A parser whose correctness depends on nobody touching the text is not
  #     a parser, it is a convention.
  #
  # So: DECIDE BY DECODING. Take every candidate ending, longest first, and keep the first one that
  # is valid JSON. The longest-first order is what makes it right rather than merely lucky -- inner
  # fences are swallowed by a longer candidate before a shorter one can cut the object short.
  defp after_fence(tail) do
    with [_, rest] <- String.split(tail, @fence, parts: 2),
         parts when length(parts) >= 2 <- String.split(rest, "```") do
      candidates(parts)
    else
      # A marker with no fenced block under it is a judge QUOTING the marker in its prose, not a
      # broken payload -- it accuses nobody.
      _ -> :absent
    end
  end

  # Longest first: n-1 candidates for n segments, each a prefix ending on a different fence. The
  # first that decodes wins; if none does, the block is there and unreadable, and that is said.
  defp candidates(parts) do
    (length(parts) - 1)..1//-1
    |> Enum.map(&(parts |> Enum.take(&1) |> Enum.join("```") |> String.trim()))
    |> Enum.find_value(:undecodable, fn candidate ->
      case Jason.decode(candidate) do
        {:ok, %{} = map} -> {:ok, map}
        _ -> nil
      end
    end)
  end
end
