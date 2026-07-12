defmodule Fleet.EventRouter.SignalsOSTest do
  use ExUnit.Case, async: true

  alias Fleet.EventRouter.SignalsOS

  test "R0-EVT-011 : init/1 RAISE (fail-loud) — refuse de démarrer un SignalsOS non-implémenté" do
    # Enabling `:start_signals` doit échouer LOUDEMENT au boot plutôt que capturer SIGTERM/SIGHUP dans un
    # handler mort. Le raise arrive AVANT tout `:os.set_signal` (aucun signal capturé).
    assert_raise RuntimeError, ~r/not implemented/, fn ->
      SignalsOS.init([])
    end
  end
end
