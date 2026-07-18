defmodule Fleet.Pilot.WakeRecoveryTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Fleet.Pilot.WakeRecovery

  test "wake :ok → :ok, no re-roll, no note, no escalation" do
    pid = self()

    opts = [
      wake_fun: fn p -> send(pid, {:wake, p}) && :ok end,
      seen_before_fun: fn _ -> flunk("seen_before forbidden on :ok") end,
      note_fun: fn _, _ -> flunk("note forbidden on :ok") end
    ]

    assert :ok = WakeRecovery.wake("pod-1", fn -> flunk("respawn forbidden on :ok") end, opts)
    assert_received {:wake, "pod-1"}
  end

  test "fail + never seen + re-roll RECOVERS → records the incident (right signature) + :ok" do
    pid = self()
    ctr = :counters.new(1, [])

    opts = [
      # 1st wake → {:error}; re-wake (after re-roll) → :ok
      wake_fun: fn p ->
        send(pid, {:wake, p})
        n = :counters.get(ctr, 1)
        :counters.add(ctr, 1, 1)
        if n == 0, do: {:error, :dead}, else: :ok
      end,
      seen_before_fun: fn _ -> false end,
      note_fun: fn sig, reason -> send(pid, {:note, sig, reason}) && :ok end
    ]

    assert :ok = WakeRecovery.wake("issue-7-engineer", fn -> send(pid, :respawn) end, opts)

    assert_received {:wake, "issue-7-engineer"}
    assert_received :respawn
    assert_received {:wake, "issue-7-engineer"}
    # signature: digits normalized → N
    assert_received {:note, "wake:issue-N-engineer:dead", :dead}
  end

  test "re-roll RECOVERS but note FAILS → :ok BUT LOUD log (incident anchor NOT recorded, no more \"recorded\" lie)" do
    pid = self()
    ctr = :counters.new(1, [])

    opts = [
      wake_fun: fn p ->
        send(pid, {:wake, p})
        n = :counters.get(ctr, 1)
        :counters.add(ctr, 1, 1)
        if n == 0, do: {:error, :dead}, else: :ok
      end,
      seen_before_fun: fn _ -> false end,
      # Registry unavailable: the note fails → the anchor is NOT set → the next recurrence will not
      # be seen as one (no escalation). The fix: LOUD log, no lying "recorded".
      note_fun: fn _, _ -> {:error, :registry_unavailable} end
    ]

    log =
      capture_log(fn ->
        assert :ok = WakeRecovery.wake("issue-7-engineer", fn -> send(pid, :respawn) end, opts)
      end)

    assert log =~ "NOT recorded"
    refute log =~ "→ incident recorded"
  end

  test "fail + never seen + re-roll FAILS → escalation :reroll_failed + {:error,{:escalated,_}}" do
    pid = self()

    opts = [
      wake_fun: fn _ -> {:error, :dead} end,
      seen_before_fun: fn _ -> false end,
      note_fun: fn _, _ -> flunk("no note when the re-roll fails") end,
      create_issue_fun: fn repo, title, _body, iopts ->
        send(pid, {:issue, repo, title, iopts}) && {:ok, 1}
      end,
      add_label_fun: fn repo, num, lbl, _o ->
        send(pid, {:label, repo, num, lbl}) && {:ok, :added}
      end
    ]

    assert {:error, {:escalated, :dead}} =
             WakeRecovery.wake("pod-x", fn -> send(pid, :respawn) end, opts)

    assert_received :respawn
    assert_received {:issue, "fleet/lcars", title, iopts}
    # "re-roll échoué" pins the FR user-facing sysadmin issue title (Escalation).
    assert title =~ "re-roll échoué"

    # fix F-RUN-2: create_issue WITHOUT label (the Gitea POST requires int IDs, not names → 422);
    # the error_system label is set AFTERWARDS by NAME via add_label.
    refute Keyword.has_key?(iopts, :labels)
    assert iopts[:assignees] == ["starfleet"]
    assert_received {:label, "fleet/lcars", 1, "error_system"}
  end

  test "fail + ALREADY SEEN → DIRECT :recurrence escalation (no re-roll)" do
    pid = self()

    opts = [
      wake_fun: fn _ -> {:error, :dead} end,
      seen_before_fun: fn _ -> true end,
      create_issue_fun: fn repo, title, _b, iopts ->
        send(pid, {:issue, repo, title, iopts}) && {:ok, 1}
      end,
      add_label_fun: fn _r, _n, _l, _o -> {:ok, :added} end
    ]

    assert {:error, {:escalated, :dead}} =
             WakeRecovery.wake("pod-y", fn -> flunk("no re-roll when already seen") end, opts)

    assert_received {:issue, "fleet/lcars", title, _iopts}
    # "récurrence" pins the FR user-facing sysadmin issue title (Escalation).
    assert title =~ "récurrence"
  end

  test "fail + ALREADY SEEN + forge DOWN → {:error,{:escalation_failed,_}} (NOT escalated) + LOUD log" do
    opts = [
      wake_fun: fn _ -> {:error, :dead} end,
      seen_before_fun: fn _ -> true end,
      # failure on BOTH attempts (with assignee + label-only fallback) = forge really down
      create_issue_fun: fn _r, _t, _b, _o -> {:error, :forge_down} end
    ]

    log =
      capture_log(fn ->
        # NO issue opened → the return SAYS the failure, not a reassuring `:escalated`; the caller
        # does not believe a sysadmin was notified when the alarm never went through.
        assert {:error, {:escalation_failed, :forge_down}} =
                 WakeRecovery.wake("pod-down", fn -> flunk("no re-roll when already seen") end, opts)
      end)

    assert log =~ "escalation"
    assert log =~ "NO sysadmin issue"
  end

  test "escalation: create_issue fails with assignee → label-only fallback" do
    pid = self()

    opts = [
      wake_fun: fn _ -> {:error, :dead} end,
      seen_before_fun: fn _ -> true end,
      create_issue_fun: fn repo, _t, _b, iopts ->
        if iopts[:assignees] do
          send(pid, :with_assignee) && {:error, :bad_assignee}
        else
          send(pid, {:fallback, repo, iopts}) && {:ok, 7}
        end
      end,
      add_label_fun: fn repo, num, lbl, _o ->
        send(pid, {:label, repo, num, lbl}) && {:ok, :added}
      end
    ]

    WakeRecovery.wake("pod-z", fn -> :ok end, opts)

    assert_received :with_assignee

    # fix F-RUN-2: the fallback (assignee absent) creates WITHOUT assignee NOR label; the
    # error_system label is set AFTERWARDS by NAME via add_label — on issue 7 actually created by
    # the fallback.
    assert_received {:fallback, "fleet/lcars", fb_opts}
    refute Keyword.has_key?(fb_opts, :labels)
    refute fb_opts[:assignees]
    assert_received {:label, "fleet/lcars", 7, "error_system"}
  end
end
