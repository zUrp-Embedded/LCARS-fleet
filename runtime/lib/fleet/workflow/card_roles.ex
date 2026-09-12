defmodule Fleet.Workflow.CardRoles do
  @moduledoc """
  Checks card-to-role references against this catalogue's and catalogue-system's profile names.
  A peer business catalogue, including fleet, is never a role fallback. This complements the
  profile/prompt image checks: individually valid trees can still have a dev/developer mismatch.
  Boot and installation use the check before an unresolved role reaches dispatch.
  This is reference inventory, not full workflow-schema validation or credential provisioning.
  """

  alias Fleet.Catalogue

  @doc """
  Returns missing {card, role} pairs from sorted top-level *.yaml files, deduplicated per card.
  Missing/non-directory card root returns {:ok, []} without checking profiles. YAML read errors
  stop the inventory; malformed nested spec structures may raise. Non-binary roles are ignored.
  An empty result only proves no missing references were found in this scan.
  """
  @spec unresolved(Path.t()) :: {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def unresolved(root) when is_binary(root) do
    dir = Path.join(root, Catalogue.rel(:workflow_maps))

    if File.dir?(dir) do
      with {:ok, known} <- known_roles(root) do
        dir
        |> Path.join("*.yaml")
        |> Path.wildcard()
        |> Enum.sort()
        |> Enum.reduce_while({:ok, []}, &collect_unresolved(&1, &2, known))
      end
    else
      {:ok, []}
    end
  end

  # Do not return a partial successful inventory after a card read error.
  defp collect_unresolved(path, {:ok, acc}, known) do
    case roles_of(path) do
      {:ok, roles} ->
        card = Path.basename(path, ".yaml")
        missing = roles |> Enum.reject(&MapSet.member?(known, &1)) |> Enum.map(&{card, &1})
        {:cont, {:ok, acc ++ missing}}

      {:error, reason} ->
        {:halt, {:error, {:cards_unreadable, path, reason}}}
    end
  end

  @doc """
  Raises on missing references or returned read errors from unresolved/1; otherwise :ok.
  Boot and installation share this check, each against the files present at that time.
  """
  @spec verify!(Path.t()) :: :ok
  def verify!(root) when is_binary(root) do
    case unresolved(root) do
      {:ok, []} ->
        :ok

      {:ok, missing} ->
        detail = Enum.map_join(missing, ", ", fn {card, role} -> "#{card} -> #{role}" end)

        raise "Workflow.CardRoles: #{root} — #{detail}. A card names a role and the role must be " <>
                "declared by THIS catalogue or by the system layer; a peer catalogue is not a " <>
                "fallback. Unresolved, the ticket dies at dispatch instead of here."

      {:error, reason} ->
        raise "Workflow.CardRoles: #{root} — cards unreadable (#{inspect(reason)}). A catalogue " <>
                "whose cards cannot be parsed cannot be served, and guessing which roles they name " <>
                "would be worse than refusing."
    end
  end

  # Missing profile directories contribute no names, allowing cards that only use system roles.
  defp known_roles(root) do
    [
      Path.join(root, Catalogue.rel(:cap_profiles)),
      Path.join(Catalogue.system_root(), Catalogue.rel(:cap_profiles))
    ]
    |> Enum.reduce_while({:ok, MapSet.new()}, fn dir, {:ok, acc} ->
      # Use the exported CapProfile facade; Catalog remains internal to its boundary.
      case Fleet.CapProfile.index_of(dir) do
        {:ok, index} -> {:cont, {:ok, MapSet.union(acc, MapSet.new(Map.keys(index)))}}
        {:error, :enoent} -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, {:profiles_unreadable, dir, reason}}}
      end
    end)
  end

  # Steps normally form a name-keyed map (legacy lists accepted). List.wrap(map) would hide
  # every step role. Read jury both at spec root and per step.
  defp roles_of(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, %{} = yaml} ->
        spec = Map.get(yaml, "spec", yaml)
        steps = Map.get(spec, "steps", %{})

        per_step =
          case steps do
            %{} = m -> Map.values(m)
            l when is_list(l) -> l
            _ -> []
          end

        roles =
          [jury(spec)] ++ Enum.map(per_step, fn s -> [role_of(s)] ++ jury(s) end)

        {:ok, roles |> List.flatten() |> Enum.filter(&is_binary/1) |> Enum.uniq() |> Enum.sort()}

      {:ok, other} ->
        {:error, {:not_a_map, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp role_of(%{} = step), do: Map.get(step, "role")
  defp role_of(_), do: nil

  defp jury(%{} = m), do: m |> Map.get("jury", []) |> List.wrap()
  defp jury(_), do: []
end
