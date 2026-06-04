defmodule Fleet.Coord.R1SeamSoftGateTest do
  @moduledoc """
  R1 — couture coord soft gate : le backend de spawn par défaut doit être
  CÂBLÉ, pas le placeholder `NotWiredYet` (qui transforme silencieusement
  toute soft gate en échec `:not_wired_yet`).

  ROUGE sur le code actuel (soft_gate.ex:82 défaut `HookSpawner.NotWiredYet`).
  Passe au vert avec R4 (D5=câbler : backend réel par défaut, NotWiredYet hors
  du chemin actif — R22).

  Tag `:r1_seam` — `mix test --only r1_seam`.
  """
  use ExUnit.Case, async: false

  @moduletag :r1_seam

  alias Fleet.Coord.SoftGate

  setup do
    # On force le DÉFAUT prod (pas de stub injecté) : la couture testée EST le
    # backend par défaut. Il doit être câblé, pas le placeholder.
    prev = Application.get_env(:fleet_coord, :spawner_backend)
    Application.delete_env(:fleet_coord, :spawner_backend)

    on_exit(fn ->
      if is_nil(prev),
        do: Application.delete_env(:fleet_coord, :spawner_backend),
        else: Application.put_env(:fleet_coord, :spawner_backend, prev)
    end)

    :ok
  end

  # T5 — soft gate atteint une décision via un backend câblé.
  test "T5 — soft gate ne tombe pas sur le placeholder NotWiredYet" do
    result = SoftGate.invoke_soft_gate(%{}, %{}, %{}, max_rounds: 1)

    # RED : défaut NotWiredYet → {:fail, "soft gate spawn error: :not_wired_yet"}.
    # Après R4 : le défaut est un backend réel → tout sauf ce message.
    refute match?({:fail, "soft gate spawn error: :not_wired_yet"}, result),
           "soft gate a tapé le placeholder NotWiredYet — backend non câblé (R4). Got: #{inspect(result)}"
  end
end
