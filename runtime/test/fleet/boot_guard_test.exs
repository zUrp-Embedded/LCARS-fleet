defmodule Fleet.BootGuardTest do
  @moduledoc """
  GUARD B, branch by branch, on injected machine facts.

  These cases came from `deploy/tests/runtime_guard.bats`, where each one launched a VM
  (`mix run --no-start`) to reach one `raise` in `config/runtime.exs`. The judgement now lives in
  `Fleet.BootGuard`, so the facts are handed to it directly: same branches, no launch. The bats
  file keeps ONE case, the wiring — that a real launch refuses — which no unit test can prove.

  What is measured here is a REFUSAL and its wording: the phrase an operator reads is the only
  thing that tells them which of the two facts stopped their boot.
  """
  use ExUnit.Case, async: true

  alias Fleet.BootGuard

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    seat = Path.join(tmp, "seat.uid")
    defs = Path.join(tmp, "login.defs")
    File.write!(defs, "UID_MIN\t1000\nUID_MAX\t60000\n")
    {:ok, seat: seat, defs: defs}
  end

  defp verify(ctx, opts) do
    BootGuard.verify(Keyword.merge([seat_uid_path: ctx.seat, uid_bounds_path: ctx.defs], opts))
  end

  describe "the seat" do
    test "the SEAT uid is refused, with the GUARD B phrase", ctx do
      File.write!(ctx.seat, "1000\n")

      assert {:error, message} = verify(ctx, uid_reading: "1000")
      assert message =~ "SYSADMIN seat"
      assert message =~ "GUARD B"
    end

    test "a worker uid passes — the guard aims at the seat, not at fleet humans", ctx do
      File.write!(ctx.seat, "99999\n")

      assert :ok = verify(ctx, uid_reading: "1001")
    end

    test "no seat file: the guard REFUSES instead of guessing", ctx do
      refute File.exists?(ctx.seat)

      assert {:error, message} = verify(ctx, uid_reading: "1001")
      assert message =~ "R-no-seat"
      # the remedy names the gesture that installs the machine, on both rails
      assert message =~ "deploy/workstation up"
      assert message =~ "deploy/container config"
    end

    test "a seat file that does not carry a uid REFUSES, it is not replaced", ctx do
      File.write!(ctx.seat, "pasunuid\n")

      assert {:error, message} = verify(ctx, uid_reading: "1001")
      assert message =~ "R-no-seat"
    end

    test "the FILE is the only reader — no env value redefines the seat", ctx do
      # The witness of the precedence: the same uid that the file calls the seat is refused, and a
      # guard that refused everything would pass this case without reading anything — hence the
      # second half, where the file INNOCENTS the same uid.
      File.write!(ctx.seat, "1000\n")
      assert {:error, message} = verify(ctx, uid_reading: "1000")
      assert message =~ "SYSADMIN seat"

      File.write!(ctx.seat, "99999\n")
      assert :ok = verify(ctx, uid_reading: "1000")
    end
  end

  describe "the system/human boundary" do
    test "a SYSTEM account (uid < UID_MIN) is refused — the mirror of GUARD B is WHOLE", ctx do
      File.write!(ctx.seat, "1000\n")

      assert {:error, message} = verify(ctx, uid_reading: "999")
      assert message =~ "SYSTEM account"
      assert message =~ "UID_MIN 1000"
    end

    test "root is refused by its own phrase, before any range", ctx do
      File.write!(ctx.seat, "1000\n")

      assert {:error, message} = verify(ctx, uid_reading: "0")
      assert message =~ "refuses to run as root"
    end

    test "an account ABOVE UID_MAX is refused — nobody is not a fleet human", ctx do
      File.write!(ctx.seat, "1000\n")

      assert {:error, message} = verify(ctx, uid_reading: "65534")
      assert message =~ "ABOVE the"
      assert message =~ "UID_MAX 60000"
    end

    test "the boundary is READ in login.defs — a moved floor moves the boundary", ctx do
      File.write!(ctx.seat, "1000\n")
      File.write!(ctx.defs, "UID_MIN\t2000\nUID_MAX\t60000\n")

      assert {:error, message} = verify(ctx, uid_reading: "1500")
      assert message =~ "SYSTEM account"
      assert message =~ "2000"
    end

    test "login.defs UNREADABLE REFUSES, it is not replaced by 1000", ctx do
      File.write!(ctx.seat, "99999\n")
      absent = Path.join(ctx.defs, "../aucun-login-defs") |> Path.expand()

      assert {:error, message} = verify(ctx, uid_reading: "1001", uid_bounds_path: absent)
      assert message =~ "UID_MIN"
      assert message =~ "aucun-login-defs"
    end

    test "UID_MAX missing REFUSES too — both bounds are facts, not one", ctx do
      File.write!(ctx.seat, "99999\n")
      File.write!(ctx.defs, "UID_MIN\t1000\n")

      assert {:error, message} = verify(ctx, uid_reading: "1001")
      assert message =~ "UID_MAX"
    end
  end

  describe "the uid reading" do
    test "an unreadable `id -u` REFUSES, and says why", ctx do
      File.write!(ctx.seat, "99999\n")

      assert {:error, message} =
               verify(ctx, uid_reading: {:unreadable, "`id -u` exited 127: not found"})

      assert message =~ "could not be established"
      assert message =~ "exited 127"
    end

    test "the machine facts are read FIRST: an unreadable seat names itself, not the uid", ctx do
      refute File.exists?(ctx.seat)

      assert {:error, message} = verify(ctx, uid_reading: {:unreadable, "boom"})
      assert message =~ "R-no-seat"
      refute message =~ "boom"
    end
  end
end
