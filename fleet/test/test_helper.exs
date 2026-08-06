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

# The in-tree `tmp/` @tmp_dir root is SHARED across runners of the
# `fleet` group (multi-human box). A test interrupted (kill -9) or run by another UID could leave a
# non-group-writable dir under the STABLE @tmp_dir path → the next runner's `create_tmp_dir!` fails
# to `rm_rf` it before the test body. Pre-run best-effort sweep: make every leftover under `tmp/`
# group-writable so ANY fleet-group runner can always erase it. Silent on failure (not-owner dirs
# we cannot chmod are exactly the ones a fresh checkout will not have; the sweep is a belt, not a
# gate). The fixtures that chmod a dir read-only restore it synchronously (see pod_test.exs).
_ =
  case File.stat("tmp") do
    {:ok, _} -> System.cmd("chmod", ["-R", "g+rwX", "tmp"], stderr_to_stdout: true)
    _ -> :ok
  end

# Machine prerequisites resolved at RUNTIME into STRUCTURAL exclusions: an integration test
# whose binary is missing must show up as excluded in the bilan, never print "SKIP" and count
# as a green success (a hollow-green is a verdict about a machine, silently reported as a
# verdict about the code).
curl_excludes = if System.find_executable("curl"), do: [], else: [:requires_curl]

if curl_excludes != [] do
  IO.puts(
    "test_helper: curl missing on this machine — :requires_curl tests are EXCLUDED (visible in the bilan)"
  )
end

ExUnit.start(exclude: curl_excludes)
