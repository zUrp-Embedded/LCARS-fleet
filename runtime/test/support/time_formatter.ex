defmodule Fleet.Test.TimeFormatter do
  @moduledoc """
  Writes test_finished events as TSV: module, name, state, async, time_us, file.
  Includes skipped/excluded states reported by ExUnit; rows are not all executed tests.

      TIME_OUT=/tmp/times.tsv mix test --formatter Fleet.Test.TimeFormatter --formatter ExUnit.CLIFormatter

  TIME_OUT is required and the file is truncated on startup. Compare runs by module/name,
  not row order: asynchronous tests finish in varying order. Records expose generated
  test names and per-test timings that source counts and suite totals cannot show.
  """

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
    # Close errors at suite end are ignored.
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
