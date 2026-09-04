defmodule Fleet.Pilot.IncidentRegistryTest do
  # `async: false` : `with_store/2` ECRIT `LCARS_STORE_ROOT`, globale au NOEUD, et la restaure. En
  # parallele de `Fleet.Spawner.Pod.LaunchSpecTest` — qui ecrit et lit la meme — cette restauration
  # tombe au milieu de ses tests et leur fait lire une racine qui n'est pas la leur (mesure du
  # 2026-08-20, en `mix gate` complet). La regle de `Fleet.TestEnv` vaut pour l'env OS comme pour
  # l'env d'application : un fichier qui l'ecrit est `async: false`.
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

      opts =
        [
          name: name,
          wal_path: Path.join(tmp, "incidents.json"),
          sync_debounce_ms: 5,
          retry_ms: 50
        ] ++ extra

      start_supervised!({Reg, opts})
      name
    end

    # Walks the forge-sync puts until the STAMPED one (bounded). The sync can legitimately fire
    # twice around an escalation: `{:observe, …}` schedules a debounce, the stamp lands in a
    # second `{:mark_escalated, …}` call which re-schedules — under load the first put is a
    # PRE-STAMP snapshot (measured: directory-scope run, seed 763143). The contract is not "the
    # first write carries the stamp": it is "the stamp survives the sync that FOLLOWS it".
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
          put_file_fun: fn _r, _p, content, _o -> send(pid, {:put, content}) && {:ok, "c"} end
        )

      refute Reg.seen_before?("wake:p:dead", server: name)
      assert :ok = Reg.note("wake:p:dead", :dead, server: name, now: "2026-06-20T10:00:00Z")
      assert Reg.seen_before?("wake:p:dead", server: name)

      # crash-survivable local WAL, written BEFORE the forge
      assert {:ok, content} = File.read(Path.join(tmp, "incidents.json"))

      assert {:ok, %{"wake:p:dead" => %{"count" => 1, "last_reason" => ":dead"}}} =
               JSON.decode(content)

      # forge sync triggered async (5ms debounce)
      assert_receive {:put, _}, 1000
    end

    # The registry sync is a commit the RUNTIME makes — no human initiated it, no pod produced it,
    # and no pod could (a pod never holds the forge token). It signed `LCARS-starfleet` /
    # `starfleet@lcars.local`, which is the one shape `ForgeIdentity` forbids: author = the human,
    # role = a verified TRAILER, committer = the system. Nothing caught it because nothing looked at
    # the identity of this put — only at its content.
    test "sync: the put is signed by the SYSTEM, never by a pod role", %{tmp_dir: tmp} do
      pid = self()

      name =
        start_reg(tmp,
          get_file_fun: fn _r, _p, _o -> {:error, :not_found} end,
          put_file_fun: fn _r, _p, _c, o -> send(pid, {:put_opts, o}) && {:ok, "c"} end
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
          put_file_fun: fn _r, _p, content, _o -> send(pid, {:put, content}) && {:ok, "c"} end
        )

      assert :ok = Reg.note("wake:p:dead", :dead, server: name, now: "2026-06-20T10:00:00Z")

      # A failed (non-404) forge READ used to collapse to {%{}, nil} → a PUT that could OVERWRITE the
      # remote registry (cross-machine incidents we never read = data loss). Now: unreadable → NO put at
      # all; the local WAL holds the data and the sync retries (retry_ms) until the forge returns.
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

    # JG-123 — LE MOTIF TRI-ETAT EXISTAIT DANS LE MEME FICHIER, quarante lignes plus haut, et le
    # site du tampon de cooldown ne l'avait pas : `_ = write_wal(...)` jetait le seul fait qui
    # distingue « tampon grave » de « tampon perdu », et la reponse etait `:ok` DANS LES DEUX CAS.
    # Aucun appelant ne pouvait donc le savoir, meme en le voulant.
    #
    # ⚠ Le retour public de `record_or_escalate/4` NE CHANGE PAS, et c'est mesure : ici un WAL perdu
    # coute une issue REDONDANTE a la recurrence suivante (borne, auto-reparant), la ou le voisin
    # perdait l'INCIDENT lui-meme (la chronologie ment). Ce qui manquait n'etait pas un verdict,
    # c'etait que le fait EXISTE.
    # JG-122 — UN FICHIER CORROMPU N'EST PAS UN REGISTRE VIDE. `decode/1` rendait `%{}` et son propre
    # commentaire disait la perte (« real amnesia, not an absence ») ; c'est ensuite le SHA du
    # fichier CORROMPU qui partait en `sha:` du PUT, donc l'ecrasement reussissait. La discipline
    # existait cent-cinquante lignes plus haut, sur l'autre moitie du probleme : « an unreadable
    # forge is NOT an empty one … pushing our LOCAL view would OVERWRITE cross-machine incidents ».
    # JG-113 — `nil` DISAIT DEUX CHOSES : « le tableau a ete LU et ne porte pas ce marqueur » et
    # « le tableau est ILLISIBLE ». Les deux menaient au meme geste (creer, fail-closed vers l'alarme
    # — l'arbitrage est ecrit et il ne change pas) ET au meme RESULTAT : une issue sysadmin
    # identique. Or son lecteur est un humain devant le tableau ops : si un doublon apparait, rien
    # dans l'issue ne lui dit pourquoi ni qu'il doit chercher sa jumelle.
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
        create_issue_fun: fn _r, _t, body, _o -> send(pid, {:body, body}) && {:ok, 77} end,
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
        create_issue_fun: fn _r, _t, body, _o -> send(pid, {:body, body}) && {:ok, 78} end,
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

      # 2 incidents → 4 lines (`{`, incident a, incident b, `}`): ONE incident per line. Bites if we
      # go back to the compact `JSON.encode!` (which would glue everything on one line → unreadable
      # git diff).
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

    test "boot: forge file CORRUPT (present but not a JSON map) → treated empty, LOUD",
         %{tmp_dir: tmp} do
      # The file EXISTED (≠ 404) but its content is not a JSON map — real amnesia, must be loud.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          name =
            start_reg(tmp,
              get_file_fun: fn _r, _p, _o -> {:ok, %{content: "not json {{{", sha: "s"}} end
            )

          _ = settle(name)
        end)

      assert log =~ "CORRUPT"
    end

    test "boot: WAL present but CORRUPT → LOUD log (visible amnesia), reg boots empty anyway",
         %{
           tmp_dir: tmp
         } do
      # A WAL present but unreadable = LOSS of the cross-session memory (recurrences are no longer
      # detected, no more escalation). Swallowing the decode error into `%{}` would boot
      # "0 signatures" as if nominal. Fix: direct Jason.decode → LOUD log (the amnesia must be
      # visible), reg boots empty.
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
      # The old flow logged the corruption then let the next write rename a fresh WAL over it —
      # erasing the only forensic trace of what corrupted the cross-machine memory. Now the corrupt
      # file is moved aside to a `.corrupt-<ts>` sibling BEFORE booting empty, and a subsequent write
      # lands on the clean path.
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
      # The forge file (ops) and the WAL are hand-editable: a non-map VALUE under a signature
      # entered RAM then made merge_entry raise in handle_continue(:load) → boot-loop reproducible
      # at every reboot until the file was repaired. Unreadable-WAL doctrine: VISIBLE memory loss
      # (drop logged error), never a boot crash.
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
          put_file_fun: fn _r, _p, content, _o -> send(pid, {:put, content}) && {:ok, "c"} end
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
          put_file_fun: fn _r, _p, content, _o -> send(pid, {:put, content}) && {:ok, "c"} end
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

      # Return = the issue's NUMBER (1, returned by the stub), not the reason: an `{:escalated, num}`
      # PROVES an issue really exists. (An honesty fix: the return used to carry the reason and came
      # out even when opening the issue failed — cf. the "forge DOWN" test below.)
      # MECHANICS (fix F-RUN-2): `issue_create` receives the assignee but NO label (the Gitea POST
      # requires integer IDs, not names → 422); the `error_system` label is set AFTERWARDS via
      # `add_label` by NAME. We verify BOTH calls.
      assert {:escalated, 1} =
               Reg.record_or_escalate("pod", "issue-7-engineer", :result_timeout,
                 server: name,
                 create_issue_fun: fn repo, title, _b, iopts ->
                   send(pid, {:issue, repo, title, iopts}) && {:ok, 1}
                 end,
                 add_label_fun: fn repo, num, lbl, _o ->
                   send(pid, {:label, repo, num, lbl}) && {:ok, :added}
                 end
               )

      assert_received {:issue, "fleet/lcars", title, iopts}
      # "récurrence" pins the FR user-facing sysadmin issue title (Escalation).
      assert title =~ "récurrence"
      # create_issue NO LONGER carries a label (otherwise 422). Et SANS projection du siege
      # (ni config, ni fichier — l'etat de ce banc), il ne porte AUCUN assignee : l'option est
      # OMISE, pas posee a nil — cf. resolve_assignee/1, plus aucun login en dur.
      refute Keyword.has_key?(iopts, :labels)
      refute Keyword.has_key?(iopts, :assignees)
      # The durable label is set by NAME on the created issue.
      assert_received {:label, "fleet/lcars", 1, "error_system"}
    end

    test "recurrence UNDER cooldown → {:escalation_suppressed, N}, NO new issue (escalation memory)",
         %{tmp_dir: tmp} do
      # Escalating on EVERY recurrence — a durably unreadable workflow_map on a routed issue =
      # 1 forge issue PER TICK (~2,880/day), self-amplified by the webhook-kick ("the dedup IS the
      # throttle" was false: the dedup throttled nothing). Instead: the escalation records
      # last_escalated_at/escalated_issue in the entry; a recurrence under the cooldown is NOTED
      # (count/last_seen — the timeline stays true) but suppressed.
      pid = self()

      name =
        start_reg(tmp,
          get_file_fun: fn _r, _p, _o -> {:error, :not_found} end,
          put_file_fun: fn _r, _p, _c, _o -> {:ok, "c"} end
        )

      opts = [
        server: name,
        create_issue_fun: fn _r, _t, _b, _o -> send(pid, :issue_created) && {:ok, 41} end,
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
        create_issue_fun: fn _r, _t, _b, _o -> send(pid, :issue_created) && {:ok, 42} end,
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
      # The BLOCKING point of the verify: merge_entry rebuilt the entry with 4 hardcoded keys →
      # the escalation stamp would have been silently lost at every forge sync (2s debounce) and
      # the storm would resume. Here the forge returns the entry WITHOUT the stamp (other machine,
      # pre-cooldown): after the merge, the recurrence must STILL be suppressed.
      pid = self()
      sig = Reg.signature("pod", "issue-9-eng", :launch_failed)

      name =
        start_reg(tmp,
          get_file_fun: fn _r, _p, _o ->
            {:ok, %{content: JSON.encode!(%{sig => %{"count" => 3}}), sha: "s"}}
          end,
          put_file_fun: fn _r, _p, content, _o -> send(pid, {:put, content}) && {:ok, "c"} end
        )

      opts = [
        server: name,
        create_issue_fun: fn _r, _t, _b, _o -> send(pid, :issue_created) && {:ok, 43} end,
        add_label_fun: fn _r, _n, _l, _o -> {:ok, :added} end
      ]

      # Entry already known (forge, count 3) → direct recurrence → escalation + stamp.
      assert {:escalated, 43} = Reg.record_or_escalate("pod", "issue-9-eng", :launch_failed, opts)
      assert_received :issue_created

      # The sync (5ms debounce) merges WAL ∪ forge-without-stamp and REWRITES the memory: the stamp
      # must survive the merge (last_escalated_at/escalated_issue pair carried by merge_entry).
      # Walked, not first-put-asserted: a pre-stamp snapshot may precede it (cf. receive_stamped_put).
      content = receive_stamped_put()
      assert content =~ "escalated_issue"

      assert {:escalation_suppressed, 43} =
               Reg.record_or_escalate("pod", "issue-9-eng", :launch_failed, opts)

      refute_received :issue_created
    end

    test "escalate_gated (porte immediate): 1st occurrence IMMEDIATE, repetition under cooldown suppressed",
         %{tmp_dir: tmp} do
      # La porte immediate (gate: immediate des routes declaratives, et les kinds tires du code) :
      # issue des la PREMIERE occurrence — seules les repetitions intra-cooldown de la meme
      # signature sont supprimees (une panne permanente ne re-cree pas une issue par event).
      pid = self()

      name =
        start_reg(tmp,
          get_file_fun: fn _r, _p, _o -> {:error, :not_found} end,
          put_file_fun: fn _r, _p, _c, _o -> {:ok, "c"} end
        )

      opts = [
        server: name,
        create_issue_fun: fn _r, _t, _b, _o -> send(pid, :issue_created) && {:ok, 77} end,
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
      # `error_system` = THE durable discovery signal (the poller/human finds the issue BY this label).
      # Fallback B-#5: failed label → escalate returned `{:ok, 1}` → record_or_escalate →
      # {:escalated, 1} = alarm "delivered" while the incident is UNFINDABLE by label filter.
      # F-C075: after bounded retry, we SURFACE the failure →
      # {:escalation_failed, {:discovery_label_failed, num, reason}} (the alarm re-fires on
      # recurrence, the operator must act; the issue exists, its number travels in the reason).
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

      # `issue_create` fails on BOTH attempts (with assignee, then label-only fallback) = forge down.
      # The return must SAY the failure — never a reassuring `{:escalated, _}` while no sysadmin
      # issue was opened.
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
                   send(pid, {:issue, title, body}) && {:ok, 1}
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
            send(me, :created) && {:ok, 999}
          end,
          add_label_fun: fn _r, num, _lbl, _o -> send(me, {:label, num}) && {:ok, :added} end
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
          create_issue_fun: fn _r, _t, _b, _o -> send(me, :created) && {:ok, 7} end,
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
          create_issue_fun: fn _r, _t, _b, _o -> send(me, :created) && {:ok, 5} end,
          add_label_fun: fn _r, _num, _lbl, _o -> {:ok, :added} end
        )

      assert {:ok, 5} = result
      assert_received :created
    end
  end

  describe "every kind that fires has a describe clause" do
    alias Fleet.Pilot.IncidentRegistry.Escalation

    # TROUVE PAR LA RELECTURE 2026-08-19 : `:awaits_arch_stuck` (emis par
    # `StepRunConsumer.drain_failed/4`) n'avait pas de clause `kind_describe/1` — l'escalade
    # crashait en FunctionClauseError au lieu d'ouvrir l'issue, exactement sur le chemin
    # « un ticket sort du pipeline en silence ». Le temoin du drain stubbe `escalate_fun`,
    # donc SEUL un appel au VRAI `Escalation.escalate/5` peut attraper cette classe de trou.
    test ":awaits_arch_stuck opens an issue instead of crashing on kind_describe" do
      pid = self()

      opts = [
        list_issues_fun: fn _r, _o -> {:ok, []} end,
        create_issue_fun: fn _r, title, _body, _o -> send(pid, {:title, title}) && {:ok, 91} end,
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
          send(pid, {:create, iopts}) && {:ok, 5}
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
      src = File.read!("lib/fleet/pilot/incident_registry/escalation.ex")
      refute src =~ ~s("starfleet")
      refute src =~ ~s("admiral")
    end
  end
end
