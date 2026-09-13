defmodule Fleet.Pilot.IncidentRegistry.EscalationTest do
  @moduledoc """
  Checks marker reuse, the awaits_arch_stuck kind and provisioned assignee lookup.
  Serialized because with_store/2 mutates the global LCARS_STORE_ROOT environment.
  Readback tests do not exercise concurrent creation or transport ambiguity.
  """
  use ExUnit.Case, async: false

  describe "Escalation idempotency (create is not idempotent, readback is)" do
    alias Fleet.Pilot.IncidentRegistry.Escalation

    test "an OPEN issue already carrying this occurrence's marker → reused, NO duplicate create" do
      me = self()
      sig = "wake:issue-7-engineer:dead"

      # The forge already holds the issue (a create that timed-out-after-commit, or a concurrent
      # escalation): the marker in its body is the idempotency key. create_issue must NOT be called.
      marker = "<!-- lcars-incident:#{sig} -->"

      result =
        Escalation.escalate(:reroll_failed, "issue-7-engineer", :dead, sig,
          list_issues_fun: fn _repo, _opts ->
            {:ok, [%{"number" => 42, "body" => "prior incident\n#{marker}\n"}]}
          end,
          create_issue_fun: fn _r, _t, _b, _o ->
            send(me, :created)
            {:ok, 999}
          end,
          add_label_fun: fn _r, num, _lbl, _o ->
            send(me, {:label, num})
            {:ok, :added}
          end
        )

      assert {:ok, 42} = result
      refute_received :created
      assert_received {:label, 42}
    end

    test "no open issue carries the marker → create as before" do
      me = self()
      sig = "wake:issue-9-engineer:dead"

      result =
        Escalation.escalate(:reroll_failed, "issue-9-engineer", :dead, sig,
          list_issues_fun: fn _repo, _opts -> {:ok, [%{"number" => 1, "body" => "unrelated"}]} end,
          create_issue_fun: fn _r, _t, _b, _o ->
            send(me, :created)
            {:ok, 7}
          end,
          add_label_fun: fn _r, _num, _lbl, _o -> {:ok, :added} end
        )

      assert {:ok, 7} = result
      assert_received :created
    end

    test "an UNREADABLE listing does NOT suppress the alarm → create (fail-closed toward escalating)" do
      me = self()

      result =
        Escalation.escalate(
          :reroll_failed,
          "issue-3-engineer",
          :dead,
          "wake:issue-3-engineer:dead",
          list_issues_fun: fn _repo, _opts -> {:error, :forge_down} end,
          create_issue_fun: fn _r, _t, _b, _o ->
            send(me, :created)
            {:ok, 5}
          end,
          add_label_fun: fn _r, _num, _lbl, _o -> {:ok, :added} end
        )

      assert {:ok, 5} = result
      assert_received :created
    end
  end

  describe "every kind that fires has a describe clause" do
    alias Fleet.Pilot.IncidentRegistry.Escalation

    # Drain tests stub escalate_fun; call real escalation here to catch a missing
    # kind_describe clause.
    test ":awaits_arch_stuck opens an issue instead of crashing on kind_describe" do
      pid = self()

      opts = [
        list_issues_fun: fn _r, _o -> {:ok, []} end,
        create_issue_fun: fn _r, title, _body, _o ->
          send(pid, {:title, title})
          {:ok, 91}
        end,
        add_label_fun: fn _r, _n, _l, _o -> {:ok, :added} end
      ]

      assert {:ok, 91} =
               Escalation.escalate(
                 :awaits_arch_stuck,
                 "o/r#7",
                 {:remove_label_failed, :forge_write_down},
                 "awaits_arch_stuck:o/r#7",
                 opts
               )

      assert_received {:title, title}
      assert title =~ "awaits-arch"
    end
  end

  describe "l'assignee est une PROJECTION — jamais un nom en dur" do
    alias Fleet.Pilot.IncidentRegistry.Escalation

    defp escalate_opts(pid) do
      [
        list_issues_fun: fn _r, _o -> {:ok, []} end,
        create_issue_fun: fn _r, _t, _b, iopts ->
          send(pid, {:create, iopts})
          {:ok, 5}
        end,
        add_label_fun: fn _r, _n, _l, _o -> {:ok, :added} end
      ]
    end

    defp with_store(root, fun) do
      prev = System.get_env("LCARS_STORE_ROOT")
      System.put_env("LCARS_STORE_ROOT", root)

      try do
        fun.()
      after
        if prev,
          do: System.put_env("LCARS_STORE_ROOT", prev),
          else: System.delete_env("LCARS_STORE_ROOT")
      end
    end

    test "fichier projete present => son login part en assignee" do
      root = Fleet.TestEnv.tmp_path("lcars-assg")
      File.mkdir_p!(Path.join(root, "state"))
      File.write!(Path.join([root, "state", "pilot.assignee"]), "le-login-reel\n")
      on_exit(fn -> File.rm_rf!(root) end)

      with_store(root, fn ->
        assert {:ok, 5} =
                 Escalation.escalate(:recurrence, "s", :r, "sig-a", escalate_opts(self()))
      end)

      assert_received {:create, iopts}
      assert iopts[:assignees] == ["le-login-reel"]
    end

    test "fichier VIDE = ABSENT : UN SEUL appel, l'option OMISE, et un warning" do
      # Sans la clause vide->nil, `assignees: [""]` partirait, la forge refuserait, et le retry
      # sans option rattraperait — temoin naif vert, un appel API brule par escalade.
      root = Fleet.TestEnv.tmp_path("lcars-assg")
      File.mkdir_p!(Path.join(root, "state"))
      File.write!(Path.join([root, "state", "pilot.assignee"]), "  \n")
      on_exit(fn -> File.rm_rf!(root) end)
      pid = self()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          with_store(root, fn ->
            assert {:ok, 5} =
                     Escalation.escalate(:recurrence, "s", :r, "sig-b", escalate_opts(pid))
          end)
        end)

      assert_received {:create, iopts}
      refute Keyword.has_key?(iopts, :assignees)
      refute_received {:create, _}
      assert log =~ "projection du siege"
    end

    test "store present + fichier absent => nil + warning (panne dite, pas silence)" do
      root = Fleet.TestEnv.tmp_path("lcars-assg")
      File.mkdir_p!(Path.join(root, "state"))
      on_exit(fn -> File.rm_rf!(root) end)
      pid = self()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          with_store(root, fn ->
            assert {:ok, 5} =
                     Escalation.escalate(:recurrence, "s", :r, "sig-c", escalate_opts(pid))
          end)
        end)

      assert_received {:create, iopts}
      refute Keyword.has_key?(iopts, :assignees)
      assert log =~ "projection du siege"
    end

    test "aucun login en dur ne survit dans ce module" do
      # Check the assignment syntax rather than a blacklist of known account names.
      # This source regex is a guard against literals, not a full data-flow proof.
      src = File.read!("lib/fleet/pilot/incident_registry/escalation.ex")

      suspects =
        for {l, i} <- Enum.with_index(String.split(src, "\n"), 1),
            not String.starts_with?(String.trim(l), "#"),
            Regex.match?(
              ~r/(assignees?|login|owner|account)\s*[:=>]+\s*(\[\s*)?"[a-z][a-z0-9_-]{2,}"/,
              l
            ),
            do: "#{i}: #{String.trim(l)}"

      assert suspects == [],
             "un login en dur est revenu dans ce module — le siege se PROJETTE, il ne se devine " <>
               "pas :\n" <> Enum.join(suspects, "\n")
    end
  end
end
