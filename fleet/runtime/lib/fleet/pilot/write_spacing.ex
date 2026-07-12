defmodule Fleet.Pilot.WriteSpacing do
  @moduledoc """
  Anti-tie gap BETWEEN two forge writes whose DISPLAY ORDER matters (Gitea dashboard/activity).
  Gitea timestamps events to the SECOND: two writes in the same second hold a `created_at`
  tie that the feed renders in an ARBITRARY order ("logically before, displayed after" —
  observed live, several times, on DIFFERENT sequences).

  A SINGLE primitive, two consumers: `StepRunCompleter` (verdict comment → route/stage; merge
  seal → unlock) and `ProjectOnboard` (create_repo → push main → push work/ops — the sequence runs
  locally, near-instantaneous, so collision near-guaranteed without a gap). Same config, same test seam —
  the concept is "human-visible forge write", not "step_run" nor "onboard" specifically.
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
