defmodule Fleet.Coord.HookSpawner do
  @moduledoc """
  Behaviour wrap autour de `Fleet.Spawner.spawn_pod/3` (chantier 6
  PROMOTED) pour `SoftGate` et `Hook`.

  Permet aux tests d'injecter un stub sans bwrap réel.

  ## Format retour pod

  Le pod jetable PoC-π2 doit retourner `{:ok, %{decision: ..., ...}}`
  ou `{:error, reason}`. Décisions supportées :

    * SoftGate : `"pass"` / `"fail"` (avec `reason`) / `"retry"`
    * Hook : `"continue"` / `"halt"` (avec `reason`)
  """

  @callback spawn_pod(
              role :: atom(),
              cap_profile :: map(),
              args :: map()
            ) :: {:ok, map()} | {:error, term()}
end

defmodule Fleet.Coord.HookSpawner.NotWiredYet do
  @moduledoc """
  Délégation à `Fleet.Spawner.spawn_pod/3`.

  Note : ch6 `Fleet.Spawner.spawn_pod/3` retourne `{:ok, pid}` et
  démarre un GenServer pod. Pour le pattern PoC-π2 fire-mode (résultat
  synchrone), on attend que le pod ait fini son cycle EXTRACT et
  retourne ses outputs structurés. Cette adaptation est faite ici
  (call synchrone bloc jusqu'au résultat).

  En attendant le wiring complet ch7 `fleet_pod_runtime` EXTRACT JSON,
  cet adapter retourne `{:error, :not_wired_yet}`. Tests utilisent
  `HookSpawnerStub` configuré via `Application.put_env`.
  """

  @behaviour Fleet.Coord.HookSpawner

  @impl Fleet.Coord.HookSpawner
  def spawn_pod(_role, _cap_profile, _args) do
    {:error, :not_wired_yet}
  end
end
