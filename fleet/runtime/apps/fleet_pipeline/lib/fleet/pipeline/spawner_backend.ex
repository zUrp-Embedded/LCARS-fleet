defmodule Fleet.Pipeline.SpawnerBackend do
  @moduledoc """
  Behaviour wrap autour de `Fleet.Spawner.spawn_pod/3` (chantier 6
  PROMOTED).

  StageRunner et Gates dépendent de cette indirection plutôt que d'un
  appel direct, ce qui permet :

    * tests sans bwrap réel (stub broadcast `:pipeline_stage_completed`
      synchronement)
    * fallback gatekeeper cap-profile `:terminal` gate (même seam)

  Default `Default` délègue à
  `Fleet.CapProfile.compose/2` + `Fleet.Spawner.spawn_pod/3`.
  """

  @callback spawn_stage_pod(
              role :: String.t(),
              profile :: String.t() | [String.t()] | nil,
              stage_ctx :: map()
            ) :: {:ok, pod_id :: term()} | {:error, reason :: term()}
end

defmodule Fleet.Pipeline.SpawnerBackend.Default do
  @moduledoc """
  Délégation directe à `Fleet.CapProfile` + `Fleet.Spawner`.

  `profile` peut être `nil` (rôle nu), une string (modop unique), ou
  une liste (composition ordonnée last-wins).
  """

  @behaviour Fleet.Pipeline.SpawnerBackend

  @impl Fleet.Pipeline.SpawnerBackend
  def spawn_stage_pod(role, profile, stage_ctx) when is_binary(role) do
    modops =
      case profile do
        nil -> []
        bin when is_binary(bin) -> [bin]
        list when is_list(list) -> list
      end

    with {:ok, cap_profile} <- resolve_cap_profile(role, modops),
         ticket_id <- Map.get(stage_ctx, :ticket_id, "pipeline-anonymous"),
         opts <- Map.get(stage_ctx, :spawn_opts, []) do
      Fleet.Spawner.spawn_pod(cap_profile, ticket_id, opts)
    end
  end

  defp resolve_cap_profile(role, []), do: Fleet.CapProfile.load(role)
  defp resolve_cap_profile(role, modops), do: Fleet.CapProfile.compose(role, modops)
end
