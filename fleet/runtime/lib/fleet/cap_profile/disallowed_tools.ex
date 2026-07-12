defmodule Fleet.CapProfile.DisallowedTools do
  @moduledoc """
  Write-time resolution of a pod's effective `disallowedTools` list:
  the universal git-denied baseline ∪ the worker cap-profile's patterns.

  Cluster extracted from `Fleet.CapProfile`. SINGLE concern: `spec.scope.disallowedTools`
  (written) + `spec.scope.git_ops_denied` (read as input). Reads/writes NO other
  face of the profile.

  Single dependency direction (no cycle): this module depends on the
  `%Fleet.CapProfile{}` struct (compile-dep); `Fleet.CapProfile` calls this module via
  three delegators — `with_resolved_disallowed_tools/1` (consumed by
  the `:allocating` state step of `Fleet.Spawner.Pod`), `git_ops_denied_patterns/1`,
  `baseline_git_ops_denied_patterns/0` (runtime-dep). The public API
  `Fleet.CapProfile.*` does not move. Calls NEITHER `Schema` NOR `Invariants` NOR the
  `load`/`compose` core.

  I/O: reads the IMMUTABLE priv baseline `priv/cap_profile/canon/cap-profiles/_baseline-git-denied.yaml`
  (resolved via `:code.priv_dir(:lcars_fleet)` — the same file as before the
  extraction), read+parse cached once in `:persistent_term` (lazy-init; errors not
  cached — the bang re-raises on the next call).
  """

  # Source struct (compile-dep): the fns pattern-match `%CapProfile{}` and the
  # `@spec` references `CapProfile.t()`. No cycle (see moduledoc).
  alias Fleet.CapProfile

  @doc """
  Translates the semantic entries `spec.scope.git_ops_denied` (e.g. `"push --force"`,
  `"reset --hard"`) into claude CLI `disallowedTools` patterns of the form
  `Bash(git <entry>:*)`. Empty/non-binary entries are ignored. Input order
  preserved. Pure.

  Generic catalogue → claude CLI mechanism: what was a declarative line validated
  by G24 in isolation becomes a constraint effectively enforced by claude CLI at
  pod launch (disallow wins over allow on the same pattern).
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
  Returns a `%CapProfile{}` whose `spec.scope.disallowedTools` is augmented with:
  - the patterns of the **universal baseline** (`_baseline-git-denied.yaml`,
    intangible by guiding principle)
  - THEN the patterns from `git_ops_denied_patterns/1` (worker-specific cap-profile).
  Deduplicated union, order preserved: existing, baseline, profile.
  Idempotent.

  Application point: the `:allocating` state step of `Fleet.Spawner.Pod` when writing
  `.cap-profile.json` into the pod, so that `claude_launch.sh` receives the
  already-resolved list. Exposed as `Fleet.CapProfile.with_resolved_disallowed_tools/1`
  (delegator — that is the name the spawner consumes).
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
  The `disallowedTools` patterns from the universal baseline
  (`priv/cap_profile/canon/cap-profiles/_baseline-git-denied.yaml`). Intangible patterns
  denied to ALL workers regardless of the cap-profile — removing a pattern is an
  explicit architectural decision (edit the baseline file, not a cap-profile
  option).

  **Raises** if the baseline file is absent, unreadable, or of an invalid
  format. The baseline is doctrinally "intangible": a silent fail-open
  (returning `[]`) would disable the universal denylist without alerting,
  contradicting the intent → fail-closed. The caller (`pod.ex`, `:allocating` state)
  catches via `rescue` and transitions to `:failed` cleanly.

  Pure modulo file I/O; read+parse cached in `:persistent_term`.
  """
  @spec baseline_patterns() :: [String.t()]
  def baseline_patterns do
    load_baseline_git_ops_denied!()
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.map(&"Bash(git #{&1}:*)")
  end

  # IMMUTABLE priv baseline: read+parse once, cached in `:persistent_term`
  # (lazy-init; an error is not cached — the bang re-raises on the next call).
  # DELIBERATE local copy of the `Fleet.SchemaCache.cached/2` skeleton (fleet_event_router —
  # the Ring 0 authority for load-once-cache): fleet_cap_profile is Ring 0 WITHOUT a dep onto
  # fleet_event_router, and we do not add an intra-R0 boundary dep (`use Boundary`) for ten lines.
  # If the edge appears one day for another reason, migrate this site (and `CapProfile.Schema`).
  defp load_baseline_git_ops_denied! do
    key = {__MODULE__, :baseline_git_ops_denied}

    case :persistent_term.get(key, :miss) do
      :miss ->
        entries = read_baseline_git_ops_denied!()
        :persistent_term.put(key, entries)
        entries

      entries ->
        entries
    end
  end

  defp read_baseline_git_ops_denied! do
    path =
      :lcars_fleet
      |> :code.priv_dir()
      |> to_string()
      |> Path.join("cap_profile/canon/cap-profiles/_baseline-git-denied.yaml")

    case YamlElixir.read_from_file(path) do
      {:ok, %{"git_ops_denied" => entries}} when is_list(entries) ->
        entries

      {:ok, _other} ->
        raise "fleet_cap_profile baseline #{path}: key `git_ops_denied` absent or invalid format (intangible baseline — fail-closed)"

      {:error, reason} ->
        raise "fleet_cap_profile baseline #{path} absent or corrupt (#{inspect(reason)}) (intangible baseline — fail-closed)"
    end
  end
end
