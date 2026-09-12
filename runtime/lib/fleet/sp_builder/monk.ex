defmodule Fleet.SPBuilder.Monk do
  @moduledoc """
  Reads optional monk persona and corpus injection from a YAML registry.
  Missing knowledge keys produce no injection. The default registry is intentionally
  absent while the frozen monk catalogue is dormant.
  """

  @type injection :: %{persona_hint: String.t(), corpus_paths: [String.t()]}

  @doc """
  Resolves the first registry entry named monk_instance. Either missing/nil knowledge
  key returns :not_a_monk. Returned errors distinguish unreadable YAML, a missing
  spec.monks list and an absent instance.

  Registry root precedence: :monk_registry_root option, :sp_builder_monk_registry_root
  application config, Catalogue.monk_registry_root/0. The registry name is joined to
  that root without traversal or symlink checks; callers must supply a trusted path.
  Only the list container is checked. Malformed entries/profiles can raise, and persona/
  corpus values are returned without validating their types or filesystem existence.
  """
  @spec resolve(Fleet.CapProfile.t(), keyword()) ::
          {:ok, injection()} | :not_a_monk | {:error, term()}
  def resolve(%Fleet.CapProfile{spec: spec}, opts \\ []) do
    knowledge = Map.get(spec, "knowledge", %{})
    registry_rel = Map.get(knowledge, "monk_registry")
    instance = Map.get(knowledge, "monk_instance")

    if is_nil(registry_rel) or is_nil(instance) do
      :not_a_monk
    else
      root =
        Keyword.get(opts, :monk_registry_root) ||
          Application.get_env(:lcars_fleet, :sp_builder_monk_registry_root) ||
          Fleet.Catalogue.monk_registry_root()

      path = Path.join(root, registry_rel)

      with {:ok, monks} <- read_registry(path),
           {:ok, monk} <- find_monk(monks, instance) do
        {:ok,
         %{
           persona_hint: Map.get(monk, "persona_hint", ""),
           corpus_paths: Map.get(monk, "corpus_paths", [])
         }}
      end
    end
  end

  @doc """
  Converts :not_a_monk to empty persona/corpus for compose/3, adding no prompt bytes.
  Propagates returned errors; exceptions from resolve/2 are not caught.
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
    # No kind discriminator: check only spec.monks is a list, not the entries' schemas.
    case YamlElixir.read_from_file(path) do
      {:ok, %{"spec" => %{"monks" => monks}}} when is_list(monks) ->
        {:ok, monks}

      {:ok, _} ->
        {:error, {:not_a_memory_registry, path}}

      {:error, reason} ->
        {:error, {:registry_unreadable, path, reason}}
    end
  end

  defp find_monk(monks, instance) when is_list(monks) do
    case Enum.find(monks, &(Map.get(&1, "name") == instance)) do
      nil -> {:error, {:monk_instance_not_found, instance}}
      monk -> {:ok, monk}
    end
  end
end
