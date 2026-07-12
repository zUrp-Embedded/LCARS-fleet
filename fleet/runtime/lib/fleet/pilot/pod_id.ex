defmodule Fleet.Pilot.PodId do
  @moduledoc """
  DETERMINISTIC semantic pod ID, **repo-scoped**.

  The pod_id is the pod's GLOBAL key: `Registry`, `task.pod_id` broker, `pod_dir`
  (`~/pods/pod_<id>`), sock, and tmux session name (`lcars-pod-<id>`). Without repo-scope,
  `issue-N-role` collides between repos/runs at the same number → a SINGLE pod for two distinct
  jobs (multi-repo / cross-repo delegation). The repo slug disambiguates.

  DETERMINISTIC (stable key, no timestamp suffix): same `(repo, n, role)` → same id → a re-dispatch falls back onto
  the live pod to RE-BRIEF it (keeps its context). The format lives ENTIRELY here: `for_issue`/`for_pr`
  BUILD it, `parse_ref/2` ANCHORS it (phase + instance number) for lock reconciliation. A single
  module knows the format -> no remote parser re-derives it (a format change breaks no one
  silently). We never reconstruct full `(n, role)` from the id (the role is not re-extracted): the id
  stays opaque to the outside, which goes through `parse_ref/2` rather than re-parsing the literal.

  The feature-branch (`lcars/issue-N-role`) stays **repo-LOCAL** (it lives IN the repo → no
  collision) → NOT scoped. pod_id and branch are built independently from `(n, role)`.

  Path-safe (contract `Fleet.Spawner.valid_pod_id?/1`) because interpolated into FS paths / tmux names.
  """

  # Instance phase markers — single LITERAL-SOURCE: `for_issue`/`for_pr` SET them,
  # `parse_ref` RECOGNIZES them. Renaming = this single point (no more token typed twice in builder/parser).
  # Pure alphanumerics -> no Regex.escape needed on the parser side.
  @phase_issue "issue"
  @phase_pr "pr"

  @doc "Producer pod_id (keyed by ISSUE): `<repo-slug>-issue-<n>-<role>`."
  @spec for_issue(String.t(), integer() | String.t(), String.t()) :: String.t()
  def for_issue(repo, n, role),
    do: Enum.join([slug(repo), @phase_issue, component(n), component(role)], "-")

  @doc "Judge pod_id (keyed by PR): `<repo-slug>-pr-<n>-<role>`."
  @spec for_pr(String.t(), integer() | String.t(), String.t()) :: String.t()
  def for_pr(repo, n, role),
    do: Enum.join([slug(repo), @phase_pr, component(n), component(role)], "-")

  @doc """
  PROJECT pod_id (keyed by repo ALONE, without a number): `<repo-slug>-<role>`. For `slot_scope:
  project` roles (engineer, fleet-level singletons): ONE identity per (repo, role) → a re-dispatch of
  ANY issue/PR of the repo falls back onto the SAME pod_id → ONE stable Desktop slot (frozen cwd +
  session-id), dispatch serialized by (repo, role). To contrast with `for_issue`/`for_pr` (keyed by
  instance → fan-out). Reuses `scope_prefix/1` (single source of the slug). The role (`engineer`, …) never
  contains `-issue-`/`-pr-` → no collision with an instance id.
  """
  @spec for_repo(String.t(), String.t()) :: String.t()
  def for_repo(repo, role) when is_binary(role), do: scope_prefix(repo) <> component(role)

  @doc """
  REPO scope prefix of a pod_id: `<repo-slug>-`. It's the ANCHOR that qualifies a lock
  key by repo. Every pod_id of the repo starts with it (`for_issue`/`for_pr` set `<slug>-issue|pr-…`).
  SINGLE source of the slug (the same as `for_issue`/`for_pr`) → the reconciliation scopes its refs by repo
  without re-deriving the format. (`PodId` stays opaque: we don't re-parse the id, we ANCHOR it by prefix.)
  """
  @spec scope_prefix(String.t()) :: String.t()
  def scope_prefix(repo) when is_binary(repo), do: "#{slug(repo)}-"

  @doc """
  Recognizes the INSTANCE marker a pod_id encodes (`issue`/`pr` + number), anchored on the repo
  scope. Partial inverse of `for_issue`/`for_pr`: the authority that BUILDS the format also RECOGNIZES it,
  so that no remote parser has to re-derive the literal (a format change would otherwise break
  a distant reader silently). We extract ONLY the phase and the number (never the role) -> the id stays
  opaque on its full semantics.

  `{:ok, {:issue | :pr, n}}` if `pod_id` belongs to the repo and encodes an instance;
  `:error` otherwise (other repo, or project pod_id `<repo>-<role>` without `-issue|pr-N-`).
  """
  @spec parse_ref(String.t(), String.t()) :: {:ok, {:issue | :pr, pos_integer()}} | :error
  def parse_ref(pod_id, repo) when is_binary(pod_id) and is_binary(repo) do
    prefix = Regex.escape(scope_prefix(repo))

    case Regex.run(~r/^#{prefix}(#{@phase_issue}|#{@phase_pr})-(\d+)-/, pod_id) do
      [_, @phase_issue, n] -> {:ok, {:issue, String.to_integer(n)}}
      [_, @phase_pr, n] -> {:ok, {:pr, String.to_integer(n)}}
      _ -> :error
    end
  end

  def parse_ref(_, _), do: :error

  # `owner/name` → `owner-name`; any char outside the path-safe charset → `-`.
  # Runs of `.` are reduced to satisfy the spawner contract (`..` forbidden
  # even if the charset allows it).
  #
  # DISTINCT SLUG DOMAIN (do not merge): `component` TRANSFORMS toward the pod_id charset
  # `[A-Za-z0-9._-]` (case + `.` preserved, contract `valid_pod_id?`). It is NEITHER `Fleet.Slug`
  # (VALIDATES/rejects, strict lowercase, no `.`), NOR `SeedStore.slugify` (Claude vendor compat).
  defp slug(repo) when is_binary(repo) do
    repo
    |> String.replace("/", "-")
    |> component()
  end

  defp component(n) when is_integer(n), do: Integer.to_string(n)

  defp component(value) when is_binary(value) do
    value
    |> String.replace(~r/[^A-Za-z0-9._-]/, "-")
    |> String.replace(~r/\.{2,}/, ".")
  end
end
