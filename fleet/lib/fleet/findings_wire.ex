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
    case last_block(body) do
      nil ->
        :none

      json ->
        case Jason.decode(json) do
          {:ok, %{} = map} -> {:ok, map}
          _ -> {:error, :undecodable}
        end
    end
  end

  def parse(_), do: :none

  # Cut at the last marker, then take the first fenced block after it. String primitives rather
  # than a regex: the payload is arbitrary JSON (braces, quotes, newlines), and a regex that has to
  # be right about all three is harder to read than two splits.
  defp last_block(body) do
    case String.split(body, @marker) do
      [_only] ->
        nil

      parts ->
        parts
        |> List.last()
        |> after_fence()
    end
  end

  # THE CLOSING FENCE IS THE LAST ONE, NOT THE FIRST, and the difference is not academic: a
  # finding QUOTES CODE. "assertion creuse -- `parse_duration \"90s\" >/dev/null`" is the normal
  # shape of a judge's payload, so backticks (and ```-fenced snippets) live INSIDE the JSON as a
  # matter of course. Cutting at the first "```" after the opening fence truncated the payload
  # mid-object on exactly those findings -- the substantial ones -- and handed back
  # `{:error, :undecodable}`, which reads as "the judge wrote garbage" about a judge that wrote
  # the most useful thing it could. Our block is appended LAST to the body, so the last fence in
  # the string is ours by construction; everything before it is payload.
  defp after_fence(tail) do
    with [_, rest] <- String.split(tail, @fence, parts: 2),
         parts when length(parts) >= 2 <- String.split(rest, "```") do
      parts |> Enum.drop(-1) |> Enum.join("```") |> String.trim()
    else
      _ -> nil
    end
  end
end
