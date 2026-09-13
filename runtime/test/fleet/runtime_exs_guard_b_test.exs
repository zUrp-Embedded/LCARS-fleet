defmodule Fleet.RuntimeExsGuardBTest do
  # Environment changes are VM-wide; keep these fixtures synchronous.
  use ExUnit.Case, async: false

  @moduledoc """
  Evaluates the real runtime.exs as prod with stubbed id output and temporary seat/login.defs
  files. Exercises the upper UID bound, its missing declaration, and an in-range control.
  The normal test boot skips this deployment branch. The control accepts later exceptions
  without GUARD B in their message; it does not prove a complete successful boot.
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

    # Disable tool mode so the deployment guard runs.
    System.delete_env("LCARS_TOOL_EVAL")
    seat = Path.join(tmp, "seat.uid")
    File.write!(seat, "99999\n")
    System.put_env("LCARS_SEAT_UID_FILE", seat)
    defs = Path.join(tmp, "login.defs")
    File.write!(defs, "UID_MIN\t1000\nUID_MAX\t60000\n")
    System.put_env("PASSWD_DEFS", defs)
    {:ok, defs: defs}
  end

  # System.cmd resolves id through the fixture PATH.
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
    run_as(tmp, 1001)

    try do
      boot()
    rescue
      e -> refute Exception.message(e) =~ "GUARD B"
    end
  end
end
