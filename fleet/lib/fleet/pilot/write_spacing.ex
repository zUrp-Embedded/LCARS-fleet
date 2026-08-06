defmodule Fleet.Pilot.WriteSpacing do
  @moduledoc """
  Shared gap between distinct forge writes whose second-resolution display order
  matters. Events produced by one forge call remain inseparable by construction.
  """

  @doc """
  Inserts the configured gap (`:fleet_pilot, :forge_write_spacing_ms`, default 2000ms; 0 in test → no-op,
  cf. `config/test.exs`). `:sleeper` seam in `opts` (test — captures the requested duration, does not actually
  sleep). NB: briefly blocks the caller (assumed: already on the synchronous HTTP writes
  path — 2s buys an honest chronology, user decision).
  """
  @spec gap(keyword()) :: :ok
  def gap(opts \\ []) do
    case Application.get_env(:fleet_pilot, :forge_write_spacing_ms, 2000) do
      ms when is_integer(ms) and ms > 0 -> (opts[:sleeper] || (&Process.sleep/1)).(ms)
      _ -> :ok
    end

    :ok
  end
end
