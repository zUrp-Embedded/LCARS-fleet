defmodule Fleet.Starfleet.CoordBackendRaising do
  @moduledoc """
  `CoordBackend` stub qui EXPLOSE, et il n'existe que pour tenir un ORDRE.

  C'est le seul montage qui distingue « la trace est ecrite » de « la trace est ecrite AVANT le
  routage » : avec un backend qui rend `:ok`, l'ordre est inobservable et un test passe dans les
  deux sens. Mesure 2026-08-08 : intervertir audit et routage dans `Cat5Escalator` laissait la
  suite entiere verte.

  Partage entre `Cat5EscalatorTest` et `DriftMonitorTest` — les deux chemins qui traversent le seam
  `:coord_backend`, et les deux qui doivent graver avant de router.
  """
  @behaviour Fleet.Starfleet.CoordBackend

  # `no_return` est la PROPRIETE de ce module, pas un defaut : ses deux fonctions n'existent que
  # pour lever. Dialyzer ne le voyait pas tant que le stub vivait dans un `.exs` ; il est passe en
  # `test/support/` le jour ou un second corpus en a eu besoin, donc il est compile, donc il est
  # analyse. On le declare au lieu de tordre le stub pour faire taire l'outil.
  @dialyzer {:nowarn_function, handle_decision: 2, handle_escalation: 3}

  @impl true
  def handle_decision(_decision, _correlation_id), do: raise("coord backend down")

  @impl true
  def handle_escalation(_source, _payload, _correlation_id), do: raise("coord backend down")
end
