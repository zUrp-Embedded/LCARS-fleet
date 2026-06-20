defmodule Fleet.Pilot.WakeRecoveryTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.WakeRecovery

  test "wake :ok → clear le compteur, renvoie :ok, ni note ni respawn" do
    pid = self()

    opts = [
      wake_fun: fn p -> send(pid, {:wake, p}) && :ok end,
      clear_fail_fun: fn p -> send(pid, {:clear, p}) && :ok end,
      note_fail_fun: fn _ -> flunk("note interdit sur :ok") end
    ]

    assert :ok = WakeRecovery.wake("pod-1", fn -> flunk("respawn interdit sur :ok") end, opts)
    assert_received {:wake, "pod-1"}
    assert_received {:clear, "pod-1"}
  end

  test "1er fail (n=1 ≤ reroll_max) → re-roll : respawn PUIS re-wake" do
    pid = self()

    opts = [
      wake_fun: fn p -> send(pid, {:wake, p}) && {:error, :boom} end,
      note_fail_fun: fn _ -> 1 end,
      reroll_max: 1
    ]

    WakeRecovery.wake("pod-2", fn -> send(pid, :respawn) end, opts)

    assert_received {:wake, "pod-2"}
    assert_received :respawn
    assert_received {:wake, "pod-2"}
  end

  test "2e fail (n=2 > reroll_max) → escalade ticket système + {:error,{:escalated,_}}, pas de respawn" do
    pid = self()

    opts = [
      wake_fun: fn _ -> {:error, :dead} end,
      note_fail_fun: fn _ -> 2 end,
      reroll_max: 1,
      create_issue_fun: fn repo, title, _body, iopts ->
        send(pid, {:issue, repo, title, iopts})
        {:ok, 42}
      end
    ]

    assert {:error, {:escalated, :dead}} =
             WakeRecovery.wake("pod-3", fn -> flunk("pas de respawn au 2e fail") end, opts)

    assert_received {:issue, "fleet/lcars", title, iopts}
    assert title =~ "error_system"
    assert title =~ "pod-3"
    assert iopts[:labels] == ["error_system"]
    assert iopts[:assignees] == ["starfleet"]
  end

  test "escalade : create_issue échoue avec assignee → fallback label-only" do
    pid = self()

    opts = [
      wake_fun: fn _ -> {:error, :dead} end,
      note_fail_fun: fn _ -> 2 end,
      reroll_max: 1,
      create_issue_fun: fn repo, _t, _b, iopts ->
        if iopts[:assignees] do
          send(pid, :with_assignee)
          {:error, :bad_assignee}
        else
          send(pid, {:fallback, repo, iopts})
          {:ok, 7}
        end
      end
    ]

    WakeRecovery.wake("pod-4", fn -> :ok end, opts)

    assert_received :with_assignee
    assert_received {:fallback, "fleet/lcars", fb_opts}
    assert fb_opts[:labels] == ["error_system"]
    refute fb_opts[:assignees]
  end
end
