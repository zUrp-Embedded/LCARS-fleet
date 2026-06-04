defmodule Fleet.EventRouter.R1SeamDispatchTest do
  @moduledoc """
  R1 — couture events.yaml / Dispatch : un handler référencé qui n'existe pas
  doit refuser le BOOT (fail-loud), pas être toléré (warning au dispatch). C'est
  le verrou anti-récurrence de la classe « handler fantôme ».

  ROUGE sur le code actuel (Dispatch.init charge la table sans vérifier
  l'existence des modules — dispatch.ex:101-114). Passe au vert avec R5
  (Dispatch fail-loud-boot sur handler absent).

  Tag `:r1_seam` — `mix test --only r1_seam`.
  """
  use ExUnit.Case, async: false

  @moduletag :r1_seam

  alias Fleet.EventRouter.Bus
  alias Fleet.EventRouter.Dispatch

  @tag :tmp_dir
  test "T4 — Dispatch refuse de booter si events.yaml référence un handler inexistant",
       %{tmp_dir: tmp} do
    path = Path.join(tmp, "events.yaml")
    File.write!(path, "events:\n  pod.completed:\n    - Fleet.Phantom.DoesNotExist\n")

    Application.put_env(:fleet_event_router, :events_yaml_path, path)

    on_exit(fn ->
      Application.delete_env(:fleet_event_router, :events_yaml_path)
      # Reset le registry global (register_authorized_types a pu peupler le
      # persistent_term avec {pod.completed}) pour ne pas polluer les autres tests.
      Bus.set_authorized_event_types(MapSet.new())
    end)

    # RED : aujourd'hui le boot réussit ({:ok, pid}) — le handler fantôme n'est
    # détecté qu'au dispatch (warning silencieux). Après R5 : init doit
    # fail-loud (handler absent = état invalide non-représentable au boot).
    assert {:error, _reason} = start_supervised(Dispatch)
  end
end
