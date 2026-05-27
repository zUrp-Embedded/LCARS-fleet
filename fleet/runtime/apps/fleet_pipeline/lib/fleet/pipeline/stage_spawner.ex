defmodule Fleet.Pipeline.StageSpawner do
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

defmodule Fleet.Pipeline.StageSpawner.Default do
  @moduledoc """
  Délégation directe à `Fleet.CapProfile` + `Fleet.Spawner`.

  `profile` peut être `nil` (rôle nu), une string (modop unique), ou
  une liste (composition ordonnée last-wins).
  """

  @behaviour Fleet.Pipeline.StageSpawner

  @impl Fleet.Pipeline.StageSpawner
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
      # `Fleet.Spawner.spawn_pod/3` retourne `{:ok, pid}` (Erlang OTP),
      # PAS le pod_id string. Pour exposer le pod_id au StageRunner
      # (TaskQueue routing `_lcars_pod_id`, PodRegistry mapping), on
      # le génère en amont et le passe via `opts[:pod_id]`.
      pod_id = Keyword.get_lazy(opts, :pod_id, fn -> UUID.uuid4() end)

      opts =
        opts
        |> Keyword.put(:pod_id, pod_id)
        # PUSH (modèle fleet) : le TRAVAIL de la stage est livré au pod via le brief (opts[:mandate]),
        # construit depuis stage_ctx. Sinon le pod recevrait un brief générique sans sa tâche.
        |> Keyword.put_new(:mandate, build_mandate(stage_ctx))

      case Fleet.Spawner.spawn_pod(cap_profile, ticket_id, opts) do
        {:ok, _pid} -> {:ok, pod_id}
        {:ok, _pid, _info} -> {:ok, pod_id}
        {:error, _} = err -> err
      end
    end
  end

  # Mandat textuel livré au pod (brief) : la stage + le mandat + les inputs résolus des stages amont.
  defp build_mandate(stage_ctx) do
    stage = Map.get(stage_ctx, :stage)
    mandate = Map.get(stage_ctx, :mandate)
    inputs = Map.get(stage_ctx, :inputs, %{})

    [
      if(is_binary(stage), do: "Stage : #{stage}"),
      if(not is_nil(mandate), do: "Mandat : #{inspect(mandate)}"),
      if(is_map(inputs) and map_size(inputs) > 0,
        do: "Inputs (stages amont) : #{inspect(inputs)}"
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp resolve_cap_profile(role, []), do: Fleet.CapProfile.load(role)
  defp resolve_cap_profile(role, modops), do: Fleet.CapProfile.compose(role, modops)
end
