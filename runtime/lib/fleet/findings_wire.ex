defmodule Fleet.FindingsWire do
  use Boundary, deps: [], exports: []

  @moduledoc """
  Renders and reads machine findings in forge review bodies, shared by Pilot's completer and
  Forge.Client.Jury across their dependency boundary. The review carries findings with its own
  commit scope and existing fetch; the ops JSON object remains the archive, without a per-tick
  Git read through the write-only OpsObjectSync.

      [findings]
      ```json
      {"findings":[...]}
      ```

  Rendered inside details for readability. Append the block after Pinning.render so summarizing
  a long prose verdict cannot drop its machine payload. Parsing only requires a JSON object;
  consumers must revalidate findings.json because humans can edit the review body after posting.
  """

  @marker "[findings]"
  @unreadable_key "findings_unreadable"
  @fence "```json"

  @doc "The stable marker -- exported so a reader/test names it once."
  @spec marker() :: String.t()
  def marker, do: @marker

  @doc """
  Renders a findings block for appending to a review. Nil renders an empty string, preserving
  prose-only review bodies byte-for-byte.
  """
  @spec render(map() | nil) :: String.t()
  def render(nil), do: ""

  def render(findings) when is_map(findings) do
    "\n\n<details>\n<summary>#{@marker} — verdict machine du juge (données, pas prose)</summary>\n\n" <>
      @fence <> "\n" <> Jason.encode!(findings) <> "\n```\n</details>"
  end

  @doc """
  Reads the block after the last marker, since system findings are appended after judge prose.
  No marker or no closed JSON fence returns :none. A fenced payload that cannot decode to a map
  returns {:error, :undecodable}; callers must distinguish damaged findings from absent findings.
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
  Shared severity order, weakest first, for comparison with a card's block_at threshold.
  """
  @spec severities() :: [String.t()]
  def severities, do: ["minor", "important", "critical"]

  @doc """
  Sentinel for present but unreadable findings, without inventing a critical finding.
  It blocks whenever block_at is non-nil: unreadability cannot establish that the threshold is clear.
  """
  @spec unreadable() :: map()
  def unreadable, do: %{@unreadable_key => true}

  @doc """
  Whether a finding meets/exceeds block_at. Unknown severities are unranked and do not block;
  neither do absent or malformed findings, or a missing/unknown threshold. The unreadable sentinel
  is the exception: it blocks for any non-nil threshold. Consumers own schema validation.
  This check supplements the judge's binary verdict without changing it.
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

  defp block(body) do
    case String.split(body, @marker) do
      [_only] -> :absent
      parts -> parts |> List.last() |> after_fence()
    end
  end

  # A finding can quote fences inside JSON, and humans can append fenced code after the block.
  # Neither the first nor last closing fence is reliable; try candidate endings by JSON decoding.
  defp after_fence(tail) do
    with [_, rest] <- String.split(tail, @fence, parts: 2),
         parts when length(parts) >= 2 <- String.split(rest, "```") do
      candidates(parts)
    else
      # A bare marker or unclosed fence counts as absent; no payload is available to decode.
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
