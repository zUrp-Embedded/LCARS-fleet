defmodule Fleet.MCP.PodTools.Delegation.Render do
  @moduledoc """
  Shared optional-field rendering. put_present omits nil, but retains empty lists
  and other values; callers decide their meaning. put_architect requires a status
  map and omits its nil fields. Neither helper removes an already-present key.
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
