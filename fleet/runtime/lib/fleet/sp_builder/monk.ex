defmodule Fleet.SPBuilder.Monk do
  @moduledoc """
  Monk-injection resolution — split out of `Fleet.SPBuilder` (a distinct data
  source: a YAML registry, the composer's only non-markdown I/O).

  If the cap-profile carries `spec.knowledge.{monk_registry, monk_instance}`, the
  module reads the YAML registry (memory registry, shape `spec.monks`), finds the
  `monk_instance` entry and returns `%{persona_hint, corpus_paths}`. The injection
  is purely ADDITIVE: for a non-monk, the `compose/3` flow stays byte-identical (no
  branch traverses it) — that is the contract of `resolve_or_empty/2`.

  **Pure** functions (FS read only, no process). The composer's public API stays
  `Fleet.SPBuilder.resolve_monk_injection/2` (defdelegate to `resolve/2`).

  ## Monks are FROZEN — reactivation is dormant by design (F-C153)

  The registry root defaults to `app_dir(:fleet_cap_profile, "priv/canon/cap-profiles/monks")`, a tree that
  is **intentionally ABSENT**: the monks were FROZEN into `apps/fleet_cap_profile/priv/canon/_frozen-monks/`
  (deliberately NOT scanned). No ACTIVE cap-profile carries `spec.knowledge.{monk_registry, monk_instance}`,
  so `resolve_or_empty/2` returns `:not_a_monk` → the empty injection everywhere (the `compose/3` flow stays
  byte-identical). A "Memory-X reactivation" (setting the monk fields) would target the absent
  `cap-profiles/monks/` and fail — this is the DORMANT-by-design state (kept, documented) until an explicit
  thaw wires the frozen tree back as the registry root. See also the LEGACY banner in `runtime/priv/canon/README.md`.
  """

  @type injection :: %{persona_hint: String.t(), corpus_paths: [String.t()]}

  @doc """
  Resolves the cap-profile's monk injection.

    * `{:ok, %{persona_hint, corpus_paths}}` — monk cap-profile, entry found.
    * `:not_a_monk` — no `monk_registry`/`monk_instance` in `spec.knowledge`.
    * `{:error, {:registry_unreadable, path, reason}}` — YAML unreadable.
    * `{:error, {:not_a_memory_registry, path}}` — YAML without `spec.monks` (list).
    * `{:error, {:monk_instance_not_found, instance}}` — instance absent from the registry.

  ## opts

    * `:monk_registry_root` — root resolving the registry's relative path
      (test-seam; defaults to config `:fleet_sp_builder, :monk_registry_root`
      then `Application.app_dir(:fleet_cap_profile, "priv/canon/cap-profiles/monks")`).

  The `monk_registry` field in the cap-profile = basename (e.g. `alpha.yaml`)
  — the code resolves it via `:monk_registry_root`. It is NOT an absolute path:
  the registry lives in-repo under the root, never an external doctrine path.
  """
  @spec resolve(Fleet.CapProfile.t(), keyword()) ::
          {:ok, injection()} | :not_a_monk | {:error, term()}
  def resolve(%Fleet.CapProfile{spec: spec}, opts \\ []) do
    knowledge = Map.get(spec, "knowledge", %{})
    registry_rel = Map.get(knowledge, "monk_registry")
    instance = Map.get(knowledge, "monk_instance")

    cond do
      is_nil(registry_rel) or is_nil(instance) ->
        :not_a_monk

      true ->
        root =
          Keyword.get(opts, :monk_registry_root) ||
            Application.get_env(:fleet_sp_builder, :monk_registry_root) ||
            Application.app_dir(:fleet_cap_profile, "priv/canon/cap-profiles/monks")

        path = Path.join(root, registry_rel)

        with {:ok, reg} <- read_registry(path),
             {:ok, monk} <- find_monk(reg, instance) do
          {:ok,
           %{
             persona_hint: Map.get(monk, "persona_hint", ""),
             corpus_paths: Map.get(monk, "corpus_paths", [])
           }}
        end
    end
  end

  @doc """
  Variant for the `compose/3` flow: `:not_a_monk` → EMPTY injection
  (`persona_hint: ""`, `corpus_paths: []`) so the flow stays byte-identical
  for a non-monk; `{:error, _}` → propagated (fail-loud).
  """
  @spec resolve_or_empty(Fleet.CapProfile.t(), keyword()) ::
          {:ok, injection()} | {:error, term()}
  def resolve_or_empty(cap_profile, opts) do
    case resolve(cap_profile, opts) do
      {:ok, inj} -> {:ok, inj}
      :not_a_monk -> {:ok, %{persona_hint: "", corpus_paths: []}}
      {:error, _} = err -> err
    end
  end

  @doc """
  Markdown "Monk persona" section to concatenate to the SP's modop fragments:
  empty if `persona_hint` is empty (non-monk → no byte added to the SP).
  """
  @spec persona_section(injection()) :: String.t()
  def persona_section(%{persona_hint: ""}), do: ""

  def persona_section(%{persona_hint: ph}) when is_binary(ph),
    do: "\n\n## Monk persona\n\n" <> ph

  defp read_registry(path) do
    # No `kind` attribute (a single kind per `monks/*.yaml` folder, the path
    # declares the role). Validation = presence of `spec.monks` in the expected
    # shape (list), not a `kind` embedded in the YAML.
    case YamlElixir.read_from_file(path) do
      {:ok, %{"spec" => %{"monks" => monks}} = reg} when is_list(monks) ->
        {:ok, reg}

      {:ok, _} ->
        {:error, {:not_a_memory_registry, path}}

      {:error, reason} ->
        {:error, {:registry_unreadable, path, reason}}
    end
  end

  defp find_monk(reg, instance) do
    monks = get_in(reg, ["spec", "monks"]) || []

    case Enum.find(monks, &(Map.get(&1, "name") == instance)) do
      nil -> {:error, {:monk_instance_not_found, instance}}
      monk -> {:ok, monk}
    end
  end
end
