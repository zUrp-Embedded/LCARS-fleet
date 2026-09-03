defmodule Fleet.MCP.PodTools.Delegation.Render do
  @moduledoc """
  What the delegation channels put in the map they hand back to the pod.

  Two writers, and both exist because a key present with `nil` is not the same answer as a key
  ABSENT: the first reads as "the fleet looked and found nothing", the second as "the fleet did
  not look". Every channel renders the same way, so the two readings never diverge between tools.
  """

  @doc false
  @spec put_present(map(), String.t(), term()) :: map()
  def put_present(map, _key, nil), do: map
  def put_present(map, key, value), do: Map.put(map, key, value)

  # Report a present architect without requiring test seams to return it.
  @doc false
  @spec put_architect(map(), map()) :: map()
  def put_architect(rendered, result) do
    case Map.get(result, :architect) do
      %{status: status} = arch ->
        Map.put(
          rendered,
          "architect",
          %{
            "status" => status,
            "pod_id" => Map.get(arch, :pod_id),
            "reason" => Map.get(arch, :reason)
          }
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)
          |> Map.new()
        )

      _ ->
        rendered
    end
  end
end
