defmodule Fleet.Forge.WriteSpacing do
  @moduledoc """
  Shared gap between distinct forge writes whose second-resolution display order
  matters. Events produced by one forge call remain inseparable by construction.

  It lives in the FORGE domain and not the pilot's, because that is what it is about: the pilot
  calls it exactly where it writes to the forge. The config key keeps its `pilot_` prefix
  (`:lcars_fleet, :pilot_forge_write_spacing_ms`) — renaming a key at the edge of a move is how an
  operator's env file silently stops being read.
  """

  @doc """
  Inserts the configured gap (`:lcars_fleet, :pilot_forge_write_spacing_ms`, default 2000ms; 0 in test → no-op,
  cf. `config/test.exs`). `:sleeper` seam in `opts` (test — captures the requested duration, does not actually
  sleep). NB: briefly blocks the caller (assumed: already on the synchronous HTTP writes
  path — 2s buys an honest chronology, user decision).
  """
  @spec gap(keyword()) :: :ok
  def gap(opts \\ []) do
    case Application.get_env(:lcars_fleet, :pilot_forge_write_spacing_ms, 2000) do
      ms when is_integer(ms) and ms > 0 -> (opts[:sleeper] || (&Process.sleep/1)).(ms)
      _ -> :ok
    end

    :ok
  end
end
