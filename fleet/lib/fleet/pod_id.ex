defmodule Fleet.PodId do
  use Boundary, deps: [], exports: []

  @moduledoc """
  Owns deterministic, repository-scoped and path-safe pod identifiers.

  FOUNDATION, next to `Fleet.Layout` which owns the human-facing twin (`pod_label/3`): a naming
  authority has to sit where every namer can reach it. Housed inside `Fleet.Pilot`, the pod-id
  FORMAT would sit ABOVE two of its consumers — `Fleet.Spawner`, which owns the Registry these ids
  key, and `Fleet.Project`, which removes a project and must first find the pods on it. Neither
  could reach it (`Fleet.Pilot` depends on `Fleet.Project`, so the reverse edge is a cycle boundary
  refuses), leaving only a re-derivation of `slug(repo) <> "-"` at the call site — A SECOND SOURCE
  FOR A FORMAT WHOSE WHOLE POINT IS HAVING ONE. It has zero runtime dependency, so nothing about it
  belongs up there.

  Instance ids encode issue or PR number; project ids key a stable `(repo, role)` slot. Consumers may
  recover only the repo-anchored instance reference, keeping the rest of the identifier opaque.
  """

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
  Builds a project-scoped id `<repo-slug>-<role>` without an issue or PR number.
  """
  @spec for_repo(String.t(), String.t()) :: String.t()
  def for_repo(repo, role) when is_binary(role), do: scope_prefix(repo) <> component(role)

  @doc """
  Returns the repository prefix shared by all of its pod ids.
  """
  @spec scope_prefix(String.t()) :: String.t()
  def scope_prefix(repo) when is_binary(repo), do: "#{slug(repo)}-"

  @doc """
  Extracts a positive issue or PR reference only when the id belongs to the supplied repository.
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

  # This transforms into the pod-id charset; it is not Fleet.Slug validation or vendor slugging.
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
