defmodule Fleet.Pilot.StepDispatcher.Spawn.Naming do
  @moduledoc """
  Spawn opts builders / naming, extracted from `StepDispatcher.Spawn`: everything that
  NAMES or RESOLVES an identity datum embedded in the `spawn_opts` (Desktop RC
  label, branch slug, written route, forge repo_id). Quasi-pure (only
  `resolve_repo_id/3` reads the forge), zero spawn decision — the `Spawn` leaf keeps
  the MECHANIC (order lock→pod→enqueue→wake, compensation, scope serialization).

  Shared by the dispatcher's TWO flows (issue via `StepDispatcher`, review via
  `ReviewLifecycle.RoleDispatch`) — one copy of each, never a fork.
  """

  @doc """
  Desktop RC name = `<project>_<role>` (project = final segment of the repo, e.g.
  `fleet/poc-8` → `poc-8`). EXACT label (claude_launch → `--remote-control "<name>"`, zero auto
  suffix). Distinct from the pod_id (repo-scoped technical key); here it is the human-readable Desktop label.
  """
  @spec rc_name(String.t(), String.t()) :: String.t()
  def rc_name(repo, role), do: "#{project_name(repo)}_#{role}"

  # Path/name-safe project name (charset [A-Za-z0-9-], zero space/`/`/`_`).
  # Final segment of the repo, sanitized. It is THE source of `<project>` everywhere downstream (Desktop RC name,
  # SANDBOX_HOME `/home/<project>`, seed-store, branch) via `rc_name` → a single point of truth, clean.
  # No `_` (rc_name separator `<project>_<role>` → would keep the ambiguity).
  defp project_name(repo),
    do: repo |> String.split("/") |> List.last() |> String.replace(~r/[^A-Za-z0-9-]/, "-")

  @doc """
  Speaking slug from the issue title for the LOCAL branch (`feature/<slug>`).
  Sanitized + truncated; empty → `work`. No pod_id/human leak.
  """
  @spec feature_slug(map()) :: String.t()
  def feature_slug(issue) do
    (issue["title"] || "")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 40)
    |> case do
      "" -> "work"
      s -> s
    end
  end

  # (The conditional puts of ONE key — `:project`, `:repo_id` — go through the single source
  # `Fleet.Pilot.Opts.maybe_put/3` at the call sites: no more fixed-key wrapper here. Only
  # `maybe_put_route/2` lives here — it puts TWO coupled keys, which is not the maybe_put idiom.)

  @doc "Puts `:workflow_map`/`:step` into the spawn_opts if the route is present (nil = no-op)."
  @spec maybe_put_route(keyword(), {String.t(), String.t()} | nil) :: keyword()
  def maybe_put_route(spawn_opts, nil), do: spawn_opts

  def maybe_put_route(spawn_opts, {workflow_map_name, step}),
    do: spawn_opts |> Keyword.put(:workflow_map, workflow_map_name) |> Keyword.put(:step, step)

  @doc """
  Resolves the forge `repo_id` (bounded to `<REPO4>` = `rem(id, 10000)`) — the project's forge id makes the
  deterministic session_id of project-bound roles (eng, judges) via `Fleet.Spawner.SessionId`
  (DECIMAL `<REPO4>` segment). Forge without `repo_id/2` (stub) / forge down / absent id → `nil`
  (no `:repo_id` put — `Opts.maybe_put` swallows the nil at the call site). A project-bound role
  spawned WITHOUT a repo is then an ANOMALY: the mint (`Fleet.Spawner.Pod.SessionMint`) FAILS-LOUD (raises)
  — we NEVER fabricate a random UUID to mask an unresolved forge (forge = organ of
  LCARS, forge down = stop). `rem(id, 10000)`: `<REPO4>` = 4 decimal digits → assumed DEBT,
  repo 10000 collides with repo 0 (we will not reopen the old one; cf. SessionId moduledoc).
  """
  @spec resolve_repo_id(module(), String.t(), keyword()) :: non_neg_integer() | nil
  def resolve_repo_id(forge, repo, forge_opts) do
    if function_exported?(forge, :repo_id, 2) do
      case forge.repo_id(repo, forge_opts) do
        {:ok, id} when is_integer(id) and id >= 0 -> rem(id, 10000)
        _ -> nil
      end
    else
      nil
    end
  end
end
