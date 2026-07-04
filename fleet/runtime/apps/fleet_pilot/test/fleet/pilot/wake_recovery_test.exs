defmodule Fleet.Pilot.WakeRecoveryTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Fleet.Pilot.WakeRecovery

  test "wake :ok → :ok, ni re-roll ni note ni escalade" do
    pid = self()

    opts = [
      wake_fun: fn p -> send(pid, {:wake, p}) && :ok end,
      seen_before_fun: fn _ -> flunk("seen_before interdit sur :ok") end,
      note_fun: fn _, _ -> flunk("note interdit sur :ok") end
    ]

    assert :ok = WakeRecovery.wake("pod-1", fn -> flunk("respawn interdit sur :ok") end, opts)
    assert_received {:wake, "pod-1"}
  end

  test "fail + jamais vu + re-roll RÉCUPÈRE → grave l'incident (bonne signature) + :ok" do
    pid = self()
    ctr = :counters.new(1, [])

    opts = [
      # 1er wake → {:error} ; re-wake (après re-roll) → :ok
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
    # signature : chiffres normalisés → N
    assert_received {:note, "wake:issue-N-engineer:dead", :dead}
  end

  test "fail + jamais vu + re-roll ÉCHOUE → escalade :reroll_failed + {:error,{:escalated,_}}" do
    pid = self()

    opts = [
      wake_fun: fn _ -> {:error, :dead} end,
      seen_before_fun: fn _ -> false end,
      note_fun: fn _, _ -> flunk("pas de note si le re-roll échoue") end,
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
    assert title =~ "re-roll échoué"

    # fix F-RUN-2 : create_issue SANS label (le POST Gitea exige des IDs int, pas des noms → 422) ;
    # le label error_system est posé APRÈS par NOM via add_label.
    refute Keyword.has_key?(iopts, :labels)
    assert iopts[:assignees] == ["starfleet"]
    assert_received {:label, "fleet/lcars", 1, "error_system"}
  end

  test "fail + DÉJÀ VU → escalade :recurrence DIRECTE (pas de re-roll)" do
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
             WakeRecovery.wake("pod-y", fn -> flunk("pas de re-roll si déjà vu") end, opts)

    assert_received {:issue, "fleet/lcars", title, _iopts}
    assert title =~ "récurrence"
  end

  test "fail + DÉJÀ VU + forge DOWN → {:error,{:escalation_failed,_}} (PAS escalated) + log LOUD" do
    opts = [
      wake_fun: fn _ -> {:error, :dead} end,
      seen_before_fun: fn _ -> true end,
      # échec aux DEUX tentatives (avec assignee + fallback label-only) = forge réellement down
      create_issue_fun: fn _r, _t, _b, _o -> {:error, :forge_down} end
    ]

    log =
      capture_log(fn ->
        # AUCUN issue ouvert → le retour DIT l'échec, pas un `:escalated` rassurant ; l'appelant ne croit
        # pas qu'un sysadmin a été prévenu alors que l'alarme n'est pas passée.
        assert {:error, {:escalation_failed, :forge_down}} =
                 WakeRecovery.wake("pod-down", fn -> flunk("pas de re-roll si déjà vu") end, opts)
      end)

    assert log =~ "escalade"
    assert log =~ "AUCUN issue sysadmin"
  end

  test "escalade : create_issue échoue avec assignee → fallback label-only" do
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

    # fix F-RUN-2 : le fallback (assignee absent) crée SANS assignee NI label ; le label error_system
    # est posé APRÈS par NOM via add_label — sur l'issue 7 réellement créée par le fallback.
    assert_received {:fallback, "fleet/lcars", fb_opts}
    refute Keyword.has_key?(fb_opts, :labels)
    refute fb_opts[:assignees]
    assert_received {:label, "fleet/lcars", 7, "error_system"}
  end
end
