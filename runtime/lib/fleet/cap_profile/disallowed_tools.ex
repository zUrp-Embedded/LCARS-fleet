defmodule Fleet.CapProfile.DisallowedTools do
  @moduledoc """
  Resolves a profile's effective `spec.scope.disallowedTools`.

  Existing entries are followed by the runtime's bundled git-denied baseline
  and profile-specific `git_ops_denied` patterns, with duplicates removed.
  The baseline lives outside operator catalogues and fails closed when unreadable.
  """

  alias Fleet.CapProfile

  @doc """
  Converts non-empty `git_ops_denied` entries to `Bash(git <entry>:*)` patterns.
  """
  @spec git_ops_denied_patterns(CapProfile.t()) :: [String.t()]
  def git_ops_denied_patterns(%CapProfile{spec: spec}) do
    spec
    |> get_in(["scope", "git_ops_denied"])
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.map(&"Bash(git #{&1}:*)")
  end

  @doc """
  Adds baseline and profile git-denial patterns after existing disallowed tools.

  The union preserves order, removes duplicates, and is idempotent.
  """
  @spec with_resolved(CapProfile.t()) :: CapProfile.t()
  def with_resolved(%CapProfile{spec: spec} = profile) do
    baseline = baseline_patterns()
    profile_patterns = git_ops_denied_patterns(profile)
    existing = get_in(spec, ["scope", "disallowedTools"]) || []
    augmented = Enum.uniq(existing ++ baseline ++ profile_patterns)

    new_scope =
      spec
      |> Map.get("scope", %{})
      |> Map.put("disallowedTools", augmented)

    %{profile | spec: Map.put(spec, "scope", new_scope)}
  end

  @doc """
  Returns the bundled universal git-denial patterns.

  The parsed baseline is cached. Unreadable YAML or a missing/non-list git_ops_denied
  raises; empty and non-string list entries are discarded, not rejected.
  """
  @spec baseline_patterns() :: [String.t()]
  def baseline_patterns do
    load_baseline_git_ops_denied!()
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.map(&"Bash(git #{&1}:*)")
  end

  defp load_baseline_git_ops_denied! do
    Fleet.SchemaCache.cached(
      {__MODULE__, :baseline_git_ops_denied},
      &read_baseline_git_ops_denied!/0
    )
  end

  defp read_baseline_git_ops_denied! do
    path =
      :lcars_fleet
      |> :code.priv_dir()
      |> to_string()
      |> Path.join("cap_profile/baseline/git-denied.yaml")

    case YamlElixir.read_from_file(path) do
      {:ok, %{"git_ops_denied" => entries}} when is_list(entries) ->
        entries

      {:ok, _other} ->
        raise "DisallowedTools: baseline #{path}: key `git_ops_denied` absent or invalid format (intangible baseline — fail-closed)"

      {:error, reason} ->
        raise "DisallowedTools: baseline #{path} absent or corrupt (#{inspect(reason)}) (intangible baseline — fail-closed)"
    end
  end
end
