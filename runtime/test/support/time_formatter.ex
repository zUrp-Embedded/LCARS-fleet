defmodule Fleet.Test.TimeFormatter do
  @moduledoc """
  The executed-witness manifest, with the time and the `async` flag of each test.

  One line per witness, tab-separated: `module`, `name`, `state`, `async`, `time_us`, `file`.
  It is the only honest way to COUNT this suite (13 loop sites generate 62 names a static count
  does not see) and the only way to say WHERE the wall-clock goes: the CLI summary gives one sync
  total, this gives it per module and per witness.

      TIME_OUT=/tmp/times.tsv mix test --formatter Fleet.Test.TimeFormatter --formatter ExUnit.CLIFormatter

  Two manifests from two runs (two seeds, two Elixir versions, before and after a change) diff
  line by line on the first two columns. Measured 2026-09-06: the 1.18 and 1.20 manifests were
  byte-identical (3 587 names) while the two summary lines disagreed by 11 — 1.20 subtracts the
  skipped from each counter, 1.18 keeps them in. The manifest settled it; the summary could not.

  `TIME_OUT` unset = the formatter refuses to start (fail-loud, never a silent no-op).
  """
  # A support module is its own boundary, like Barrier and OsProbe: it depends on nothing of the
  # fleet and exports nothing — the compiler refuses a module that belongs nowhere.
  use Boundary, deps: [], exports: []
  use GenServer

  @impl GenServer
  def init(_opts) do
    case System.get_env("TIME_OUT") do
      nil -> {:stop, "Fleet.Test.TimeFormatter: TIME_OUT must name the output file"}
      path -> {:ok, File.open!(path, [:write, :utf8])}
    end
  end

  @impl GenServer
  def handle_cast({:test_finished, %ExUnit.Test{} = t}, io) do
    IO.puts(
      io,
      "#{inspect(t.module)}\t#{t.name}\t#{state(t.state)}\t#{t.tags[:async]}\t#{t.time}\t#{t.tags[:file]}"
    )

    {:noreply, io}
  end

  def handle_cast({:suite_finished, _}, io) do
    # `_ =`: dialyzer's :unmatched_returns is part of the gate, and a close error at suite end has
    # nowhere useful to go (the file is already written line by line).
    _ = File.close(io)
    {:noreply, io}
  end

  def handle_cast(_, io), do: {:noreply, io}

  defp state(nil), do: "passed"
  defp state({:failed, _}), do: "failed"
  defp state({:skipped, _}), do: "skipped"
  defp state({:excluded, _}), do: "excluded"
  defp state({:invalid, _}), do: "invalid"
  defp state(other), do: inspect(other)
end
