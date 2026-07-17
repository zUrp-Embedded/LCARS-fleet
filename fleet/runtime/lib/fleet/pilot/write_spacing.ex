defmodule Fleet.Pilot.WriteSpacing do
  @moduledoc """
  Anti-tie gap BETWEEN two forge writes whose DISPLAY ORDER matters (Gitea dashboard/activity).
  Gitea timestamps events to the SECOND and, within a tied second, the feed displays actions in
  INSERTION order (oldest on top) inside an anti-chronological list — so any same-second pair
  renders inverted ("logically before, displayed after"; observed live on several sequences).

  A SINGLE primitive, shared consumers (all pilot-side, where the forge writes live):
  `StepRunCompleter` (verdict comment → route/stage; target-branch birth → content push) and
  `ProjectOnboard` (create_repo → push main → push work/ops) and `ForgeClient.merge_pr`
  (merge → head-branch delete). Same config, same test seam.

  The gap only orders writes BETWEEN two distinct forge calls. Two events born from ONE call
  (a single `git push` of a new ref → "branch created" + "pushed" the same second) cannot be
  spaced — make the birth a SINGLE forge action instead (API branch create, cf.
  `ForgeClient.create_branch/4`), or accept the tie when the call is unsplittable (orphan
  `work/ops` push, cf. `ProjectOnboard`).
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
