Application.put_env(:fleet_api, :start_listener, false)
# Tests R1 (couture) tagués :r1_seam — exclus par défaut, lancés via
# `mix test --only r1_seam`. Exclusion retirée au verrou R7.
ExUnit.start(exclude: [:r1_seam])
