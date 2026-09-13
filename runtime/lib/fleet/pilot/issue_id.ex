defmodule Fleet.Pilot.IssueId do
  @moduledoc """
  Owns the canonical step issue id format `"issue-<n>"` and its strict inverse.
  """

  @prefix "issue-"

  @doc ~S'''
  Composes a step issue id from a forge issue number.
  '''
  @spec compose(integer()) :: String.t()
  def compose(number), do: @prefix <> to_string(number)

  @doc ~S'''
  Parses canonical integer spelling, including negatives (`issue--5`); explicit +,
  leading zeros and partial suffixes fail. This does not validate forge-number bounds.
  '''
  @spec parse(String.t()) :: {:ok, integer()} | :error
  def parse(@prefix <> rest) do
    case Integer.parse(rest) do
      {n, ""} -> if Integer.to_string(n) == rest, do: {:ok, n}, else: :error
      _ -> :error
    end
  end

  def parse(_), do: :error
end
