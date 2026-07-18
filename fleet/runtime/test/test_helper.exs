# Single post-collapse helper (merge of the 14 umbrella helpers — migration Z1).
# - `put_env :start_listener`: belt-and-suspenders inherited from the fleet_api helper.
#   config/test.exs already sets it; kept because a test that manipulates the global config must not
#   make the listener bindable by accident (same hermetic invariant, two locks).
# - NO global `exclude: [:r1_seam]`: the exclusion was LOCAL to fleet_api (its red-by-design WS R1
#   test now carries its own `@moduletag skip:`) — event_router's :r1_seam tests run and must keep
#   running.
# - `ensure_all_started(:fleet_workflow)` (ex-workflow helper): covered by the single-app boot in
#   test env — nothing left to start by hand.
Application.put_env(:fleet_api, :start_listener, false)
ExUnit.start()
