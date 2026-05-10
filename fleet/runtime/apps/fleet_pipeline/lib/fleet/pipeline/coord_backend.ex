defmodule Fleet.Pipeline.CoordBackend do
  @moduledoc """
  Behaviour wrap autour de `Fleet.Coord.invoke_soft_gate/4` (chantier 14).

  Permet de différer la dep `fleet_coord` jusqu'au câblage chantier 14.
  Default `NotWiredYet` retourne `{:fail, "fleet_coord (ch14) pas encore
  câblé"}` cohérent canon §0 #1 refus par défaut.
  """

  @callback invoke_soft_gate(
              stage :: map(),
              outputs :: map(),
              ctx :: map(),
              opts :: keyword()
            ) :: :pass | {:fail, reason :: String.t()} | :retry

  @callback invoke_hook(name :: String.t(), ctx :: map()) ::
              :ok | {:halt, reason :: String.t()} | {:error, term()}
end

defmodule Fleet.Pipeline.CoordBackend.NotWiredYet do
  @moduledoc false

  @behaviour Fleet.Pipeline.CoordBackend

  @impl Fleet.Pipeline.CoordBackend
  def invoke_soft_gate(_stage, _outputs, _ctx, _opts) do
    {:fail, "soft gate: fleet_coord (chantier 14) pas encore câblé"}
  end

  @impl Fleet.Pipeline.CoordBackend
  def invoke_hook(_name, _ctx), do: :ok
end
