defmodule Fleet.Pilot.IncidentRegistryTest do
  # Serialized to reduce scheduler contention around real timers and bounded receives.
  # Environment-mutating projection tests live in EscalationTest.
  use ExUnit.Case, async: false
  import Fleet.Test.Barrier, only: [settle: 1]

  alias Fleet.Pilot.IncidentRegistry, as: Reg

  describe "signature/3" do
    test "normalizes the subject's digits + categorizes the reason (atom + tuple)" do
      assert Reg.signature("wake", "issue-42-engineer", :not_found) ==
               "wake:issue-N-engineer:not_found"

      assert Reg.signature("wake", "gatekeeper", {:send_keys_failed, :detail}) ==
               "wake:gatekeeper:send_keys_failed"
    end
  end

  describe "resilient owner (GenServer)" do
    @describetag :tmp_dir

    defp start_reg(tmp, extra) do
      name = :"reg_#{System.unique_integer([:positive])}"

      # `merge`, not `++`: a keyword read takes the FIRST occurrence, so an appended override of
      # the clocks would be silently ignored.
      opts =
        Keyword.merge(
          [
            name: name,
            wal_path: Path.join(tmp, "incidents.json"),
            sync_debounce_ms: 5,
            retry_ms: 50
          ],
          extra
        )

      start_supervised!({Reg, opts})
      name
    end

    # Observation and cooldown stamping are separate calls: a pre-stamp sync can
    # arrive first. Wait for a stamped snapshot rather than asserting on the first PUT.
    defp receive_stamped_put(puts_left \\ 5)
    defp receive_stamped_put(0), do: flunk("no forge sync carried the escalation stamp")

    defp receive_stamped_put(puts_left) do
      assert_receive {:put, content}, 1_000
      if content =~ "last_escalated_at", do: content, else: receive_stamped_put(puts_left - 1)
    end

    test "note → :ok, seen_before? = memory lookup, local WAL written, async forge sync", %{
      tmp_dir: tmp
    } do
      pid = self()

      name =
        start_reg(tmp,
          get_file_fun: fn _r, _p, _o -> {:error, :not_found} end,
          put_file_fun: fn _r, _p, content, _o ->
            send(pid, {:put, content})
            {:ok, "c"}
          end
        )

      refute Reg.seen_before?("wake:p:dead", server: name)
      assert :ok = Reg.note("wake:p:dead", :dead, server: name, now: "2026-06-20T10:00:00Z")
      assert Reg.seen_before?("wake:p:dead", server: name)

      # The note has written the WAL before replying; this is not a power-loss test.
      assert {:ok, content} = File.read(Path.join(tmp, "incidents.json"))

      assert {:ok, %{"wake:p:dead" => %{"count" => 1, "last_reason" => ":dead"}}} =
               JSON.decode(content)

      # forge sync triggered async (5ms debounce)
      assert_receive {:put, _}, 1000
    end

    # Coalesce notes into one PUT carrying the latest count; intermediate commits
    # are unnecessary. The bounded refute also detects immediate rescheduling.
    test "sync window: three notes inside one window → ONE put, carrying count 3", %{
      tmp_dir: tmp
    } do
      pid = self()

      name =
        start_reg(tmp,
          sync_debounce_ms: 150,
          get_file_fun: fn _r, _p, _o -> {:error, :not_found} end,
          put_file_fun: fn _r, _p, content, _o ->
            send(pid, {:put, content})
            {:ok, "c"}
          end
        )

      for i <- 1..3 do
        assert :ok = Reg.note("wake:p:dead", :dead, server: name, now: "2026-06-20T10:0#{i}:00Z")
      end

      assert_receive {:put, content}, 1_000
      assert {:ok, %{"wake:p:dead" => %{"count" => 3}}} = JSON.decode(content)
      refute_receive {:put, _}, 200
    end

    # The window is a budget for a memory the WAL holds. A note whose WAL write FAILED has the
    # forge as its only durability: it must sync on the catch-up clock, not wait the window.
    test "WAL write FAILS → the forge sync runs on the catch-up clock, not on the window", %{
      tmp_dir: tmp
    } do
      pid = self()
      blocker = Path.join(tmp, "blocker")
      File.write!(blocker, "i am a file, not a dir")
      name = :"reg_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Reg,
         [
           name: name,
           wal_path: Path.join([blocker, "nested", "incidents.json"]),
           sync_debounce_ms: 60_000,
           retry_ms: 50,
           get_file_fun: fn _r, _p, _o -> {:error, :not_found} end,
           put_file_fun: fn _r, _p, content, _o ->
             send(pid, {:put, content})
             {:ok, "c"}
           end
         ]}
      )

      assert {:error, {:wal_write_failed, _}} =
               Reg.note("wake:p:dead", :dead, server: name, now: "2026-06-20T10:00:00Z")

      assert_receive {:put, content}, 1_000
      assert content =~ "wake:p:dead"
    end

    # Registry synchronization is a system action. Verify its identity as well as content.
    test "sync: the put is signed by the SYSTEM, never by a pod role", %{tmp_dir: tmp} do
      pid = self()

      name =
        start_reg(tmp,
          get_file_fun: fn _r, _p, _o -> {:error, :not_found} end,
          put_file_fun: fn _r, _p, _c, o ->
            send(pid, {:put_opts, o})
            {:ok, "c"}
          end
        )

      assert :ok = Reg.note("wake:p:dead", :dead, server: name, now: "2026-06-20T10:00:00Z")
      assert_receive {:put_opts, opts}, 1000

      system = Fleet.Credentials.ForgeIdentity.system_identity()
      assert Keyword.fetch!(opts, :author) == system
      assert Keyword.fetch!(opts, :committer) == system

      # Adverse: no catalogue role may appear in this identity, whatever the catalogue names them.
      {:ok, roles} = Fleet.CapProfile.list()

      for role <- roles do
        refute system.email == Fleet.Credentials.ForgeIdentity.role_email(role),
               "the system commit is signed under the role #{role}"
      end
    end

    test "sync: forge getter UNREADABLE (not a 404) → NO put (never overwrite an unread forge)",
         %{
           tmp_dir: tmp
         } do
      pid = self()

      name =
        start_reg(tmp,
          get_file_fun: fn _r, _p, _o -> {:error, {:http, 503, "down"}} end,
          put_file_fun: fn _r, _p, content, _o ->
            send(pid, {:put, content})
            {:ok, "c"}
          end
        )

      assert :ok = Reg.note("wake:p:dead", :dead, server: name, now: "2026-06-20T10:00:00Z")

      # A failed read must not overwrite remote incidents with the local view.
      refute_receive {:put, _}, 250
      # local memory intact (the note is remembered)
      assert Reg.seen_before?("wake:p:dead", server: name)
    end

    # WAL under a parent that is a FILE → File.write of the .tmp fails :enotdir. The WAL is the ONLY
    # durability of a 1st occurrence (no escalation) → the failure is SURFACED, never swallowed (BND-055).
    defp start_reg_wal_broken(tmp) do
      blocker = Path.join(tmp, "blocker")
      File.write!(blocker, "i am a file, not a dir")
      wal = Path.join([blocker, "nested", "incidents.json"])
      name = :"reg_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Reg,
         [
           name: name,
           wal_path: wal,
           sync_debounce_ms: 5,
           retry_ms: 50,
           get_file_fun: fn _r, _p, _o -> {:error, :not_found} end,
           put_file_fun: fn _r, _p, _c, _o -> {:ok, "c"} end
         ]}
      )

      name
    end

    test "note: WAL write FAILS → {:error, {:wal_write_failed, _}} (BND-055, never a lying :ok)",
         %{tmp_dir: tmp} do
      name = start_reg_wal_broken(tmp)

      assert {:error, {:wal_write_failed, _}} =
               Reg.note("wake:p:dead", :dead, server: name, now: "2026-06-20T10:00:00Z")

      # memory still updated (volatile) — the recurrence stays detected IN MEMORY this session.
      assert Reg.seen_before?("wake:p:dead", server: name)
    end

    # Corrupt backing must block writes; unreadable dedup must warn in the issue body.
    # Lost cooldown persistence is separate from a successful escalation result.
    test "JG-113: relecture de dedup ILLISIBLE → l'issue le DIT dans son corps", %{tmp_dir: tmp} do
      pid = self()

      name =
        start_reg(tmp,
          get_file_fun: fn _r, _p, _o -> {:error, :not_found} end,
          put_file_fun: fn _r, _p, _c, _o -> {:ok, "c"} end
        )

      opts = [
        server: name,
        # Le tableau est ILLISIBLE — pas vide.
        list_issues_fun: fn _r, _o -> {:error, {:http, 503, "down"}} end,
        create_issue_fun: fn _r, _t, body, _o ->
          send(pid, {:body, body})
          {:ok, 77}
        end,
        add_label_fun: fn _r, _n, _l, _o -> {:ok, :added} end
      ]

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :recorded = Reg.record_or_escalate("pod", "jg113", :launch_failed, opts)
          assert {:escalated, 77} = Reg.record_or_escalate("pod", "jg113", :launch_failed, opts)
        end)

      assert_received {:body, body}

      assert body =~ "Déduplication NON vérifiée",
             "l'issue ne dit pas que son unicite n'a pas pu etre verifiee — un humain devant un " <>
               "doublon n'a aucun moyen de savoir pourquoi"

      assert body =~ "503", "le corps ne porte pas la raison de l'echec de relecture"
      assert log =~ "dedup readback FAILED"
    end

    test "TEMOIN JG-113 — une relecture REUSSIE et vide n'ajoute aucun avertissement", %{
      tmp_dir: tmp
    } do
      # Sans ce temoin, coller l'avertissement sur TOUTE issue passerait le test ci-dessus et
      # rendrait la marque inutile : present = doute, absent = mesure.
      pid = self()

      name =
        start_reg(tmp,
          get_file_fun: fn _r, _p, _o -> {:error, :not_found} end,
          put_file_fun: fn _r, _p, _c, _o -> {:ok, "c"} end
        )

      opts = [
        server: name,
        list_issues_fun: fn _r, _o -> {:ok, []} end,
        create_issue_fun: fn _r, _t, body, _o ->
          send(pid, {:body, body})
          {:ok, 78}
        end,
        add_label_fun: fn _r, _n, _l, _o -> {:ok, :added} end
      ]

      assert :recorded = Reg.record_or_escalate("pod", "jg113-ok", :launch_failed, opts)
      assert {:escalated, 78} = Reg.record_or_escalate("pod", "jg113-ok", :launch_failed, opts)

      assert_received {:body, body}
      refute body =~ "Déduplication NON vérifiée"
    end

    test "JG-122: forge CORROMPUE → aucun PUT, meme branche que l'illisible", %{tmp_dir: tmp} do
      name = :"reg_corrupt_#{System.unique_integer([:positive])}"
      test_pid = self()

      start_supervised!(
        {Reg,
         [
           name: name,
           wal_path: Path.join(tmp, "incidents.json"),
           sync_debounce_ms: 5,
           retry_ms: 50,
           get_file_fun: fn _r, _p, _o ->
             {:ok, %{content: "[1, 2, 3]", sha: "sha-du-fichier-corrompu"}}
           end,
           put_file_fun: fn _r, _p, _c, _o ->
             send(test_pid, :PUT_APPELE)
             {:ok, "c"}
           end
         ]}
      )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Reg.note("jg122:sig", :boom, server: name, now: "2026-06-20T10:00:00Z")
          Process.sleep(120)
        end)

      refute_received :PUT_APPELE,
                      "la vue locale a ete poussee PAR-DESSUS un fichier qu'on n'a pas su lire — " <>
                        "les incidents des autres machines sont effaces"

      assert log =~ "CORRUPT", "la corruption n'est pas tracee"
    end

    test "TEMOIN JG-122 — une forge LISIBLE est bien fusionnee et poussee", %{tmp_dir: tmp} do
      # Sans ce temoin, couper le PUT en toutes circonstances passerait le test ci-dessus.
      name = :"reg_ok_#{System.unique_integer([:positive])}"
      test_pid = self()

      start_supervised!(
        {Reg,
         [
           name: name,
           wal_path: Path.join(tmp, "incidents_ok.json"),
           sync_debounce_ms: 5,
           retry_ms: 50,
           get_file_fun: fn _r, _p, _o -> {:ok, %{content: "{}", sha: "sha-valide"}} end,
           put_file_fun: fn _r, _p, _c, _o ->
             send(test_pid, :PUT_APPELE)
             {:ok, "c"}
           end
         ]}
      )

      Reg.note("jg122:ok", :boom, server: name, now: "2026-06-20T10:00:00Z")
      Process.sleep(120)

      assert_received :PUT_APPELE
    end

    test "JG-123: le tampon de cooldown perdu rend un echec type, plus un `:ok` menteur", %{
      tmp_dir: tmp
    } do
      name = start_reg_wal_broken(tmp)

      assert {:error, {:wal_write_failed, _}} =
               GenServer.call(name, {:mark_escalated, "jg123:sig", 4242, "2026-06-20T12:00:00Z"}),
             "le tampon n'a pas ete grave et la reponse dit `:ok` — le fait n'existe nulle part"

      # TEMOIN : la memoire, elle, EST a jour. L'echec porte sur la durabilite, pas sur la
      # transaction — sans ce temoin, rendre l'erreur sans muter passerait le test ci-dessus.
      assert Reg.seen_before?("jg123:sig", server: name)
    end

    test "record_or_escalate: 1st occurrence + WAL write FAILS → {:recorded_volatile, _} (not :recorded)",
         %{tmp_dir: tmp} do
      name = start_reg_wal_broken(tmp)

      assert {:recorded_volatile, _} =
               Reg.record_or_escalate("pod", "p1", :dead,
                 server: name,
                 now: "2026-06-20T10:00:00Z"
               )
    end

    test "multi-line WAL: one incident per line (readable git diff), stays valid JSON",
         %{tmp_dir: tmp} do
      name =
        start_reg(tmp,
          get_file_fun: fn _r, _p, _o -> {:error, :not_found} end,
          put_file_fun: fn _r, _p, _c, _o -> {:ok, "c"} end
        )

      assert :ok = Reg.note("wake:a:1", :dead, server: name, now: "2026-06-20T10:00:00Z")
      assert :ok = Reg.note("wake:b:2", :dead, server: name, now: "2026-06-20T10:01:00Z")

      assert {:ok, content} = File.read(Path.join(tmp, "incidents.json"))

      # One incident per line keeps the ops diff readable.
      lines = content |> String.trim_trailing() |> String.split("\n")
      assert length(lines) == 4
      assert hd(lines) == "{"
      assert List.last(lines) == "}"
      assert Enum.any?(lines, &String.starts_with?(&1, ~s(  "wake:a:1":)))
      assert Enum.any?(lines, &String.starts_with?(&1, ~s(  "wake:b:2":)))

      # ...and stays valid JSON: `decode/1` re-reads both incidents as-is.
      assert {:ok, %{"wake:a:1" => _, "wake:b:2" => _}} = JSON.decode(content)
    end

    test "boot: merge local WAL ∪ forge (both sources of truth)", %{tmp_dir: tmp} do
      File.write!(
        Path.join(tmp, "incidents.json"),
        JSON.encode!(%{"wake:a:x" => %{"count" => 1}})
      )

      name =
        start_reg(tmp,
          get_file_fun: fn _r, _p, _o ->
            {:ok, %{content: JSON.encode!(%{"wake:b:y" => %{"count" => 1}}), sha: "s"}}
          end,
          put_file_fun: fn _r, _p, _c, _o -> {:ok, "c"} end
        )

      assert Reg.seen_before?("wake:a:x", server: name)
      assert Reg.seen_before?("wake:b:y", server: name)
    end

    test "boot: forge UNREADABLE (not a 404) → boots on WAL, LOUD, schedules a re-sync",
         %{tmp_dir: tmp} do
      # An unreadable forge is NOT an empty forge: on a fresh node (empty WAL) collapsing it to `%{}`
      # would replay every past recurrence as a first occurrence. Boot on WAL, log LOUD, and mark a
      # re-sync pending (the node catches up when the forge returns). Long debounce keeps the
      # scheduled re-sync from firing mid-test.
      name = :"reg_#{System.unique_integer([:positive])}"

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          start_supervised!(
            {Reg,
             [
               name: name,
               wal_path: Path.join(tmp, "incidents.json"),
               sync_debounce_ms: 60_000,
               retry_ms: 60_000,
               get_file_fun: fn _r, _p, _o -> {:error, {:http, 503, "down"}} end
             ]}
          )

          _ = settle(name)
        end)

      assert log =~ "forge backing UNREADABLE"
      assert log =~ "re-sync"
      assert settle(name).sync_pending == true
    end

    test "sync: the registry branch does NOT exist → named at the FIRST failure, with the gesture that lays it",
         %{tmp_dir: tmp} do
      name = :"reg_#{System.unique_integer([:positive])}"

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          start_supervised!(
            {Reg,
             [
               name: name,
               wal_path: Path.join(tmp, "incidents.json"),
               sync_debounce_ms: 5,
               retry_ms: 60_000,
               get_file_fun: fn _r, _p, _o -> {:error, :not_found} end,
               put_file_fun: fn _r, _p, _c, _o ->
                 {:error, {:http, 404, "branch does not exist"}}
               end
             ]}
          )

          Reg.note("wake:p:dead", %{"pod" => "p"}, server: name)
          Process.sleep(60)
          _ = settle(name)
        end)

      assert log =~ "does NOT exist"
      assert log =~ "forge-gestures apply"
      refute log =~ "forge unreachable"
      assert settle(name).sync_pending == true
    end

    test "boot: forge file CORRUPT (present but not a JSON map) → treated empty, LOUD",
         %{tmp_dir: tmp} do
      # Assert scheduled recovery as well as the log: logging then accepting empty
      # backing would conceal corruption despite the historical test title.
      name = :"reg_#{System.unique_integer([:positive])}"

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          start_reg(tmp,
            name: name,
            get_file_fun: fn _r, _p, _o -> {:ok, %{content: "not json {{{", sha: "s"}} end
          )

          _ = settle(name)
        end)

      assert log =~ "CORRUPT"
      assert settle(name).sync_pending == true
    end

    test "boot: WAL present but CORRUPT → LOUD log (visible amnesia), reg boots empty anyway",
         %{
           tmp_dir: tmp
         } do
      # Corrupt WAL must be reported even when boot proceeds with empty local memory.
      File.write!(Path.join(tmp, "incidents.json"), "this is not JSON {{{")

      name = :"reg_#{System.unique_integer([:positive])}"

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          start_supervised!(
            {Reg,
             [
               name: name,
               wal_path: Path.join(tmp, "incidents.json"),
               sync_debounce_ms: 5,
               retry_ms: 50,
               get_file_fun: fn _r, _p, _o -> {:error, :not_found} end
             ]}
          )

          # flush of handle_continue(:load) (where read_wal runs)
          _ = settle(name)
        end)

      assert log =~ "UNPARSEABLE"
      # the reg boots and works: empty memory, no crash
      refute Reg.seen_before?("wake:whatever:x", server: name)
    end

    test "boot: CORRUPT WAL is QUARANTINED, never overwritten by the fresh registry", %{
      tmp_dir: tmp
    } do
      # Preserve corrupt evidence while subsequent notes populate a fresh WAL.
      wal = Path.join(tmp, "incidents.json")
      File.write!(wal, "this is not JSON {{{")

      name = :"reg_#{System.unique_integer([:positive])}"

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          start_supervised!(
            {Reg,
             [
               name: name,
               wal_path: wal,
               sync_debounce_ms: 5,
               retry_ms: 50,
               get_file_fun: fn _r, _p, _o -> {:error, :not_found} end
             ]}
          )

          _ = settle(name)

          # A write happens (an incident is noted): it must NOT clobber the corrupt evidence.
          :ok = Reg.note("wake:p:x", :dead, server: name)
          _ = settle(name)
        end)

      assert log =~ "quarantined"

      # The corrupt content is preserved in a sibling; the live WAL is fresh (parseable).
      quarantined = Path.wildcard(wal <> ".corrupt-*")
      assert [q] = quarantined
      assert File.read!(q) == "this is not JSON {{{"
      assert {:ok, %{}} = Jason.decode(File.read!(wal))
    end

    test "boot: NON-MAP entry in the WAL/forge (hand-edited file) → LOUD drop, NEVER a boot-loop",
         %{tmp_dir: tmp} do
      # A non-map entry must be dropped visibly while valid neighboring entries survive.
      File.write!(
        Path.join(tmp, "incidents.json"),
        Jason.encode!(%{"wake:p:bad" => "garbage-string", "wake:p:ok" => %{"count" => 1}})
      )

      name = :"reg_#{System.unique_integer([:positive])}"

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          start_supervised!({Reg,
           [
             name: name,
             wal_path: Path.join(tmp, "incidents.json"),
             sync_debounce_ms: 5,
             retry_ms: 50,
             # The forge ALSO carries a non-map entry for the same signature: the boot's
             # WAL ∪ forge merge must not raise on either side.
             get_file_fun: fn _r, _p, _o ->
               {:ok, %{content: Jason.encode!(%{"wake:p:bad" => 42}), sha: "s"}}
             end
           ]})

          _ = settle(name)
        end)

      assert log =~ "non-map"
      # The healthy entry survives, the rotten entry is dropped (recurrence = first occurrence).
      assert Reg.seen_before?("wake:p:ok", server: name)
      refute Reg.seen_before?("wake:p:bad", server: name)
    end

    test "forge down: note stays :ok + WAL holds (fail-loud, NO loss)", %{tmp_dir: tmp} do
      name =
        start_reg(tmp,
          get_file_fun: fn _r, _p, _o -> {:error, :not_found} end,
          put_file_fun: fn _r, _p, _c, _o -> {:error, :forge_down} end
        )

      assert :ok = Reg.note("wake:p:x", :x, server: name, now: "2026-06-20T10:00:00Z")
      # memory OK despite the forge KO (the recurrence check does NOT depend on the forge)
      assert Reg.seen_before?("wake:p:x", server: name)
      # WAL holds → re-sync when the forge comes back
      assert {:ok, content} = File.read(Path.join(tmp, "incidents.json"))
      assert {:ok, %{"wake:p:x" => _}} = JSON.decode(content)
    end

    test "sync: bidirectional merge (incident from another machine absorbed)", %{tmp_dir: tmp} do
      pid = self()

      name =
        start_reg(tmp,
          # the forge has an incident from ANOTHER machine, not yet known locally
          get_file_fun: fn _r, _p, _o ->
            {:ok, %{content: JSON.encode!(%{"wake:other:z" => %{"count" => 2}}), sha: "s"}}
          end,
          put_file_fun: fn _r, _p, content, _o ->
            send(pid, {:put, content})
            {:ok, "c"}
          end
        )

      assert :ok = Reg.note("wake:local:q", :q, server: name, now: "2026-06-20T11:00:00Z")
      assert_receive {:put, content}, 1000
      # the put carries the MERGE (local + other machine), not an overwrite
      assert {:ok, merged} = JSON.decode(content)
      assert Map.has_key?(merged, "wake:local:q")
      assert Map.has_key?(merged, "wake:other:z")
      # and the owner adopted the cross-machine truth
      assert Reg.seen_before?("wake:other:z", server: name)
    end

    test "record_or_escalate: never seen → noted (:recorded)", %{tmp_dir: tmp} do
      pid = self()

      name =
        start_reg(tmp,
          get_file_fun: fn _r, _p, _o -> {:error, :not_found} end,
          put_file_fun: fn _r, _p, content, _o ->
            send(pid, {:put, content})
            {:ok, "c"}
          end
        )

      assert :recorded =
               Reg.record_or_escalate("pod", "issue-9-engineer", :launch_failed,
                 server: name,
                 now: "2026-06-20T10:00:00Z"
               )

      assert Reg.seen_before?(Reg.signature("pod", "issue-9-engineer", :launch_failed),
               server: name
             )

      assert_receive {:put, _}, 1000
    end

    test "record_or_escalate: already seen → escalation (:escalated)", %{tmp_dir: tmp} do
      pid = self()
      sig = Reg.signature("pod", "issue-7-engineer", :result_timeout)

      name =
        start_reg(tmp,
          get_file_fun: fn _r, _p, _o ->
            {:ok, %{content: JSON.encode!(%{sig => %{"count" => 1}}), sha: "s"}}
          end,
          put_file_fun: fn _r, _p, _c, _o -> {:ok, "c"} end
        )

      # Return the created issue number and add its label by name in a separate call.
      # These assertions check both calls, not their order.
      assert {:escalated, 1} =
               Reg.record_or_escalate("pod", "issue-7-engineer", :result_timeout,
                 server: name,
                 create_issue_fun: fn repo, title, _b, iopts ->
                   send(pid, {:issue, repo, title, iopts})
                   {:ok, 1}
                 end,
                 add_label_fun: fn repo, num, lbl, _o ->
                   send(pid, {:label, repo, num, lbl})
                   {:ok, :added}
                 end
               )

      assert_received {:issue, "lcars/_ops", title, iopts}
      # "récurrence" pins the FR user-facing sysadmin issue title (Escalation).
      assert title =~ "récurrence"
      # This fixture has no seat projection: omit assignment rather than sending nil.
      # Label names must not be passed to the integer-ID creation field.
      refute Keyword.has_key?(iopts, :labels)
      refute Keyword.has_key?(iopts, :assignees)
      # The durable label is set by NAME on the created issue.
      assert_received {:label, "lcars/_ops", 1, "error_system"}
    end

    test "recurrence UNDER cooldown → {:escalation_suppressed, N}, NO new issue (escalation memory)",
         %{tmp_dir: tmp} do
      # Under cooldown, note repeated occurrences without creating another issue.
      pid = self()

      name =
        start_reg(tmp,
          get_file_fun: fn _r, _p, _o -> {:error, :not_found} end,
          put_file_fun: fn _r, _p, _c, _o -> {:ok, "c"} end
        )

      opts = [
        server: name,
        create_issue_fun: fn _r, _t, _b, _o ->
          send(pid, :issue_created)
          {:ok, 41}
        end,
        add_label_fun: fn _r, _n, _l, _o -> {:ok, :added} end
      ]

      # 1st occurrence = note; 2nd = escalation (issue #41); 3rd/4th = SUPPRESSED (default 1h cooldown).
      assert :recorded = Reg.record_or_escalate("pod", "issue-9-eng", :launch_failed, opts)
      assert {:escalated, 41} = Reg.record_or_escalate("pod", "issue-9-eng", :launch_failed, opts)
      assert_received :issue_created

      assert {:escalation_suppressed, 41} =
               Reg.record_or_escalate("pod", "issue-9-eng", :launch_failed, opts)

      assert {:escalation_suppressed, 41} =
               Reg.record_or_escalate("pod", "issue-9-eng", :launch_failed, opts)

      refute_received :issue_created
    end

    test "recurrence AFTER the cooldown → re-escalation (the cooldown bounds, it does not silence the alarm)",
         %{tmp_dir: tmp} do
      pid = self()

      name =
        start_reg(tmp,
          get_file_fun: fn _r, _p, _o -> {:error, :not_found} end,
          put_file_fun: fn _r, _p, _c, _o -> {:ok, "c"} end
        )

      # 0 ms cooldown (seam): every recurrence re-escalates — the alarm re-fires as soon as it expires.
      opts = [
        server: name,
        escalation_cooldown_ms: 0,
        create_issue_fun: fn _r, _t, _b, _o ->
          send(pid, :issue_created)
          {:ok, 42}
        end,
        add_label_fun: fn _r, _n, _l, _o -> {:ok, :added} end
      ]

      assert :recorded = Reg.record_or_escalate("pod", "issue-9-eng", :launch_failed, opts)
      assert {:escalated, 42} = Reg.record_or_escalate("pod", "issue-9-eng", :launch_failed, opts)
      assert {:escalated, 42} = Reg.record_or_escalate("pod", "issue-9-eng", :launch_failed, opts)
      assert_received :issue_created
      assert_received :issue_created
    end

    test "the forge sync PRESERVES the escalation memory (merge_entry carries last_escalated_at/escalated_issue)",
         %{tmp_dir: tmp} do
      # Merging an older forge entry without cooldown fields must preserve the local stamp.
      pid = self()
      sig = Reg.signature("pod", "issue-9-eng", :launch_failed)

      name =
        start_reg(tmp,
          get_file_fun: fn _r, _p, _o ->
            {:ok, %{content: JSON.encode!(%{sig => %{"count" => 3}}), sha: "s"}}
          end,
          put_file_fun: fn _r, _p, content, _o ->
            send(pid, {:put, content})
            {:ok, "c"}
          end
        )

      opts = [
        server: name,
        create_issue_fun: fn _r, _t, _b, _o ->
          send(pid, :issue_created)
          {:ok, 43}
        end,
        add_label_fun: fn _r, _n, _l, _o -> {:ok, :added} end
      ]

      # Entry already known (forge, count 3) → direct recurrence → escalation + stamp.
      assert {:escalated, 43} = Reg.record_or_escalate("pod", "issue-9-eng", :launch_failed, opts)
      assert_received :issue_created

      # Wait past possible pre-stamp snapshots, then check that merging retained cooldown.
      content = receive_stamped_put()
      assert content =~ "escalated_issue"

      assert {:escalation_suppressed, 43} =
               Reg.record_or_escalate("pod", "issue-9-eng", :launch_failed, opts)

      refute_received :issue_created
    end

    test "escalate_gated (porte immediate): 1st occurrence IMMEDIATE, repetition under cooldown suppressed",
         %{tmp_dir: tmp} do
      # Immediate escalation skips the first-note gate but retains repeat cooldown.
      pid = self()

      name =
        start_reg(tmp,
          get_file_fun: fn _r, _p, _o -> {:error, :not_found} end,
          put_file_fun: fn _r, _p, _c, _o -> {:ok, "c"} end
        )

      opts = [
        server: name,
        create_issue_fun: fn _r, _t, _b, _o ->
          send(pid, :issue_created)
          {:ok, 77}
        end,
        add_label_fun: fn _r, _n, _l, _o -> {:ok, :added} end
      ]

      sig = "workflow_map:standard-qa"

      assert {:ok, 77} =
               Reg.escalate_gated(:workflow_map_failed, "standard-qa", "illisible", sig, opts)

      assert_received :issue_created

      assert {:suppressed, 77} =
               Reg.escalate_gated(:workflow_map_failed, "standard-qa", "illisible", sig, opts)

      refute_received :issue_created
    end

    test "F-C075: add_label FAILS (persistent) → {:escalation_failed, {:discovery_label_failed,_}}, NEVER a lying {:escalated}",
         %{tmp_dir: tmp} do
      # Label failure is an escalation failure even after issue creation; return
      # the number so that discovery can be repaired.
      sig = Reg.signature("pod", "issue-7-engineer", :result_timeout)

      name =
        start_reg(tmp,
          get_file_fun: fn _r, _p, _o ->
            {:ok, %{content: JSON.encode!(%{sig => %{"count" => 1}}), sha: "s"}}
          end,
          put_file_fun: fn _r, _p, _c, _o -> {:ok, "c"} end
        )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:escalation_failed,
                  {:discovery_label_failed, 1, {:label_not_added, "error_system"}}} =
                   Reg.record_or_escalate("pod", "issue-7-engineer", :result_timeout,
                     server: name,
                     create_issue_fun: fn _r, _t, _b, _o -> {:ok, 1} end,
                     add_label_fun: fn _r, _n, _l, _o ->
                       {:error, {:label_not_added, "error_system"}}
                     end
                   )
        end)

      assert log =~ "NOT added after retries"
    end

    test "F-C075: add_label FLAKY (fails 1×, succeeds) → retry → {:escalated, 1} (transient self-heal)",
         %{tmp_dir: tmp} do
      sig = Reg.signature("pod", "issue-7-engineer", :result_timeout)

      name =
        start_reg(tmp,
          get_file_fun: fn _r, _p, _o ->
            {:ok, %{content: JSON.encode!(%{sig => %{"count" => 1}}), sha: "s"}}
          end,
          put_file_fun: fn _r, _p, _c, _o -> {:ok, "c"} end
        )

      # Process-dict counter: 1st call fails, 2nd succeeds → the bounded retry self-heals.
      assert {:escalated, 1} =
               Reg.record_or_escalate("pod", "issue-7-engineer", :result_timeout,
                 server: name,
                 create_issue_fun: fn _r, _t, _b, _o -> {:ok, 1} end,
                 add_label_fun: fn _r, _n, _l, _o ->
                   n = (Process.get(:label_calls) || 0) + 1
                   Process.put(:label_calls, n)
                   if n < 2, do: {:error, {:label_not_added, "flaky"}}, else: {:ok, :added}
                 end
               )
    end

    test "record_or_escalate: already seen + forge DOWN → {:escalation_failed,_}, NEVER {:escalated} (no issue)",
         %{tmp_dir: tmp} do
      sig = Reg.signature("pod", "issue-7-engineer", :result_timeout)

      name =
        start_reg(tmp,
          get_file_fun: fn _r, _p, _o ->
            {:ok, %{content: JSON.encode!(%{sig => %{"count" => 1}}), sha: "s"}}
          end,
          put_file_fun: fn _r, _p, _c, _o -> {:ok, "c"} end
        )

      # The create stub always fails. This checks error propagation, not retry count;
      # without an assignee, escalation makes only one create attempt.
      assert {:escalation_failed, :forge_down} =
               Reg.record_or_escalate("pod", "issue-7-engineer", :result_timeout,
                 server: name,
                 create_issue_fun: fn _r, _t, _b, _o -> {:error, :forge_down} end
               )
    end

    test "record_or_escalate escalate_kind :sp_suspect → issue points at the SP (recurring wake)",
         %{
           tmp_dir: tmp
         } do
      pid = self()
      sig = Reg.signature("wake", "issue-7-engineer", {:no_ack, :wake})

      name =
        start_reg(tmp,
          get_file_fun: fn _r, _p, _o ->
            {:ok, %{content: JSON.encode!(%{sig => %{"count" => 1}}), sha: "s"}}
          end,
          put_file_fun: fn _r, _p, _c, _o -> {:ok, "c"} end
        )

      assert {:escalated, _} =
               Reg.record_or_escalate("wake", "issue-7-engineer", {:no_ack, :wake},
                 server: name,
                 escalate_kind: :sp_suspect,
                 pane: "ECRAN-TEST-42 : last REPL line",
                 create_issue_fun: fn _r, title, body, _o ->
                   send(pid, {:issue, title, body})
                   {:ok, 1}
                 end,
                 add_label_fun: fn _r, _n, _l, _o -> {:ok, :added} end
               )

      assert_received {:issue, title, body}

      # "SP suspect" / "Écran capturé" pin the FR user-facing sysadmin issue title/body (Escalation).
      assert title =~ "SP suspect"
      assert body =~ "PROMPT"
      # [5]: the captured screen (deported fallback-ack) is attached to the issue
      assert body =~ "ECRAN-TEST-42"
      assert body =~ "Écran capturé"
    end
  end
end
