defmodule Fleet.Pilot.ForgeFinchTest do
  @moduledoc """
  Pool HTTP dédié `Fleet.Pilot.ForgeFinch` — câblage anti-stale du ForgeClient.

  On SONDE le process réel (anti-vert-creux), pas un knob de config : si le pool est retiré de
  l'arbre `Fleet.Pilot.Application`, ce test casse. Le COMPORTEMENT (`conn_max_idle_time` ferme une
  connexion idle >30s avant que la forge ne la ferme côté serveur → plus de 1er-appel-pendu) est
  temporel/réseau et non isolable en unit ; sa preuve vit dans l'instrumentation du ForgeClient au
  run réel (log « LENT … »).
  """
  use ExUnit.Case, async: true

  test "le pool forge dédié tourne dans l'arbre (démarré inconditionnellement par l'Application)" do
    assert is_pid(Process.whereis(Fleet.Pilot.ForgeFinch))
  end
end
