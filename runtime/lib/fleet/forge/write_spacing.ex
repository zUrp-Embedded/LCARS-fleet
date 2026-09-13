defmodule Fleet.Forge.WriteSpacing do
  @moduledoc """
  Shared delay between caller writes to improve second-resolution forge display ordering.
  It does not serialize concurrent callers or separate events from a single forge call.
  The historical pilot_ config prefix is retained for existing operator configuration.
  """

  @doc """
  Reads :lcars_fleet/:pilot_forge_write_spacing_ms (default 2000, tests 0).
  A positive integer invokes opts[:sleeper] or Process.sleep/1, blocking by default;
  other values do nothing. Returns :ok regardless of the sleeper's return, but exceptions propagate.
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
