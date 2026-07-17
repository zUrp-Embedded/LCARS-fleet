defmodule Fleet.Workflow.WriteSpacing do
  @moduledoc """
  Anti-tie gap BETWEEN two forge writes whose DISPLAY ORDER matters (Gitea dashboard/activity).
  Gitea timestamps events to the SECOND: two writes in the same second hold a `created_at`
  tie that the feed renders in an ARBITRARY order ("logically before, displayed after" —
  observed live, several times, on DIFFERENT sequences).

  A SINGLE primitive, shared consumers: `StepRunCompleter` (verdict comment → route/stage),
  `ProjectOnboard` (create_repo → push main → push work/ops), `Deliverable` (pre-created
  target branch → content push) and `ForgeClient.merge_pr` (merge → head-branch delete).
  Same config, same test seam — the concept is "human-visible forge write", cross-domain
  (lives in workflow, the LOWEST domain that writes to the forge; pilot depends on workflow).

  The gap only orders writes BETWEEN two distinct forge calls. Two events born from ONE
  call (e.g. a single `git push` of a new ref → "branch created" + "pushed" the same
  second) cannot be spaced here — split the call itself when the display order matters
  (cf. `Fleet.Workflow.Git.ensure_remote_branch/4`), or accept the tie when the call is
  unsplittable (orphan `work/ops` push, cf. `ProjectOnboard`).
  """

  @doc """
  Inserts the configured gap (`:fleet_pilot, :forge_write_spacing_ms`, default 2000ms; 0 in test → no-op,
  cf. `config/test.exs`; the `:fleet_pilot` config atom is legacy-valid, D-07 — kept to avoid a config
  migration). `:sleeper` seam in `opts` (test — captures the requested duration, does not actually
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
