defmodule Fleet.Coord.SpawnerBackendStub do
  @moduledoc """
  Stub `SpawnerBackend` pour tests SoftGate + Hook.

  Configuration via `Application.put_env` :

    * `:fleet_coord, :stub_response` — `{:ok, %{decision: ..., reason: ...}}`
      ou `{:error, reason}` ou liste séquentielle pour scénarios retry
    * `:fleet_coord, :stub_invocations` — list collected (auto-reset
      via setup)
  """

  @behaviour Fleet.Coord.SpawnerBackend

  @impl Fleet.Coord.SpawnerBackend
  def spawn_pod(role, cap_profile, args) do
    invocations = Application.get_env(:fleet_coord, :stub_invocations, [])

    Application.put_env(
      :fleet_coord,
      :stub_invocations,
      [{role, cap_profile, args} | invocations]
    )

    case Application.get_env(:fleet_coord, :stub_response) do
      [head | rest] ->
        Application.put_env(:fleet_coord, :stub_response, rest)
        head

      response when is_tuple(response) ->
        response

      nil ->
        {:error, :stub_no_response_configured}
    end
  end
end
