defmodule Fleet.Test.OsProbe do
  # Own boundary (same pattern as `Fleet.TestEnv`): a support module used from several domains'
  # tests is not the property of any one domain. No deps — it only reads `/proc`.
  use Boundary, deps: [], exports: []

  @moduledoc """
  "Is this OS pid still RUNNING?" — for tests that kill a process and must prove it died.

  ## Why `kill -0` is the wrong instrument, and how it cost a red

  Every such test used to ask `kill -0 <pid>`, documented as "exit 0 if the process exists".
  That sentence is true and it is not the question. `kill -0` succeeds on a **ZOMBIE**: a process
  that has terminated and whose exit status nobody has reaped yet. The probe therefore answers
  *"is this pid slot still taken"*, and a test that reads it as *"is it still running"* measures
  reaping, not liveness.

  The two questions have the same answer on a workstation and DIFFERENT answers in a container,
  because the difference lives in pid 1. On a normal system pid 1 reaps orphans continuously, so a
  killed process loses its slot within milliseconds and the two questions coincide. A container's
  pid 1 is whatever the image was told to run — a gitea-actions job container runs
  `/bin/sleep 10800` — and `sleep` reaps nothing. An orphan killed there stays `Z` **forever**.

  Measured on 2026-08-07, both sides, same sequence (`setsid -w bash -c 'sleep & wait'` then
  `kill -KILL -- -<pgid>`):

      host (pid 1 reaps)   /proc/<desc> ABSENT            kill -0 fails    -> "dead"
      container (pid 1 = sleep)  /proc/<desc>/stat = `Z`, ppid 1    kill -0 SUCCEEDS -> "alive"

  The code under test was correct in both: the process group really was killed. Only the
  instrument disagreed, and it disagreed exactly where nobody looks — a green workstation and a red
  clean room.

  ## What this reads instead

  `/proc/<pid>/stat`, third field, the state letter. Absent pid entry = dead; state `Z` = dead
  (terminated, unreaped); anything else = running. Linux only, which is the documented target of
  everything that uses it — the process-group bound in `Fleet.Credentials.Shell` reads `/proc` for
  the same reason.

  The state letter is taken after the LAST `)`, not the first: `comm` may itself contain spaces and
  parentheses, so a process named `evil) name` writes `(evil) name)` and a cut at the first `)`
  reads a letter of the NAME as the state.
  """

  @doc """
  Is `pid` a RUNNING process? A zombie is not: it has terminated.

  `pid` may be an integer or a string (test fixtures often read it back from a file).
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
  Poll until `pid` stops running, `tries` times, 50 ms apart. `true` if it died within the budget.

  SIGKILL is asynchronous: the signal returns before the process is torn down, so a single check
  right after the kill measures the scheduler, not the bound.
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
  The raw state letter from `/proc/<pid>/stat`, `nil` if there is no such pid entry, `"?"` if the
  entry exists but does not parse.

  Exposed so a failing assertion can SAY what it saw: "still R" and "still Z" are two different
  defects, and a message that reports only "alive" sends the reader after the wrong one.

  `"?"` counts as ALIVE, deliberately. "I could not establish that it is dead" must never be
  reported as "it is dead" — that direction turns an unmeasured thing into a green assertion, which
  is the failure this whole module exists to remove.
  """
  @spec state(integer() | binary()) :: binary() | nil
  def state(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} -> parse_state(stat)
      {:error, _} -> nil
    end
  end

  # Split on `)` and keep the LAST piece: `comm` may itself contain `)`, so cutting at the FIRST one
  # lands inside the process name and reads a letter of it as the state. Same parse as the
  # process-group discovery in `Fleet.Credentials.Shell` — one format, one way to read it.
  defp parse_state(stat) do
    case String.split(stat, ")") do
      [_no_paren_at_all] ->
        "?"

      pieces ->
        pieces |> List.last() |> String.trim() |> String.first() || "?"
    end
  end
end
