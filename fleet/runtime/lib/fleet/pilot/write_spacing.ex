defmodule Fleet.Pilot.WriteSpacing do
  @moduledoc """
  Anti-tie gap BETWEEN two forge writes whose DISPLAY ORDER matters (Gitea dashboard/activity).
  Gitea timestamps events to the SECOND and, within a tied second, the feed displays actions in
  INSERTION order (oldest on top) inside an anti-chronological list — so any same-second pair
  renders inverted ("logically before, displayed after").

  A SINGLE primitive, shared consumers (all pilot-side, where the forge writes live):
  `StepRunCompleter` (verdict comment → route/stage; target-branch birth → content push) and
  `ProjectOnboard` (create_repo → push main → push work/ops) and `ForgeClient.merge_pr`
  (merge → head-branch delete). Same config, same test seam.

  The gap only orders writes BETWEEN two distinct forge calls. Two actions born from ONE call
  cannot be spaced — and a branch BIRTH always is one (twin "created"+"snapshot" pair, measured
  on both the push and the API channel): the twin tie is accepted everywhere (both lines tell
  the same fact), while the CONTENT push is kept OUT of it via API pre-birth + gap (cf.
  `ForgeClient.create_branch/4`). Same acceptance for the merge transaction's own pair.

  **Last revised**: 2026-07-18
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
