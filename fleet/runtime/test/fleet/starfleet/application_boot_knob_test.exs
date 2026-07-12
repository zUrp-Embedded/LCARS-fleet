defmodule Fleet.Starfleet.ApplicationBootKnobTest do
  @moduledoc """
  F-C097 — les knobs de boot `:start_*` de `Fleet.Starfleet.Application` gouvernent l'arbre de supervision.
  Lus en `if Application.get_env(...)` (truthiness), une valeur malformée changeait la topologie EN SILENCE :
  une string `"false"` ou `0` est TRUTHY → l'enfant démarrait quand même ; un `nil` égaré est falsy → l'enfant
  était sauté même si son défaut est `true`. Le verrou `boot_enabled?/2` PARSE au bord : booléen honoré,
  absence → défaut, non-booléen → raise au boot (fail-closed). async: false (config globale).
  """
  use ExUnit.Case, async: false

  alias Fleet.Starfleet.Application, as: App
  alias Fleet.Starfleet.TestEnv

  test "valeur booléenne explicite respectée" do
    TestEnv.put_env_restoring(:fleet_starfleet, :start_mcp_monitor, false)
    refute App.boot_enabled?(:start_mcp_monitor, true)

    TestEnv.put_env_restoring(:fleet_starfleet, :start_mcp_watcher, true)
    assert App.boot_enabled?(:start_mcp_watcher, false)
  end

  test "clé absente → défaut booléen (pas d'interprétation)" do
    assert App.boot_enabled?(:start_never_set_knob, true)
    refute App.boot_enabled?(:start_never_set_knob, false)
  end

  test "valeur NON-booléenne → raise au boot (fail-closed, pas de dérive de topologie silencieuse)" do
    for bad <- ["false", "true", 0, 1, :off, nil] do
      TestEnv.put_env_restoring(:fleet_starfleet, :start_mcp_monitor, bad)

      assert_raise ArgumentError, ~r/must be a boolean/, fn ->
        App.boot_enabled?(:start_mcp_monitor, true)
      end
    end
  end
end
