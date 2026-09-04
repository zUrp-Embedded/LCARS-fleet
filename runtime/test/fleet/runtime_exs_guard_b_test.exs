defmodule Fleet.RuntimeExsGuardBTest do
  # async: false — the guard reads the OS environment (PASSWD_DEFS, LCARS_SEAT_UID_FILE, PATH),
  # and `System.put_env` is VM-wide: an async neighbour would read this decor as its own.
  use ExUnit.Case, async: false

  @moduledoc """
  GUARD B, BEAM side (`config/runtime.exs`, R-no-uid-min / R-no-root-runtime) — the system/human
  boundary has TWO bounds, read in `login.defs`, and no fallback on either.

  `runtime.exs` is wrapped in `config_env() != :test`, so under `mix test` the guard never runs and
  NO ExUnit witness held it (lot 15, 2026-09-05): the launcher's witness (`test/bin/fleet.bats`)
  was the only one, on a DIFFERENT copy of the rule — which is how the BEAM came to read UID_MIN
  alone while the protocol, the console and the launcher read both bounds. These tests evaluate the
  REAL file, as `:prod`, through `Config.Reader.read!/2`: the guard is the first thing the file can
  refuse on, so a controlled environment reaches it and stops there.

  The runtime uid is whatever `id -u` answers: a stub on PATH makes it `nobody` (65534) or a fleet
  human (1001) regardless of who runs the suite — a witness that reads the runner's real uid is a
  witness about the machine. The seat is a file the decor writes (99999, an uid nobody carries).
  """

  @runtime_exs Path.expand("../../config/runtime.exs", __DIR__)
  @env ~w(PASSWD_DEFS LCARS_SEAT_UID_FILE PATH LCARS_TOOL_EVAL)

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    saved = Map.new(@env, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)

    # Tool mode skips the whole deployment body, guard included: a boot, never an eval.
    System.delete_env("LCARS_TOOL_EVAL")
    seat = Path.join(tmp, "seat.uid")
    File.write!(seat, "99999\n")
    System.put_env("LCARS_SEAT_UID_FILE", seat)
    defs = Path.join(tmp, "login.defs")
    File.write!(defs, "UID_MIN\t1000\nUID_MAX\t60000\n")
    System.put_env("PASSWD_DEFS", defs)
    {:ok, defs: defs}
  end

  # The uid the BEAM believes it runs under: `System.cmd("id", ["-u"])` resolves `id` on PATH.
  defp run_as(tmp, uid) do
    bin = Path.join(tmp, "bin")
    File.mkdir_p!(bin)
    id = Path.join(bin, "id")
    File.write!(id, "#!/bin/sh\necho #{uid}\n")
    File.chmod!(id, 0o755)
    System.put_env("PATH", bin <> ":" <> (System.get_env("PATH") || "/usr/bin:/bin"))
  end

  defp boot, do: Config.Reader.read!(@runtime_exs, env: :prod)

  test "nobody (65534) is ABOVE UID_MAX: the boot is refused, and the refusal names the bound",
       %{tmp_dir: tmp} do
    run_as(tmp, 65_534)
    err = assert_raise RuntimeError, fn -> boot() end
    assert err.message =~ "R-no-root-runtime"
    assert err.message =~ "uid 65534 > UID_MAX 60000"
  end

  test "UID_MAX absent from login.defs: the boundary is NOT established — refused under the same word as UID_MIN, remedy = the file",
       %{tmp_dir: tmp, defs: defs} do
    # One readable bound is not a boundary: with UID_MIN alone, `nobody` would boot a fleet. No
    # 60000 is guessed — the message names the missing bound and the file to fix.
    run_as(tmp, 1001)
    File.write!(defs, "UID_MIN\t1000\n")
    err = assert_raise RuntimeError, fn -> boot() end
    assert err.message =~ "R-no-uid-min"
    assert err.message =~ "UID_MAX unreadable in #{defs}"
    assert err.message =~ "fix #{defs}"
    refute err.message =~ "60000"
  end

  test "control: a fleet human (1001) inside both bounds passes GUARD B — whatever the file refuses next is not this guard",
       %{tmp_dir: tmp} do
    # Without this, the two refusals above could be measuring a guard that refuses everyone.
    run_as(tmp, 1001)

    try do
      boot()
    rescue
      e -> refute Exception.message(e) =~ "GUARD B"
    end
  end
end
