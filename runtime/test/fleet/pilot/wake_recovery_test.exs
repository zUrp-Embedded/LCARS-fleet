defmodule Fleet.Pilot.WakeRecoveryTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Fleet.Pilot.WakeRecovery

  test "fail :unreachable (slow, not proven absent) → DEFER: no re-roll, no registry, no escalation" do
    # An initial info timeout must bypass both respawn and recurrence lookup.
    log =
      capture_log(fn ->
        assert {:error, :unreachable} =
                 WakeRecovery.wake(
                   "pod-slow",
                   fn -> send(self(), :respawned) end,
                   wake_fun: fn _ -> {:error, :unreachable} end,
                   seen_before_fun: fn _ ->
                     flunk("the incident registry must not be consulted")
                   end
                 )
      end)

    refute_received :respawned
    assert log =~ "UNREACHABLE"
  end

  test "wake :ok → :ok, no re-roll, no note, no escalation" do
    pid = self()

    opts = [
      wake_fun: fn p ->
        send(pid, {:wake, p})
        :ok
      end,
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
      note_fun: fn sig, reason ->
        send(pid, {:note, sig, reason})
        :ok
      end
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
      # An unavailable registry cannot record the recovery anchor.
      note_fun: fn _, _ -> {:error, :registry_unavailable} end
    ]

    log =
      capture_log(fn ->
        assert :ok = WakeRecovery.wake("issue-7-engineer", fn -> send(pid, :respawn) end, opts)
      end)

    assert log =~ "NOT recorded"

    # capture_log can include concurrent writers. Match this pod's actual emitted
    # success message: a global fragment can collide, an impossible fragment proves nothing.
    refute log =~ "issue-7-engineer : re-roll OK → incident recorded"
  end

  test "fail + never seen + re-roll FAILS → escalation :reroll_failed + {:error,{:escalated,_}}" do
    pid = self()

    opts = [
      wake_fun: fn _ -> {:error, :dead} end,
      seen_before_fun: fn _ -> false end,
      note_fun: fn _, _ -> flunk("no note when the re-roll fails") end,
      create_issue_fun: fn repo, title, _body, iopts ->
        send(pid, {:issue, repo, title, iopts})
        {:ok, 1}
      end,
      add_label_fun: fn repo, num, lbl, _o ->
        send(pid, {:label, repo, num, lbl})
        {:ok, :added}
      end
    ]

    assert {:error, {:escalated, :dead}} =
             WakeRecovery.wake("pod-x", fn -> send(pid, :respawn) end, opts)

    assert_received :respawn
    assert_received {:issue, "lcars/_ops", title, iopts}
    # "re-roll échoué" pins the FR user-facing sysadmin issue title (Escalation).
    assert title =~ "re-roll échoué"

    # Creation takes integer label IDs; add_label resolves names separately.
    # With no seat projection, assignment is omitted in this fixture.
    refute Keyword.has_key?(iopts, :labels)
    refute Keyword.has_key?(iopts, :assignees)
    assert_received {:label, "lcars/_ops", 1, "error_system"}
  end

  test "fail + ALREADY SEEN → DIRECT :recurrence escalation (no re-roll)" do
    pid = self()

    opts = [
      wake_fun: fn _ -> {:error, :dead} end,
      seen_before_fun: fn _ -> true end,
      create_issue_fun: fn repo, title, _b, iopts ->
        send(pid, {:issue, repo, title, iopts})
        {:ok, 1}
      end,
      add_label_fun: fn _r, _n, _l, _o -> {:ok, :added} end
    ]

    assert {:error, {:escalated, :dead}} =
             WakeRecovery.wake("pod-y", fn -> flunk("no re-roll when already seen") end, opts)

    assert_received {:issue, "lcars/_ops", title, _iopts}
    # "récurrence" pins the FR user-facing sysadmin issue title (Escalation).
    assert title =~ "récurrence"
  end

  test "fail + ALREADY SEEN + forge DOWN → {:error,{:escalation_failed,_}} (NOT escalated) + LOUD log" do
    opts = [
      wake_fun: fn _ -> {:error, :dead} end,
      seen_before_fun: fn _ -> true end,
      # The create stub always fails; this case does not assert retry count.
      create_issue_fun: fn _r, _t, _b, _o -> {:error, :forge_down} end
    ]

    log =
      capture_log(fn ->
        # This stub reports failure; successful escalation must not be returned.
        assert {:error, {:escalation_failed, :forge_down}} =
                 WakeRecovery.wake(
                   "pod-down",
                   fn -> flunk("no re-roll when already seen") end,
                   opts
                 )
      end)

    assert log =~ "escalation"
    assert log =~ "NO sysadmin issue"
  end

  test "escalation: create_issue fails with assignee → label-only fallback" do
    pid = self()

    opts = [
      # Supply an assignee explicitly so this case exercises the retry branch.
      assignee: "un-admin",
      wake_fun: fn _ -> {:error, :dead} end,
      seen_before_fun: fn _ -> true end,
      create_issue_fun: fn repo, _t, _b, iopts ->
        if iopts[:assignees] do
          send(pid, :with_assignee)
          {:error, :bad_assignee}
        else
          send(pid, {:fallback, repo, iopts})
          {:ok, 7}
        end
      end,
      add_label_fun: fn repo, num, lbl, _o ->
        send(pid, {:label, repo, num, lbl})
        {:ok, :added}
      end
    ]

    WakeRecovery.wake("pod-z", fn -> :ok end, opts)

    assert_received :with_assignee

    # The fallback omits assignment and creation labels; label the returned issue.
    assert_received {:fallback, "lcars/_ops", fb_opts}
    refute Keyword.has_key?(fb_opts, :labels)
    refute fb_opts[:assignees]
    assert_received {:label, "lcars/_ops", 7, "error_system"}
  end
end
