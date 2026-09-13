defmodule Fleet.Test.OsProbe do
  use Boundary, deps: [], exports: []

  @moduledoc """
  Linux /proc probe for process-termination tests. A zombie has terminated even though
  kill -0 still succeeds; containers without a reaping init can retain these entries.
  States other than Z are treated as alive, including stopped and unparseable entries.
  All read errors are treated as dead, so an inaccessible /proc can give false reassurance.
  """

  @doc """
  Returns false for Z or any stat read error, true otherwise. Accepts integer or string pids.
  """
  @spec alive?(integer() | binary()) :: boolean()
  def alive?(pid) do
    case state(pid) do
      nil -> false
      "Z" -> false
      _ -> true
    end
  end

  @doc """
  Makes up to tries observations, sleeping 50 ms after each live result.
  Returns false when the budget expires, without a final observation after the last sleep.
  SIGKILL is asynchronous, so an immediate check alone can race with termination.
  """
  @spec eventually_dead?(integer() | binary(), pos_integer()) :: boolean()
  def eventually_dead?(pid, tries) when tries > 0 do
    if alive?(pid) do
      Process.sleep(50)
      eventually_dead?(pid, tries - 1)
    else
      true
    end
  end

  def eventually_dead?(_pid, _tries), do: false

  @doc """
  Returns the character after the final closing parenthesis in /proc/<pid>/stat,
  nil on any read error, or "?" if no state can be extracted. Exposes the observation
  for diagnostics; an unknown parsed state counts as alive.
  """
  @spec state(integer() | binary()) :: binary() | nil
  def state(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} -> parse_state(stat)
      {:error, _} -> nil
    end
  end

  # comm can contain spaces and closing parentheses; split after the last ), not the first.
  defp parse_state(stat) do
    case String.split(stat, ")") do
      [_no_paren_at_all] ->
        "?"

      pieces ->
        pieces |> List.last() |> String.trim() |> String.first() || "?"
    end
  end
end
